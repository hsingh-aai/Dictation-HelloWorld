import DictationEngine
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettings(model: model)
                .tabItem { Label("Shortcuts", systemImage: "text.badge.plus") }
            AdvancedSettings(model: model)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 520, height: 500)
    }
}

/// The everyday setup: key, shortcut, cue, key terms, input device.
struct GeneralSettings: View {
    let model: AppModel
    @State private var keyDraft = ""
    @State private var devices = InputDevice.all()

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("API key") {
                if let masked = model.maskedKey {
                    LabeledContent("Current key", value: masked)
                }
                APIKeyField(model: model, draft: $keyDraft)
            }
            Section("Shortcut") {
                ShortcutPickers(model: model)
                Text(prefs.activationMode.readout(for: prefs.triggerKey)).font(.caption).foregroundStyle(.secondary)
            }
            Section("Sound") {
                Picker("Start and stop cue", selection: $prefs.soundPack) {
                    ForEach(SoundPack.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: prefs.soundPack) { model.settingsChanged() }
            }
            Section {
                TextEditor(text: $prefs.keytermsText)
                    .font(.body)
                    .frame(minHeight: 60)
                let fitted = KeytermFitter.fit(KeytermFitter.parse(prefs.keytermsText))
                let parsed = KeytermFitter.parse(prefs.keytermsText)
                Text(fitted.count < Set(parsed).count
                     ? "Sending the first \(fitted.count) terms — the API allows 100 terms and 2048 characters."
                     : "Names, jargon and spellings to favour. Separate with commas or new lines.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Key terms")
            }
            Section("Microphone") {
                Picker("Input device", selection: $prefs.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(devices) { Text($0.name).tag(String?.some($0.id)) }
                    if let pinned = prefs.inputDeviceUID, !devices.contains(where: { $0.id == pinned }) {
                        Text("Pinned device (not connected)").tag(String?.some(pinned))
                    }
                }
                .onAppear { devices = InputDevice.all() }
            }
        }
        .formStyle(.grouped)
    }
}

/// Spoken shortcuts: say the trigger, the expansion is pasted instead.
struct ShortcutSettings: View {
    let model: AppModel

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section {
                ForEach($prefs.snippets) { $snippet in
                    HStack(spacing: 8) {
                        TextField("Say…", text: $snippet.trigger)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Paste…", text: $snippet.expansion)
                            .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            prefs.snippets.removeAll { $0.id == snippet.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add shortcut") {
                    prefs.snippets.append(Snippet(trigger: "", expansion: ""))
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Say a shortcut on its own or mid-sentence. Case, punctuation and \"dot\" don't matter, so \"personal cal dot com\" matches \"personal cal.com\".")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Cleanup switch, style profiles, developer mode, reset.
struct AdvancedSettings: View {
    let model: AppModel
    @State private var confirmReset = false

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section {
                Toggle("Clean up dictation", isOn: $prefs.enhanced)
                Text("Off pastes the verbatim transcript. The rewrite still runs on AssemblyAI's side; this picks which text you get.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach($prefs.profiles) { $profile in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Name", text: $profile.name).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                            Spacer()
                            Button(role: .destructive) {
                                prefs.profiles.removeAll { $0.id == profile.id }
                                if prefs.activeStyleID == profile.id { prefs.activeStyleID = nil }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                        TextField("Preferences, e.g. “always lowercase, no trailing period”", text: $profile.preferences, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                        let used = profile.preferences.utf8.count
                        if used > Instruction.styleBudgetBytes {
                            Text("Only the first \(Instruction.styleBudgetBytes) characters are sent.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if prefs.profiles.count < StyleProfile.maxCount {
                    Button("Add style") {
                        prefs.profiles.append(StyleProfile(name: "Style \(prefs.profiles.count + 1)", preferences: ""))
                    }
                }
            } header: {
                Text("Output styles")
            } footer: {
                Text("Choose the active style on the main window (⌘1–⌘5). Only the active one is sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Developer") {
                Toggle("Developer mode", isOn: $prefs.developerMode)
                if prefs.developerMode {
                    Text("Logs completed dictations and failures to \(model.logsDirectory.path).")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show logs in Finder") {
                        try? FileManager.default.createDirectory(at: model.logsDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([model.logsDirectory])
                    }
                }
            }
            Section {
                PrivacyNote()
                Button("Reset \(AppIdentity.displayName)…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset everything?", isPresented: $confirmReset) {
            Button("Reset and Restart", role: .destructive) { model.resetEverything() }
        } message: {
            Text("Clears settings, the saved API key, the Microphone and Accessibility grants and the logs, then restarts into setup.")
        }
    }
}
