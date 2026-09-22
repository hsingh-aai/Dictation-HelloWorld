import AppKit
import DictationEngine
import Observation
import SwiftUI

@MainActor
@Observable
final class PillModel {
    var state = PillState.from(.idle)
}

/// A floating, non-activating panel: focus stays in the user's app. Draggable, origin persisted.
@MainActor
final class OverlayController {
    private let model = PillModel()
    private let meter: LevelMeter
    private let originKey: String
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    init(meter: LevelMeter, prefsOrigin originKey: String) {
        self.meter = meter
        self.originKey = originKey
    }

    func show(_ state: PillState) {
        dismissTask?.cancel()
        guard state.visible else { hide(); return }
        model.state = state
        let panel = self.panel ?? makePanel()
        if !panel.isVisible {
            panel.setFrameOrigin(origin())
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        if let delay = state.dismissAfter {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                // A new phase may have re-shown it mid-fade.
                if panel.alphaValue == 0 { panel.orderOut(nil) }
                panel.alphaValue = 1
            }
        })
    }

    private func origin() -> CGPoint {
        let saved = (UserDefaults.standard.array(forKey: originKey) as? [Double]).flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        let main = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return OverlayGeometry.origin(saved: saved, visibleFrames: NSScreen.screens.map(\.visibleFrame), main: main)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: OverlayGeometry.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PillView(model: model, meter: meter))
        let key = originKey
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated {
                guard let origin = panel?.frame.origin else { return }
                UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: key)
            }
        }
        self.panel = panel
        return panel
    }
}

struct PillView: View {
    let model: PillModel
    let meter: LevelMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        let state = model.state
        HStack(spacing: 10) {
            indicator(state)
            if state.showsRecTag {
                Text("REC").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.red)
            } else {
                Text(state.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            if state.showsMeter {
                MeterBars(meter: meter)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(
            Capsule().fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(state.tone == .error ? Color.red.opacity(0.7) : Color.primary.opacity(0.12)))
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .frame(width: OverlayGeometry.size.width, height: OverlayGeometry.size.height)
        .help(state.detail ?? state.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.detail.map { "\(state.label). \($0)" } ?? state.label)
        .onAppear { breathe = true }
    }

    @ViewBuilder
    private func indicator(_ state: PillState) -> some View {
        switch state.tone {
        case .recording:
            Circle().fill(.red).frame(width: 9, height: 9)
        case .working:
            Circle().fill(Color.accentColor)
                .frame(width: 9, height: 9)
                .opacity(state.breathing && !reduceMotion && breathe ? 0.3 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: breathe)
        case .error:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .neutral:
            Image(systemName: state.label == "Cancelled" ? "xmark.circle" : "checkmark.circle.fill").foregroundStyle(.secondary)
        }
    }
}

struct MeterBars: View {
    let meter: LevelMeter
    private let weights: [Float] = [0.55, 0.8, 1.0, 0.8, 0.55]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let level = CGFloat(meter.normalized)
            HStack(spacing: 3) {
                ForEach(weights.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 3, height: 4 + 16 * level * CGFloat(weights[index]))
                }
            }
            .frame(height: 20)
        }
    }
}
