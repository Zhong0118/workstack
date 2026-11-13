import SwiftUI
@preconcurrency import ScreenCaptureKit
import WorkbenchCore

struct PreviewButton: View {
    @EnvironmentObject var model: Workbench
    let member: UUID
    @State private var showing = false
    var body: some View {
        if model.state.prefs.previews {
            Button {
                showing = true
            } label: {
                Label(tr("Preview window"), systemImage: "eye")
            }
            .popover(isPresented: $showing) {
                WindowPreview(member: member).environmentObject(model)
            }
        }
    }
}

@MainActor
private struct WindowPreview: View {
    @EnvironmentObject var model: Workbench
    let member: UUID
    @State var image: NSImage?
    @State var failed = false
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if failed {
                Text(tr("Preview unavailable")).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }.frame(width: 320, height: 220).padding(8)
            .task(id: member) {
                guard model.state.prefs.previews, CGPreflightScreenCaptureAccess(),
                    let w = model.windows.first(where: { $0.id == member }), !w.minimized,
                    !w.title.isEmpty,
                    model.windows.filter({
                        $0.identity.pid == w.identity.pid && $0.title == w.title && $0.frame.roughlyEquals(w.frame)
                    }).count == 1
                else { failed = true; return }
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    let matches = content.windows.filter {
                        $0.owningApplication?.processID == w.identity.pid && $0.title == w.title && $0.frame.roughlyEquals(w.frame)
                            && $0.windowLayer == 0
                    }
                    guard matches.count == 1, let window = matches.first, !Task.isCancelled else { failed = true; return }
                    let config = SCStreamConfiguration()
                    let scale = min(1, 640 / max(1, window.frame.width), 440 / max(1, window.frame.height))
                    config.width = max(1, Int(window.frame.width * scale))
                    config.height = max(1, Int(window.frame.height * scale))
                    config.showsCursor = false
                    let bitmap = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                    guard !Task.isCancelled else { return }
                    image = NSImage(cgImage: bitmap, size: .zero)
                } catch { failed = true }
            }
            .onDisappear { image = nil }
    }
}
