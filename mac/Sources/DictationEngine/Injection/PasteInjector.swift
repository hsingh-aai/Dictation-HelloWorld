import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum InjectionOutcome: Sendable, Equatable {
    case pasted
    /// The target was gone or wouldn't activate: the transcript is on the clipboard instead.
    case copied
}

public protocol TextInjecting: Sendable {
    @MainActor func inject(_ text: String, into target: FocusSnapshot) async -> InjectionOutcome
}

/// Where the last paste landed — the separator's fallback when prior text is unreadable.
public struct LastPaste: Sendable, Equatable {
    public var bundleID: String?
    public var windowTitle: String?
    public var text: String
}

public enum Separator {
    /// Consecutive dictations join with a leading space. When the prior text is unreadable,
    /// fall back to the last paste — only when app **and** window title match, so it tracks
    /// "the same window", not "the same process" (one browser PID hosts many tabs).
    public static func leading(for text: String, context: FocusSnapshot, lastPaste: LastPaste?) -> String {
        guard let first = text.first, !first.isWhitespace, !",.;:!?)]}".contains(first) else { return "" }
        if let prior = context.priorText {
            guard let last = prior.last else { return "" }
            return last.isWhitespace || "([{\"'“‘/-".contains(last) ? "" : " "
        }
        guard let lastPaste, let bundleID = context.bundleID,
              lastPaste.bundleID == bundleID, lastPaste.windowTitle == context.windowTitle,
              let last = lastPaste.text.last, !last.isWhitespace
        else { return "" }
        return " "
    }
}

/// Clipboard paste, always: activate → snapshot → write → ⌘V → (chained) settle → restore.
@MainActor
public final class PasteInjector: TextInjecting {
    private var tail: Task<Void, Never>?

    public init() {}

    public func inject(_ text: String, into target: FocusSnapshot) async -> InjectionOutcome {
        // Serialize back-to-back inserts, so a second paste can't snapshot the first one's text.
        await tail?.value

        let pasteboard = NSPasteboard.general
        guard AXIsProcessTrusted(), let pid = target.pid,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated
        else {
            Self.write(text, to: pasteboard)
            return .copied
        }

        if !app.isActive {
            app.activate()
            let deadline = Date().addingTimeInterval(Timing.activationWait)
            while !app.isActive, Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard app.isActive else {
                Self.write(text, to: pasteboard)
                return .copied
            }
        }

        let snapshot = PasteboardSnapshot.take(pasteboard)
        Self.write(text, to: pasteboard)
        let ours = pasteboard.changeCount
        guard Self.postCommandV() else { return .copied }

        tail = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Timing.pasteSettle * 1_000_000_000))
            // Only restore if nothing else claimed the clipboard in the meantime.
            if pasteboard.changeCount == ours { snapshot.restore(to: pasteboard) }
        }
        return .pasted
    }

    private static func write(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Posted to the annotated session tap: it honours exactly these flags instead of OR-ing in
    /// live hardware modifiers, so a still-held trigger can't turn ⌘V into another combo.
    private static func postCommandV() -> Bool {
        let vKey: CGKeyCode = 0x09   // kVK_ANSI_V
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand   // a key-up without ⌘ reads as the modifier released mid-chord
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}

/// Conservative clipboard snapshot. "Unreadable" (nil) is distinct from "empty", and the
/// replacement items are built before clearing, so a snapshot that can't be reproduced leaves
/// the clipboard alone rather than emptying it.
enum PasteboardSnapshot {
    case unreadable
    case empty
    case items([[NSPasteboard.PasteboardType: Data]])

    @MainActor
    static func take(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        guard let items = pasteboard.pasteboardItems else { return .unreadable }
        if items.isEmpty { return .empty }
        var copied: [[NSPasteboard.PasteboardType: Data]] = []
        for item in items {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            var complete = true
            for type in item.types {
                if let data = item.data(forType: type) { representations[type] = data } else { complete = false }
            }
            // Promised (lazily provided) representations can't be copied; degrade to plain text.
            if !complete {
                guard let string = item.string(forType: .string) else { return .unreadable }
                representations = [.string: Data(string.utf8)]
            }
            copied.append(representations)
        }
        return .items(copied)
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard) {
        switch self {
        case .unreadable:
            return
        case .empty:
            pasteboard.clearContents()
        case .items(let items):
            let replacements = items.map { representations -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: type) }
                return item
            }
            pasteboard.clearContents()
            pasteboard.writeObjects(replacements)
        }
    }
}
