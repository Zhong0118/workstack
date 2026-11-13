import Foundation

/// Discovery includes observation because both use the same ephemeral window handles.
@MainActor
public protocol WindowDiscovery: AnyObject {
    var onChange: (([LiveWindow]) -> Void)? { get set }
    func start()
    func stop()
    func refresh()
}

@MainActor
public protocol PermissionProvider: AnyObject {
    var trusted: Bool { get }
    func requestPermission()
}

@MainActor
public protocol DisplayController {
    static var all: [DisplayArea] { get }
}
