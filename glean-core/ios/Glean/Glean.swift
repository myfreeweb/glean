/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

/// The main Glean API.
///
/// This is exposed through the global `Glean.shared` object.
public class Glean {
    /// The main Glean object.
    ///
    /// Before any data collection can take place, the Glean SDK **must** be initialized from the application.
    ///
    /// ```swift
    /// Glean.shared.setUploadEnabled(true)
    /// Glean.shared.initialize()
    /// ```
    public static let shared = Glean()

    var handle: UInt64 = 0
    private var uploadEnabled: Bool = true
    private var configuration: Configuration?
    private var observer: GleanLifecycleObserver?
    static var backgroundTaskId = UIBackgroundTaskIdentifier.invalid

    // This struct is used for organizational purposes to keep the class constants in a single place
    struct Constants {
        static let logTag = "glean/Glean"
    }

    private var pingTypeQueue = [Ping]()

    private let logger = Logger(tag: Constants.logTag)

    private init() {
        // intentionally left private, no external user can instantiate a new global object.

        // Enable logging in the Rust library
        glean_enable_logging()
    }

    deinit {
        self.handle = 0
    }

    /// Initialize the Glean SDK.
    ///
    /// This should only be initialized once by the application, and not by
    /// libraries using the Glean SDK. A message is logged to error and no
    /// changes are made to the state if initialize is called a more than
    /// once.
    ///
    /// A LifecycleObserver will be added to send pings when the application goes
    /// into the background.
    ///
    /// - parameters:
    ///     * configuration: A Glean `Configuration` object with global settings.
    public func initialize(configuration: Configuration = Configuration()) {
        if self.isInitialized() {
            logger.error("Glean should not be initialized multiple times")
            return
        }

        self.registerPings(Pings.shared)

        self.configuration = configuration

        self.handle = withFfiConfiguration(
            // The FileManager returns `file://` URLS with absolute paths.
            // The Rust side expects normal path strings to be used.
            // `relativePath` for a file URL gives us the absolute filesystem path.
            dataDir: getDocumentsDirectory().relativePath,
            packageName: AppInfo.name,
            uploadEnabled: uploadEnabled,
            configuration: configuration
        ) { cfg in
            var cfg = cfg
            return glean_initialize(&cfg)
        }

        if handle == 0 {
            return
        }

        // If any pings were registered before initializing, do so now
        for ping in self.pingTypeQueue {
            self.registerPingType(ping)
        }

        if !Dispatchers.shared.testingMode {
            self.pingTypeQueue.removeAll()
        }

        initializeCoreMetrics()

        // Deal with any pending events so we can start recording new ones
        glean_on_ready_to_send_pings(self.handle)

        // Signal Dispatcher that init is complete
        Dispatchers.shared.flushQueuedInitialTasks()

        self.observer = GleanLifecycleObserver()
    }

    /// Initialize the core metrics internally managed by Glean (e.g. client id).
    private func initializeCoreMetrics() {
        // Set a few more metrics that will be sent as part of every ping.
        // Please note that the following metrics must be set synchronously, so
        // that they are guaranteed to be available with the first ping that is
        // generated. We use an internal only API to do that.

        GleanBaseline.locale.setSync(getLocaleTag())
        GleanInternalMetrics.os.setSync(Sysctl.os)
        GleanInternalMetrics.osVersion.setSync(UIDevice.current.systemVersion)
        GleanInternalMetrics.deviceManufacturer.setSync(Sysctl.manufacturer)
        GleanInternalMetrics.deviceModel.setSync(Sysctl.model)
        GleanInternalMetrics.architecture.setSync(Sysctl.machine)

        if let channel = self.configuration?.channel {
            GleanInternalMetrics.appChannel.setSync(channel)
        }

        GleanInternalMetrics.appBuild.setSync(AppInfo.buildId)
        GleanInternalMetrics.appDisplayVersion.setSync(AppInfo.displayVersion)
    }

    /// Enable or disable Glean collection and upload.
    ///
    /// Metric collection is enabled by default.
    ///
    /// When uploading is disabled, metrics aren't recorded at all and no data
    /// is uploaded.
    ///
    /// When disabling, all pending metrics, events and queued pings are cleared.
    ///
    /// When enabling, the core Glean metrics are recreated.
    ///
    /// - parameters:
    ///     * enabled: When true, enable metric collection.
    public func setUploadEnabled(_ enabled: Bool) {
        if isInitialized() {
            let originalEnabled = getUploadEnabled()

            _ = Dispatchers.shared.launch {
                // glean_set_upload_enabled might delete all of the queued pings.
                // Currently a ping uploader could be scheduled ahead of this,
                // at which point it will pick up scheduled pings before the setting was toggled.
                // Or it is scheduled afterwards and will not schedule or find any left-over pings to send.

                glean_set_upload_enabled(self.handle, enabled.toByte())

                if !enabled {
                    // TODO(bug 1581815): cancel schedulers and upload worker
                }

                if !originalEnabled && self.getUploadEnabled() {
                    // If uploading is being re-enabled, we have to restore the
                    // application-lifetime metrics.
                    self.initializeCoreMetrics()
                }
            }
        } else {
            self.uploadEnabled = enabled
        }
    }

    /// Get whether or not Glean is allowed to record and upload data.
    public func getUploadEnabled() -> Bool {
        if isInitialized() {
            return glean_is_upload_enabled(handle) != 0
        } else {
            return uploadEnabled
        }
    }

    /// Returns true if the Glean SDK has been initialized.
    func isInitialized() -> Bool {
        return handle != 0
    }

    /// Handle background event and send appropriate pings
    func handleBackgroundEvent() {
        // This asks the OS for more time when going to background to perform critical tasks.
        // This will be signaled complete when `sendPingsByName` is done.
        Glean.backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "Glean Upload Task") {
            // End the task if time expires
            UIApplication.shared.endBackgroundTask(Glean.backgroundTaskId)
            Glean.backgroundTaskId = UIBackgroundTaskIdentifier.invalid
        }

        self.sendPingsByName(pingNames: ["baseline", "events"])
    }

    /// Send a list of pings by name
    ///
    /// - parameters:
    ///     * pingNames: List of ping names to send
    ///
    /// The ping content is assembled as soon as possible, but upload is not
    /// guaranteed to happen immediately, as that depends on the upload
    /// policies.
    ///
    /// If the ping currently contains no content, it will not be assembled and
    /// queued for sending.
    func sendPingsByName(pingNames: [String]) {
        // This runs in the background to allow for processing of pings off of the
        // main thread. Please note that the ping uploader will spawn other async
        // operations if there are pings to upload.
        Dispatchers.shared.launchAsync {
            if !self.isInitialized() {
                self.logger.error("Glean must be initialized before sending pings")
                return
            }

            if !self.getUploadEnabled() {
                self.logger.error("Glean must be enabled before sending pings")
                return
            }

            withArrayOfCStrings(pingNames) { pingNames in
                let sentPing = glean_send_pings_by_name(
                    self.handle,
                    pingNames,
                    Int32(pingNames.count),
                    self.configuration!.logPings.toByte()
                )

                if sentPing != 0 {
                    if let config = self.configuration {
                        HttpPingUploader(configuration: config).process()
                    }
                }
            }

            // End background task assertion to let the OS know we are done with our tasks
            UIApplication.shared.endBackgroundTask(Glean.backgroundTaskId)
            Glean.backgroundTaskId = UIBackgroundTaskIdentifier.invalid
        }
    }

    func sendPings(_ pings: [Ping]) {
        let pingNames = pings.map { $0.name }
        return self.sendPingsByName(pingNames: pingNames)
    }

    /// Register the pings generated from `pings.yaml` with the Glean SDK.
    ///
    /// - parameters:
    ///     * pings: The `Pings` object generated for your library or application
    ///              by the Glean SDK.
    public func registerPings(_: Any) {
        // Instantiating the Pings object to send this function is enough to
        // call the constructor and have it registered through [Glean.registerPingType].
        NSLog("Registering pings")
    }

    /// Register a `Ping` in the registry associated with this `Glean` object.
    func registerPingType(_ pingType: Ping) {
        // TODO: This might need to synchronized across multiple threads,
        // `initialize()` will read and clear the ping type queue.
        if !self.isInitialized() {
            self.pingTypeQueue.append(pingType)
        } else {
            glean_register_ping_type(self.handle, pingType.handle)
        }
    }

    /// TEST ONLY FUNCTION.
    ///
    /// Returns true if a ping by this name is in the ping registry.
    func testHasPingType(_ pingName: String) -> Bool {
        return glean_test_has_ping_type(self.handle, pingName) != 0
    }

    /// Test-only method to destroy the owned glean-core handle.
    func testDestroyGleanHandle() {
        if !isInitialized() {
            // We don't need to destroy the Glean handle: it wasn't initialized.
            return
        }

        glean_destroy_glean(handle)
        handle = 0
    }

    /// TEST ONLY FUNCTION.
    ///
    /// Enable test mode.
    ///
    /// This makes all asynchronous work synchronous so we can test the results of the
    /// API synchronously.
    func enableTestingMode() {
        Dispatchers.shared.setTestingMode(enabled: true)
    }

    /// TEST ONLY FUNCTION.
    ///
    /// Resets the Glean state and trigger init again.
    ///
    /// - parameters:
    ///     * configuration: the `Configuration` to init Glean with
    ///     * clearStores: if true, clear the contents of all stores
    func resetGlean(configuration: Configuration = Configuration(), clearStores: Bool) {
        enableTestingMode()

        if isInitialized() && clearStores {
            // Clear all the stored data.
            glean_test_clear_all_stores(handle)
        }

        // Init Glean.
        testDestroyGleanHandle()
        setUploadEnabled(true)
        initialize(configuration: configuration)
    }
}