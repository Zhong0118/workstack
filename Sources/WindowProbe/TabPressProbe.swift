import AppKit
import ApplicationServices

/// AX client for exactly one Button in the QA manager that launched this helper.
@MainActor enum TabPressProbe {
    static func run(parent: pid_t, tab: UUID) -> Int32 {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard parent == getppid(), Bundle.main.bundleIdentifier == "local.windowworkbench.qa.Fixture",
            let manager = NSRunningApplication(processIdentifier: parent), manager.bundleIdentifier == "local.windowworkbench.qa",
            manager.bundleURL?.resolvingSymlinksInPath().path
                == bundle.deletingLastPathComponent().appendingPathComponent("Product.app").path,
            !manager.isTerminated, AXIsProcessTrusted()
        else { return 77 }
        func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        let app = AXUIElementCreateApplication(parent)
        AXUIElementSetMessagingTimeout(app, 1)
        let wanted = "workstack.tab." + tab.uuidString
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(4) {
            var queue = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            var seen = Set<AXUIElement>()
            while let element = queue.popLast() {
                guard seen.insert(element).inserted else { continue }
                let identifier = value(element, kAXIdentifierAttribute) as? String
                if identifier == wanted, value(element, kAXRoleAttribute) as? String == kAXButtonRole {
                    guard parent == getppid(), !manager.isTerminated else { return 1 }
                    let start = ProcessInfo.processInfo.systemUptime
                    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                    print(start)
                    return result == .success ? 0 : 1
                }
                queue.append(contentsOf: (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        print("tab button missing")
        return 1
    }
}
