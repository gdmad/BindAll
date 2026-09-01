import Foundation

/// Whether the pass that follows an applied fix must run its own re-check of the field.
///
/// The re-check exists so the underlines can never silently go stale after a fix: it runs even when
/// the field's value never changed. The one case it must stand down for is a check started from a
/// click, which is already in flight and carries the clicked word with it -- starting ours would
/// cancel it, and the surviving result, having no word attached, would close the popup instead of
/// opening it. That is the silent no-op this policy exists to prevent.
enum RecheckPolicy {
    static func shouldRecheck(selectionCheckPending: Bool) -> Bool {
        !selectionCheckPending
    }
}
