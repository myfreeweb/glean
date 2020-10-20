// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

use std::collections::HashMap;

use crate::event_database::RecordedEvent;

/// A description for the `EventMetric` type.
///
/// When changing this trait, make sure all the operations are
/// implemented in the related type in `../metrics/`.
pub trait Event {
    /// Records an event.
    ///
    /// # Arguments
    ///
    /// * `extra` - A HashMap of (key, value) pairs. The key is an index into
    ///   the metric's `allowed_extra_keys` vector where the key's string is
    ///   looked up. If any key index is out of range, an error is reported and
    ///   no event is recorded.
    fn record<M: Into<Option<HashMap<i32, String>>>>(&self, extra: M);

    /// **Exported for test purposes.**
    ///
    /// Tests whether there are currently stored events for this event metric.
    ///
    /// This doesn't clear the stored value.
    fn test_has_value(&self, store_name: &str) -> bool;

    /// **Exported for test purposes.**
    ///
    /// Get the vector of currently stored events for this event metric.
    ///
    /// This doesn't clear the stored value.
    fn test_get_value(&self, store_name: &str) -> Option<Vec<RecordedEvent>>;

    /// **Exported for test purposes.**
    ///
    /// Gets the currently stored events for this event metric as a JSON-encoded string.
    ///
    /// This doesn't clear the stored value.
    fn test_get_value_as_json_string(&self, store_name: &str) -> String;
}
