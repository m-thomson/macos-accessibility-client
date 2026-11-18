//
//  UnifiedLogEvent.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import AppKit
import Foundation

/// Process identity captured with an event, so old rows still have a name after the app exits.
nonisolated struct EventProcess: Equatable, Sendable {
    let pid: pid_t?
    let name: String?

    @MainActor
    static func capture(pid: pid_t?) -> EventProcess {
        let name = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName?.nonEmptyOrNil }
        return EventProcess(pid: pid, name: name)
    }

    var description: String {
        let name = name ?? "Unknown"
        guard let pid else { return name }
        return "\(name) (pid \(pid))"
    }
}

/// One row in the unified log timeline. Carries an entry from any of the three
/// log sources (per-app AX events, system-wide clicks, system-wide focus changes)
/// so the view can render them interleaved by timestamp.
enum UnifiedLogEvent: Identifiable, Sendable {
    case app(AXObserverWrapper.Event)
    case click(ClickTracker.ClickEvent)
    case focus(SystemFocusTracker.FocusEvent)

    var id: String {
        switch self {
        case .app(let event): return "app-\(event.id.uuidString)"
        case .click(let event): return "click-\(event.id.uuidString)"
        case .focus(let event): return "focus-\(event.id.uuidString)"
        }
    }

    var timestamp: Date {
        switch self {
        case .app(let event): return event.timestamp
        case .click(let event): return event.timestamp
        case .focus(let event): return event.timestamp
        }
    }

    /// The AX element this entry refers to, when one was successfully resolved.
    /// `nil` for clicks where `AXUIElementCopyElementAtPosition` failed.
    var element: AXElement? {
        switch self {
        case .app(let event): return event.element
        case .click(let event): return event.element
        case .focus(let event): return event.element
        }
    }

    /// PID of the process owning the element, when known. Used by the unified-log
    /// row click handler to switch the sidebar to the right app before revealing.
    var pid: pid_t? {
        process.pid
    }

    var process: EventProcess {
        switch self {
        case .app(let event): return event.process
        case .click(let event): return event.process
        case .focus(let event): return event.process
        }
    }

    var scopeDescription: String {
        switch self {
        case .app: return "Application"
        case .click, .focus: return "Global"
        }
    }

    var eventDescription: String {
        switch self {
        case .app(let event): return event.notification
        case .click(let event): return event.isRightClick ? "Right click" : "Left click"
        case .focus: return "Focus changed"
        }
    }

    var elementSummary: String {
        switch self {
        case .app(let event): return event.elementSummary
        case .click(let event): return event.summary
        case .focus(let event): return event.summary
        }
    }

    var elementRole: String? {
        switch self {
        case .app(let event): return event.role
        case .click(let event): return event.role
        case .focus(let event): return event.role
        }
    }

    /// Only recorded metadata belongs here; rendering a row must not read live AX attributes.
    var details: String {
        switch self {
        case .app(let event):
            var parts = event.userInfo.map { "\($0.key): \($0.value)" }
            if event.scope == .simulatorContent { parts.insert("iOS sim", at: 0) }
            return parts.joined(separator: " · ")
        case .click(let event):
            return String(format: "(%.0f, %.0f)", event.location.x, event.location.y)
        case .focus:
            return ""
        }
    }

    static func merged(
        appEvents: [AXObserverWrapper.Event],
        clickEvents: [ClickTracker.ClickEvent],
        focusEvents: [SystemFocusTracker.FocusEvent]
    ) -> [UnifiedLogEvent] {
        var entries: [UnifiedLogEvent] = []
        entries.reserveCapacity(appEvents.count + clickEvents.count + focusEvents.count)
        for event in appEvents { entries.append(.app(event)) }
        for event in clickEvents { entries.append(.click(event)) }
        for event in focusEvents { entries.append(.focus(event)) }
        // Reverse-chronological — newest at the top, matching the prior per-source views.
        return entries.sorted { $0.timestamp > $1.timestamp }
    }
}
