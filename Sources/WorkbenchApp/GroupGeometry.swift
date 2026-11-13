import Foundation
import WorkbenchCore

extension Workbench {
    /// Capture user-positioned floating windows on workspace departure. Coordinates are display-relative.
    func captureFloating(in workspace: Workspace?, document: inout WorkbenchState) {
        guard let workspace else { return }
        var frames = document.floatingFrames ?? [:]
        for id in workspace.groups.flatMap(\.floating) {
            guard let w = windows.first(where: { $0.id == id && !$0.minimized && !$0.fullscreen }),
                let display = displays.max(by: { overlap($0.frame, w.frame) < overlap($1.frame, w.frame) }),
                display.frame.intersects(w.frame), display.frame.width > 0, display.frame.height > 0
            else { continue }
            let area = display.frame
            frames[id] = FloatingFrame(
                display: display.id,
                relative: CGRect(
                    x: (w.frame.minX - area.minX) / area.width, y: (w.frame.minY - area.minY) / area.height,
                    width: w.frame.width / area.width, height: w.frame.height / area.height))
        }
        document.floatingFrames = frames
    }
    func floatingFrame(_ id: UUID, group: WindowGroup, document: WorkbenchState) -> CGRect? {
        guard let saved = document.floatingFrames?[id],
            let monitor = displays.first(where: { $0.id == (group.displayID ?? saved.display) }) ?? displays.first
        else { return nil }
        let area = monitor.frame
        let width = min(area.width, max(1, area.width * saved.relative.width))
        let height = min(area.height, max(1, area.height * saved.relative.height))
        return CGRect(
            x: max(area.minX, min(area.maxX - width, area.minX + area.width * saved.relative.minX)),
            y: max(area.minY, min(area.maxY - height, area.minY + area.height * saved.relative.minY)),
            width: width, height: height
        ).integral
    }
    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let rect = a.intersection(b)
        return rect.isNull ? 0 : rect.width * rect.height
    }
}
