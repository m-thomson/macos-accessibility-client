//
//  UnifiedLogView.swift
//  MacOSAccessibilityClient
//
//  Written by Andrew Benson.
//  Copyright (c) 2026 Nuclear Cyborg Corp.
//

import SwiftUI

/// One chronological table for app notifications, global clicks, and global focus changes.
/// Selecting a row reveals its element in the tree, switching apps when necessary.
struct UnifiedLogView: View {
    let entries: [UnifiedLogEvent]
    let subscriptionError: String?

    @Binding var clicksEnabled: Bool
    @Binding var focusEnabled: Bool

    let onClear: () -> Void
    let onElementClick: (UnifiedLogEvent) -> Void

    @State private var selectedEntryID: UnifiedLogEvent.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let subscriptionError {
                subscriptionErrorBanner(subscriptionError)
            }
            Divider()
            eventTable
        }
        .onChange(of: selectedEntryID) { _, id in
            guard let entry = entries.first(where: { $0.id == id }), entry.element != nil else { return }
            onElementClick(entry)
        }
        .onChange(of: entries.isEmpty) { _, isEmpty in
            if isEmpty { selectedEntryID = nil }
        }
    }

    private var eventTable: some View {
        Table(entries, selection: $selectedEntryID) {
            TableColumn("Time") { entry in
                EventCellText(text: Formatting.timestamp.string(from: entry.timestamp))
                    .foregroundStyle(.secondary)
            }
            .width(min: 85, ideal: 100)

            TableColumn("Scope") { entry in
                EventCellText(text: entry.scopeDescription)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Process") { entry in
                ProcessCell(process: entry.process)
            }
            .width(min: 110, ideal: 175)

            TableColumn("Event") { entry in
                EventCell(entry: entry)
            }
            .width(min: 120, ideal: 200)

            TableColumn("Element") { entry in
                ElementCell(entry: entry)
            }
            .width(min: 140, ideal: 250)

            TableColumn("Details") { entry in
                EventCellText(text: entry.details.isEmpty ? "—" : entry.details)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 160)
        }
        .tableStyle(.inset)
        .font(.system(.caption, design: .monospaced))
        .overlay {
            if entries.isEmpty {
                Text("No activity yet. Pick an app, or enable click / focus tracking above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Events (\(entries.count))")
                .font(.headline)
            Spacer()
            Toggle(isOn: $clicksEnabled) {
                Label("Capture clicks", systemImage: "cursorarrow.click")
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            Toggle(isOn: $focusEnabled) {
                Label("Track focus", systemImage: "scope")
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            Button("Clear", action: onClear)
                .controlSize(.small)
                .disabled(entries.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func subscriptionErrorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Subscription failed: \(message)")
                .font(.caption)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15))
    }
}

/// Keep recorded text to one visual line; hovering exposes the original, unabridged text.
private struct EventCellText: View {
    let text: String

    var body: some View {
        Text(verbatim: text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(text)
    }
}

private struct ProcessCell: View {
    let process: EventProcess

    var body: some View {
        HStack(spacing: 5) {
            EventCellText(text: process.name ?? "Unknown")
            if let pid = process.pid {
                Text(verbatim: "(\(pid))")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .help(process.description)
    }
}

private struct EventCell: View {
    let entry: UnifiedLogEvent

    var body: some View {
        HStack(spacing: 6) {
            eventIcon
                .frame(width: 14)
                .accessibilityHidden(true)
            EventCellText(text: entry.eventDescription)
        }
    }

    @ViewBuilder
    private var eventIcon: some View {
        switch entry {
        case .app(let event):
            Circle()
                .fill(NotificationFamily.family(for: event.notification).color)
                .frame(width: 7, height: 7)
        case .click(let event):
            Image(systemName: event.isRightClick ? "cursorarrow.click.badge.clock" : "cursorarrow.click")
                .font(.system(size: 11))
                .foregroundStyle(.tint)
        case .focus:
            Image(systemName: "scope")
                .font(.system(size: 11))
                .foregroundStyle(.tint)
        }
    }
}

private struct ElementCell: View {
    let entry: UnifiedLogEvent

    var body: some View {
        HStack(spacing: 6) {
            if entry.element != nil {
                let family = RoleFamily.family(for: entry.elementRole)
                Image(systemName: family.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(family.color)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
            EventCellText(text: entry.elementSummary)
        }
    }
}
