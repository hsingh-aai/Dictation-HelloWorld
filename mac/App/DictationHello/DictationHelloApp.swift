import DictationEngine
import SwiftUI

struct DictationHelloApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window(AppIdentity.displayName, id: "main") {
            MainWindowView(model: model)
                .frame(minWidth: 480, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 540, height: 660)

        Settings {
            SettingsView(model: model)
        }

        // Layered on the Dock app rather than replacing it: the notch can hide a status item,
        // so nothing may depend on it.
        MenuBarExtra {
            MenuBarMenu(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
    }
}

struct MenuBarMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusLine)
        Divider()
        Button("Open \(AppIdentity.displayName)") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit \(AppIdentity.displayName)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
