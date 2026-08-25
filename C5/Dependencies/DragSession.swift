//
//  DragSession.swift
//  C5
//

import AppKit

/// Observes the system-wide drag pasteboard to tell whether a drag is in flight.
enum DragSession {
    /// Increments whenever the system starts a new drag session, in any app.
    /// Comparing it against a value sampled at mouse-down reveals that a drag
    /// began, without needing Accessibility permission.
    static var changeCount: Int {
        NSPasteboard(name: .drag).changeCount
    }
}
