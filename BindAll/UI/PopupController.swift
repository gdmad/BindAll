import AppKit
import SwiftUI

/// Shows a small floating panel near the mouse with result text, an optional original-text section,
/// a Copy button and a Close button. The panel can become key so Esc and text selection work.
@MainActor
final class PopupController {
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?

    func show(title: String, text: String, original: String? = nil, sourceLanguage: String? = nil, at screenPoint: NSPoint? = nil) {
        close()

        let model = PopupModel(
            title: title,
            text: text,
            original: original,
            sourceLanguage: sourceLanguage,
            onCopy: { TextInjector.copyToPasteboard(text) },
            onClose: { [weak self] in self?.close() }
        )

        let hosting = NSHostingController(rootView: PopupView(model: model))
        let panel = KeyablePanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 380, height: 260))
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        positionPanel(panel, near: screenPoint ?? NSEvent.mouseLocation)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    private func positionPanel(_ panel: NSPanel, near point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else {
            panel.setFrameOrigin(point)
            return
        }
        let size = panel.frame.size
        var origin = NSPoint(x: point.x + 12, y: point.y - size.height - 12)
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }
}

@MainActor
final class PopupModel: ObservableObject {
    let title: String
    @Published var text: String
    let original: String?
    let sourceLanguage: String?
    let onCopy: () -> Void
    let onClose: () -> Void
    @Published var copied = false
    @Published var showOriginal = false

    init(title: String, text: String, original: String?, sourceLanguage: String?,
         onCopy: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.title = title
        self.text = text
        self.original = original
        self.sourceLanguage = sourceLanguage
        self.onCopy = onCopy
        self.onClose = onClose
    }
}

struct PopupView: View {
    @ObservedObject var model: PopupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.title.isEmpty {
                Text(model.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(model.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.body)
            }
            .frame(maxHeight: .infinity)

            if model.showOriginal, let original = model.original {
                Divider()
                HStack {
                    Text("Original").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let lang = model.sourceLanguage {
                        Text(lang).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    Text(original)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            }

            HStack(spacing: 10) {
                if model.original != nil {
                    Toggle("Show Original", isOn: $model.showOriginal)
                        .toggleStyle(.checkbox)
                }
                Spacer()
                Button {
                    model.onClose()
                } label: {
                    Text("Close").frame(minWidth: 56)
                }
                .controlSize(.large)
                Button {
                    model.onCopy()
                    model.copied = true
                } label: {
                    Text(model.copied ? "Copied" : "Copy").frame(minWidth: 56)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding([.top, .horizontal], 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onExitCommand { model.onClose() }
    }
}
