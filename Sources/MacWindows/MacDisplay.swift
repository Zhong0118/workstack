import AppKit
import WorkbenchCore

@MainActor public enum MacDisplay {
    public static var all: [DisplayArea] {
        // AppKit screen coordinates point upwards. AX uses a top-left origin at the
        // upper edge of the menu-bar display, including for displays above or left.
        let top = CGDisplayBounds(CGMainDisplayID()).height
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let frame = screen.visibleFrame
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
            let id = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? number.stringValue
            return DisplayArea(
                id: id, name: screen.localizedName,
                frame: CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height))
        }
    }
}
