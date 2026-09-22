import AppKit
import AVFoundation
import DictationEngine
import Observation

/// The one coordinator composing the engine. Views read it; nothing else decides anything.
@MainActor
@Observable
final class AppModel {
    let prefs = Preferences()
    let meter = LevelMeter()

    private(set) var phase: Phase = .idle
    private(set) var readiness = SetupReadiness(microphone: false, accessibility: false, apiKey: false)
    /// Memory only, cleared on quit.
    private(set) var recent: [DictationRecord] = []
    private(set) var keyCheckInFlight = false
    private(set) var keyMessage: String?
    private(set) var hotkeyActive = false

    @ObservationIgnored private let client = DictationClient(appName: AppIdentity.userAgentName, version: AppIdentity.version)
    @ObservationIgnored private let keychain = AppIdentity.keychain
    @ObservationIgnored private let devLog = DevLog(appName: AppIdentity.displayName, enabled: { Preferences.developerModeEnabled() })
    @ObservationIgnored private var apiKey: String?
    @ObservationIgnored let pipeline: DictationPipeline
    @ObservationIgnored private let hotkey: HotkeyMonitor
    @ObservationIgnored private let cues = CuePlayer()
    @ObservationIgnored private let overlay: OverlayController
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored var openMainWindow: (() -> Void)?

    init() {
        hotkey = HotkeyMonitor(key: prefs.triggerKey, mode: prefs.activationMode)
        apiKey = keychain.read()
        let meter = self.meter
        let owner = WeakOwner()
        pipeline = DictationPipeline(
            transcriber: client,
            micFactory: AVCaptureRecorderFactory(meter: meter, pinnedDeviceUID: { Preferences.pinnedDeviceUID() }),
            injector: PasteInjector(),
            focus: AXFocusReader(),
            devLog: devLog,
            settings: {
                await MainActor.run { owner.model?.requestSettings() ?? RequestSettings(apiKey: nil) }
            }
        )
        overlay = OverlayController(meter: meter, prefsOrigin: SettingKey.overlayOrigin.defaultsKey)
        owner.model = self
        cues.load(prefs.soundPack)

        hotkey.onAction = { [weak self] action in self?.hotkeyAction(action) }
        refreshReadiness()
        startPolling()

        let phases = pipeline.phases
        Task { [weak self] in
            for await phase in phases { self?.apply(phase) }
        }
    }

    // MARK: Settings the pipeline reads at press

    private func requestSettings() -> RequestSettings {
        let profile = prefs.activeProfile
        return RequestSettings(
            apiKey: apiKey,
            keyterms: KeytermFitter.parse(prefs.keytermsText),
            snippets: prefs.snippets,
            styleName: profile?.name ?? "Default",
            styleInstruction: profile?.preferences,
            enhanced: prefs.enhanced
        )
    }

    func settingsChanged() {
        hotkey.configure(key: prefs.triggerKey, mode: prefs.activationMode)
        cues.load(prefs.soundPack)
    }

    // MARK: Trigger

    private func hotkeyAction(_ action: TriggerGate.Action) {
        switch action {
        case .start:
            // A press the pipeline would refuse must not leave the gate armed or latched.
            if phase.isBusy { hotkey.dictationEnded(); return }
            pipeline.submit(.press)
        case .stop: pipeline.submit(.release)
        case .cancel: pipeline.submit(.cancelRecording)
        case .none: break
        }
    }

    func cancel() { pipeline.submit(.cancel) }

    /// For the ready screen's button: same pipeline, no hotkey involved.
    func toggleFromUI() {
        switch phase {
        case .recording: pipeline.submit(.release)
        case .connecting: pipeline.submit(.cancel)
        default: if !phase.isBusy { pipeline.submit(.press) }
        }
    }

    // MARK: Phases

    private func apply(_ new: Phase) {
        let old = phase
        if let cue = CueEdge.detect(from: old, to: new) { cues.play(cue) }
        phase = new
        overlay.show(PillState.from(new))
        if new.isTerminal || new == .idle { hotkey.dictationEnded() }
        switch new {
        case .pasted(let record), .noTarget(let record):
            if !record.sensitive {
                recent.insert(record, at: 0)
                if recent.count > Timing.historyCap { recent.removeLast() }
            }
        case .failed(let failure) where failure.isSetup:
            openMainWindow?()
            NSApp.activate()
        default:
            break
        }
    }

    // MARK: Style

    func selectStyle(_ id: UUID?) {
        guard !phase.isBusy else { return }   // locked during capture
        prefs.activeStyleID = id
    }

    // MARK: Permissions and setup

    func refreshReadiness() {
        let new = SetupReadiness(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted(),
            apiKey: !(apiKey ?? "").isEmpty
        )
        if new.accessibility, !hotkey.isRunning { hotkey.start() }
        if !new.accessibility, hotkey.isRunning { hotkey.stop() }
        hotkeyActive = hotkey.isRunning
        if new != readiness { readiness = new }
    }

    /// Brisk during setup, lazy once ready. A revoked grant is an edge that pulls a configured
    /// app back into onboarding, by the same readiness gate.
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let ready = self?.readiness.isReady ?? true
                try? await Task.sleep(nanoseconds: ready ? 5_000_000_000 : 1_000_000_000)
                self?.refreshReadiness()
            }
        }
    }

    func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refreshReadiness() }
            }
        default:
            openPrivacyPane("Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openPrivacyPane("Privacy_Accessibility") }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Validates before saving — an unverified key never persists.
    func saveAPIKey(_ raw: String) async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { keyMessage = "Paste a key first."; return }
        keyCheckInFlight = true
        keyMessage = nil
        defer { keyCheckInFlight = false }
        switch await client.validate(apiKey: key) {
        case .valid:
            guard keychain.write(key) else { keyMessage = "Couldn't save the key to the Keychain."; return }
            apiKey = key
            keyMessage = "Key saved."
        case .invalid(let message):
            keyMessage = "AssemblyAI rejected that key: \(message)"
        case .unreachable(let message):
            keyMessage = "Couldn't reach AssemblyAI to check the key (\(message))."
        }
        refreshReadiness()
    }

    var maskedKey: String? {
        guard let apiKey, apiKey.count > 8 else { return nil }
        return "••••••••" + apiKey.suffix(4)
    }

    // MARK: Reset

    /// Clears settings, the Keychain key, the TCC grants and the logs, then restarts. The restart
    /// is load-bearing: macOS prompts for a grant once per process.
    func resetEverything() {
        pipeline.submit(.cancel)
        prefs.removeAll()
        keychain.delete()
        devLog.deleteAll()
        for service in ["Microphone", "Accessibility"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, AppIdentity.bundleID]
            try? process.run()
            process.waitUntilExit()
        }
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    var logsDirectory: URL { devLog.directory }

    // MARK: Display helpers

    var menuBarSymbol: String {
        switch phase {
        case .recording: "mic.fill"
        case .connecting, .transcribing, .injecting: "ellipsis.circle"
        default: "mic"
        }
    }

    var statusLine: String {
        switch phase {
        case .connecting: "Connecting…"
        case .recording: "Listening…"
        case .transcribing, .injecting: "Transcribing…"
        default: readiness.isReady ? prefs.activationMode.readout(for: prefs.triggerKey) : "Finish setup to start dictating"
        }
    }
}

/// Lets the pipeline's settings closure reach the model without capturing `self` during init.
private final class WeakOwner: @unchecked Sendable {
    @MainActor weak var model: AppModel?
}
