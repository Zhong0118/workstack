import Foundation

public enum WindowKind: String, Codable, Sendable { case normal, dialog, panel, other }

public struct WindowIdentity: Hashable, Codable, Sendable {
    public var bundleID: String
    public var pid: Int32
    public var launched: Date?
    public var identifier: String?
    public init(bundleID: String, pid: Int32, launched: Date?, identifier: String?) {
        self.bundleID = bundleID
        self.pid = pid
        self.launched = launched
        self.identifier = identifier
    }
    public var permitsRecovery: Bool {
        !bundleID.isEmpty && launched != nil && identifier?.isEmpty == false
    }
}

public struct LiveWindow: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var bundleID: String
    public var appName: String
    public var title: String
    public var frame: CGRect
    public var kind: WindowKind
    public var minimized, fullscreen, movable, resizable, minimizable, focused: Bool
    public var identity: WindowIdentity
    public init(
        id: UUID, bundleID: String, appName: String, title: String, frame: CGRect, kind: WindowKind,
        minimized: Bool, fullscreen: Bool, movable: Bool, resizable: Bool, minimizable: Bool, focused: Bool,
        identity: WindowIdentity
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.kind = kind
        self.minimized = minimized
        self.fullscreen = fullscreen
        self.movable = movable
        self.resizable = resizable
        self.minimizable = minimizable
        self.focused = focused
        self.identity = identity
    }
}

public struct DisplayArea: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var frame: CGRect
    public init(id: String, name: String, frame: CGRect) {
        self.id = id
        self.name = name
        self.frame = frame
    }
}
