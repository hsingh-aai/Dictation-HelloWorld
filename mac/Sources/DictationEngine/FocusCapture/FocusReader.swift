import AppKit
import ApplicationServices
import Foundation

/// What was focused at press. Only `priorText` ever goes on the wire; the rest stays local
/// (paste target, separator logic, developer-mode logs).
public struct FocusSnapshot: Sendable, Equatable, Codable {
    public var pid: pid_t?
    public var bundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var fieldRole: String?
    /// Text immediately before the cursor. nil = unreadable (distinct from "" = start of field).
    public var priorText: String?
    public var isSecure: Bool

    public init(
        pid: pid_t? = nil, bundleID: String? = nil, appName: String? = nil, windowTitle: String? = nil,
        fieldRole: String? = nil, priorText: String? = nil, isSecure: Bool = false
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.fieldRole = fieldRole
        self.priorText = priorText
        self.isSecure = isSecure
    }
}

public protocol FocusReading: Sendable {
    func read() async -> FocusSnapshot
}

public struct AXFocusReader: FocusReading {
    public init() {}

    /// The frontmost app is read immediately; the AX part is bounded to 500 ms, so an
    /// unresponsive app costs the transcript its priming, never a stall.
    public func read() async -> FocusSnapshot {
        let app = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        let base = FocusSnapshot(pid: app?.processIdentifier, bundleID: app?.bundleIdentifier, appName: app?.localizedName)
        guard let pid = base.pid, AXIsProcessTrusted() else { return base }
        let once = Once()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let detail = Self.readAX(pid: pid)
                var full = base
                full.windowTitle = detail.windowTitle
                full.fieldRole = detail.fieldRole
                full.priorText = detail.priorText
                full.isSecure = detail.isSecure
                if once.claim() { continuation.resume(returning: full) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Timing.contextReadBudget) {
                if once.claim() { continuation.resume(returning: base) }
            }
        }
    }

    private static func readAX(pid: pid_t) -> (windowTitle: String?, fieldRole: String?, priorText: String?, isSecure: Bool) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(Timing.contextReadBudget))
        let window: AXUIElement? = attribute(app, kAXFocusedWindowAttribute)
        let title: String? = window.flatMap { attribute($0, kAXTitleAttribute) }
        guard let field: AXUIElement = attribute(app, kAXFocusedUIElementAttribute) else {
            return (title, nil, nil, false)
        }
        let role: String? = attribute(field, kAXRoleAttribute)
        let subrole: String? = attribute(field, kAXSubroleAttribute)
        // Never read a password field.
        if subrole == kAXSecureTextFieldSubrole as String || role == "AXSecureTextField" {
            return (title, role, nil, true)
        }
        guard let value: String = attribute(field, kAXValueAttribute) else { return (title, role, nil, false) }
        var prior: String?
        if let rangeValue: AXValue = attribute(field, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) {
                let ns = value as NSString
                let location = max(0, min(range.location, ns.length))
                prior = ns.substring(to: location)
            }
        }
        // Keep only a generous tail; the prompt fitter owns the real cap.
        if let text = prior, text.unicodeScalars.count > Wire.sttPromptCapScalars {
            prior = String(String.UnicodeScalarView(text.unicodeScalars.suffix(Wire.sttPromptCapScalars)))
        }
        return (title, role, prior, false)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self, CFGetTypeID(value) == AXUIElementGetTypeID() { return (value as! T) }  // CF type
        if T.self == AXValue.self, CFGetTypeID(value) == AXValueGetTypeID() { return (value as! T) }          // CF type
        return value as? T
    }
}

/// Resume-once guard for racing a blocking call against a deadline.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
