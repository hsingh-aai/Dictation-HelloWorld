import Foundation

public struct DictationRecord: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let text: String
    public let verbatim: String
    public let styleName: String
    public let date: Date
    /// Dictated into a password field: kept out of history, Recent and logs.
    public let sensitive: Bool

    public init(id: UUID = UUID(), text: String, verbatim: String, styleName: String, sensitive: Bool = false, date: Date = Date()) {
        self.id = id
        self.text = text
        self.verbatim = verbatim
        self.styleName = styleName
        self.sensitive = sensitive
        self.date = date
    }
}

public struct DictationFailure: Sendable, Equatable {
    /// Classified once, in the engine: setup failures route to settings, the rest flash.
    public let isSetup: Bool
    public let name: String
    public let message: String

    public init(_ error: DictationError) {
        isSetup = error.isSetup
        name = error.name
        message = error.errorDescription ?? "Something went wrong."
    }
}

public enum Phase: Sendable, Equatable {
    case idle
    case connecting
    case recording
    case transcribing
    case injecting
    case pasted(DictationRecord)
    case noTarget(DictationRecord)
    case failed(DictationFailure)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .pasted, .noTarget, .failed, .cancelled: true
        default: false
        }
    }

    public var isCapturing: Bool { self == .connecting || self == .recording }

    /// Busy covers `injecting` too: hosts read idle as "dismiss".
    public var isBusy: Bool {
        switch self {
        case .connecting, .recording, .transcribing, .injecting: true
        default: false
        }
    }
}

/// Phase → overlay pill, as a pure value type so the view has nothing to decide.
public struct PillState: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case neutral, recording, working, error }

    public var label: String
    public var tone: Tone
    /// The meter and REC tag are "speak now" cues — never shown while the route is coming up.
    public var showsMeter: Bool
    public var showsRecTag: Bool
    public var breathing: Bool
    public var detail: String?
    /// nil = stays up until the phase changes.
    public var dismissAfter: TimeInterval?
    public var visible: Bool

    public static func from(_ phase: Phase) -> PillState {
        switch phase {
        case .idle:
            PillState(label: "", tone: .neutral, showsMeter: false, showsRecTag: false, breathing: false, dismissAfter: nil, visible: false)
        case .connecting:
            PillState(label: "Connecting…", tone: .working, showsMeter: false, showsRecTag: false, breathing: true, dismissAfter: nil, visible: true)
        case .recording:
            PillState(label: "REC", tone: .recording, showsMeter: true, showsRecTag: true, breathing: false, dismissAfter: nil, visible: true)
        case .transcribing, .injecting:
            PillState(label: "Transcribing…", tone: .working, showsMeter: false, showsRecTag: false, breathing: true, dismissAfter: nil, visible: true)
        case .pasted:
            PillState(label: "Pasted", tone: .neutral, showsMeter: false, showsRecTag: false, breathing: false, dismissAfter: 0.9, visible: true)
        case .noTarget:
            PillState(label: "Copied to clipboard", tone: .neutral, showsMeter: false, showsRecTag: false, breathing: false, dismissAfter: 1.6, visible: true)
        case .failed(let failure):
            PillState(label: failure.isSetup ? "Finish setup" : "Failed", tone: .error, showsMeter: false, showsRecTag: false, breathing: false, detail: failure.message, dismissAfter: 3.0, visible: true)
        case .cancelled:
            PillState(label: "Cancelled", tone: .neutral, showsMeter: false, showsRecTag: false, breathing: false, dismissAfter: 0.7, visible: true)
        }
    }
}

public enum Cue: Sendable, Equatable { case start, stop }

public enum CueEdge {
    /// Start fires on connecting→recording, not on the press: on Bluetooth those are 1–2 s apart
    /// and speech in between is unrecoverable. Stop fires as recording ends (claimed at key-up).
    public static func detect(from old: Phase, to new: Phase) -> Cue? {
        if new == .recording, old != .recording { return .start }
        if old == .recording, new == .transcribing { return .stop }
        return nil
    }
}

/// Overlay geometry, pure so it's testable without a screen.
public enum OverlayGeometry {
    public static let size = CGSize(width: 260, height: 48)
    public static let bottomInset: CGFloat = 72

    /// Bottom-centre of the visible frame, or the saved origin when it still lands on screen.
    public static func origin(saved: CGPoint?, visibleFrames: [CGRect], main: CGRect) -> CGPoint {
        if let saved {
            let frame = CGRect(origin: saved, size: size)
            if visibleFrames.contains(where: { $0.intersects(frame.insetBy(dx: 20, dy: 10)) }) { return saved }
        }
        return CGPoint(x: (main.midX - size.width / 2).rounded(), y: (main.minY + bottomInset).rounded())
    }
}
