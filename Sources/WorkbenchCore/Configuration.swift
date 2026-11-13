import Foundation

public struct AssignmentRule: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var bundleID: String
    public var titleContains: String
    public var group: UUID
    public init(bundleID: String, titleContains: String, group: UUID) {
        self.bundleID = bundleID
        self.titleContains = titleContains
        self.group = group
    }
}

public struct KeyChord: Codable, Equatable, Hashable, Sendable {
    public var key, modifiers: UInt32
    public init(key: UInt32, modifiers: UInt32) { self.key = key; self.modifiers = modifiers }
    public var isValid: Bool {
        key < 128 && modifiers & ~UInt32(0x1B00) == 0 && modifiers & 0x1900 != 0 && !(key == 48 && modifiers & 0x0100 != 0)
    }
}

public enum WorkspaceSwitchMode: String, CaseIterable, Sendable {
    case focus, arrange, concentrate
}

public struct Preferences: Codable, Equatable, Sendable {
    // Retained in v1 exports for compatibility with existing installations.
    public var language = "zh-Hans"
    public var theme = "system"
    public var menuBar = true
    public var previews = false
    public var diagnosticsEnabled: Bool?
    public var enableAnimations = true
    public var compact = false
    public var switchLayouts = true
    public var hidePrevious = false
    // Keep the v1 JSON keys so saved workspaces and exported configurations remain readable.
    public var switchMode: WorkspaceSwitchMode {
        get { hidePrevious ? .concentrate : (switchLayouts ? .arrange : .focus) }
        set {
            hidePrevious = newValue == .concentrate
            switchLayouts = newValue != .focus
        }
    }
    public var tabPosition = "top"
    public var tabStyle: String?
    public var tabAutoHide = false
    public var minimizeTabs = true
    public var gap = 8.0
    public var snapRatios = true
    public var shortcutKey: UInt32 = 49
    public var shortcutModifiers: UInt32 = 6144  // control + option
    public var shortcutsEnabled = true
    public var additionalShortcuts: [String: KeyChord]?
    public var excludedApps: Set<String> = []
    public var excludedWindows: Set<UUID> = []
    public var rules: [AssignmentRule] = []
    public init() {}
}

public struct FloatingFrame: Codable, Equatable, Sendable {
    public var display: String
    public var relative: CGRect
    public init(display: String, relative: CGRect) { self.display = display; self.relative = relative }
}

public struct WorkbenchState: Codable, Equatable, Sendable {
    public var version = 1
    public var workspaces: [Workspace] = []
    public var activeID: UUID?
    public var recent: [UUID] = []
    public var templates: [WindowGroup] = []
    public var prefs = Preferences()
    public var identities: [UUID: WindowIdentity] = [:]
    public var floatingFrames: [UUID: FloatingFrame]?
    public var groupAreas: [UUID: CGRect] = [:]
    public init() {}
}

public enum StorageError: Error { case unsupportedVersion, invalidConfiguration }

public enum LocalFile {
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1024 * 1024 else { throw StorageError.invalidConfiguration }
        return try JSONDecoder().decode(type, from: data)
    }
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }
}

public struct WindowLease: Codable, Equatable, Sendable {
    public var identity: WindowIdentity
    public var originalFrame: CGRect?
    public var expectedFrame: CGRect?
    public var minimizedByUs = false
    public init(identity: WindowIdentity) { self.identity = identity }
}

public struct RecoveryJournal: Codable, Equatable, Sendable {
    public var version = 1
    public var entries: [UUID: WindowLease] = [:]
    public init() {}
}

public extension CGRect {
    func roughlyEquals(_ other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
