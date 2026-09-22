import DictationEngine
import SwiftUI

/// The setup wizard until fully configured, then the ready screen.
struct MainWindowView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.readiness.isReady {
                ReadyView(model: model)
            } else {
                WizardView(model: model)
            }
        }
        .onAppear {
            model.openMainWindow = { [openWindow] in openWindow(id: "main") }
            model.refreshReadiness()
        }
    }
}

// MARK: - Wizard

struct WizardView: View {
    let model: AppModel
    @State private var keyDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set up \(AppIdentity.displayName)").font(.title2.bold())
                    Text("Three things stand between you and dictating anywhere on your Mac.")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    StepRow(
                        number: 1, title: "Microphone", done: model.readiness.microphone,
                        detail: "So it can hear you while the shortcut is active — and only then."
                    ) {
                        Button("Allow Microphone") { model.requestMicrophone() }
                    }
                    Divider()
                    StepRow(
                        number: 2, title: "Accessibility", done: model.readiness.accessibility,
                        detail: "For the global shortcut and to paste into the app you're using. Turn on \(AppIdentity.displayName) in the list that opens."
                    ) {
                        Button("Open Accessibility Settings") { model.requestAccessibility() }
                    }
                    Divider()
                    StepRow(
                        number: 3, title: "AssemblyAI API key", done: model.readiness.apiKey,
                        detail: "Stored in your Keychain. Get one at assemblyai.com/dashboard."
                    ) {
                        APIKeyField(model: model, draft: $keyDraft)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Optional").font(.headline)
                    ShortcutPickers(model: model)
                    Picker("Sound", selection: Bindable(model.prefs).soundPack) {
                        ForEach(SoundPack.allCases) { Text($0.displayName).tag($0) }
                    }
                    .onChange(of: model.prefs.soundPack) { model.settingsChanged() }
                }

                PrivacyNote()
            }
            .padding(28)
        }
    }
}

struct StepRow<Action: View>: View {
    let number: Int
    let title: String
    let done: Bool
    let detail: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.2)).frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 12, weight: .semibold))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !done { action().padding(.top, 2) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

struct APIKeyField: View {
    let model: AppModel
    @Binding var draft: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("Paste your API key", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(model.keyCheckInFlight ? "Checking…" : "Verify & Save", action: save)
                    .disabled(model.keyCheckInFlight || draft.isEmpty)
            }
            if let message = model.keyMessage {
                Text(message).font(.caption).foregroundStyle(message == "Key saved." ? Color.secondary : Color.red)
            }
        }
    }

    private func save() {
        let key = draft
        Task {
            await model.saveAPIKey(key)
            if model.keyMessage == "Key saved." { draft = "" }
        }
    }
}

struct ShortcutPickers: View {
    let model: AppModel

    var body: some View {
        @Bindable var prefs = model.prefs
        Picker("Shortcut", selection: $prefs.triggerKey) {
            ForEach(TriggerKey.allCases) { Text($0.displayName).tag($0) }
        }
        .onChange(of: prefs.triggerKey) { model.settingsChanged() }
        Picker("Activation", selection: $prefs.activationMode) {
            ForEach(ActivationMode.allCases) { Text($0.displayName).tag($0) }
        }
        .onChange(of: prefs.activationMode) { model.settingsChanged() }
    }
}

struct PrivacyNote: View {
    var body: some View {
        Text("""
        Audio goes to AssemblyAI over HTTPS with your own key. Each request also carries your recent \
        dictations and the text just before the cursor — nothing else about your screen. History lives \
        in memory only and is cleared on quit, so text dictated in one app can be sent as context with \
        a later dictation in another while the app runs. No telemetry.
        """)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Ready

struct ReadyView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            hero
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(.background.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 22) {
                StyleRow(model: model)
                RecentList(model: model)
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        // Esc cancels while the window is key.
        .background(
            Button("Cancel", action: model.cancel)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
        )
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Button(action: model.toggleFromUI) {
                ZStack {
                    Circle()
                        .fill(model.phase == .recording ? Color.red : Color.accentColor.opacity(model.phase.isBusy ? 0.5 : 1))
                        .frame(width: 76, height: 76)
                    Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.phase == .recording ? "Stop dictation" : "Start dictation")

            Text(model.phase.isCapturing ? "Listening…" : model.statusLine)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
            Text(model.phase.isCapturing ? "Press Esc to cancel" : "Works in any app with a text field")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.hotkeyActive {
                Text("The shortcut isn't listening yet — check the Accessibility permission.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 24)
    }
}

struct StyleRow: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output style").font(.headline)
            HStack(spacing: 8) {
                ForEach(Array(model.prefs.styleChoices.enumerated()), id: \.offset) { index, choice in
                    let active = model.prefs.activeStyleID == choice.id
                    Button { model.selectStyle(choice.id) } label: {
                        Text(choice.name)
                            .font(.callout.weight(active ? .semibold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(active ? Color.accentColor : Color.secondary.opacity(0.14)))
                            .foregroundStyle(active ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .help("⌘\(index + 1)")
                }
                Spacer()
                if model.prefs.profiles.isEmpty {
                    SettingsLink { Text("Add styles…") }.font(.callout)
                }
            }
            .disabled(model.phase.isBusy)
            if !model.prefs.enhanced {
                Text("Cleanup is off — you'll get the verbatim transcript.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RecentList: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent").font(.headline)
            if model.recent.isEmpty {
                Text("Your dictations show up here until you quit.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.recent.prefix(Timing.recentShown)) { record in
                    RecentRow(record: record)
                }
            }
        }
    }
}

struct RecentRow: View {
    let record: DictationRecord
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(record.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(record.verbatim == record.text ? record.text : "Verbatim: \(record.verbatim)")
            if hovering {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.text, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(record.styleName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    Text(record.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
        .onHover { hovering = $0; if !$0 { copied = false } }
    }
}
