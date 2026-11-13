import ApplicationServices
import Foundation

public enum WindowAccessError: Error, LocalizedError {
    case permission, unavailable, busy, unsupported, invalidFrame, verification, system(AXError)

    public var errorDescription: String? {
        switch self {
        case .permission: "需要辅助功能权限。"
        case .unavailable: "窗口或其所属应用已不可用。"
        case .busy: "应用暂时无响应，请稍后再试。"
        case .unsupported: "此窗口不支持该操作。"
        case .invalidFrame: "目标窗口的位置或尺寸无效。"
        case .verification: "应用未确认窗口已切换到请求的状态。"
        case .system(let error): "辅助功能返回错误（\(error.rawValue)）。"
        }
    }
}

// AX handles refer to an external object. Equality, including across separate AX calls,
// identifies that object while it lives. All remote access runs on its process queue.
struct Element: @unchecked Sendable, Hashable {
    let raw: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.raw, rhs.raw) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }

    func attribute(_ key: String) throws -> CFTypeRef? {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(raw, key as CFString, &result)
        if error == .noValue || error == .attributeUnsupported { return nil }
        try checkAX(error)
        return result
    }
    func child(_ key: String) throws -> Element? {
        guard let value = try attribute(key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return Element(raw: unsafeDowncast(value, to: AXUIElement.self))
    }
    func writable(_ key: String) throws -> Bool {
        var result = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(raw, key as CFString, &result)
        if error == .attributeUnsupported || error == .noValue { return false }
        try checkAX(error)
        return result.boolValue
    }
    func set(_ key: String, _ value: CFTypeRef) throws {
        try checkAX(AXUIElementSetAttributeValue(raw, key as CFString, value))
    }
    func frame() throws -> CGRect? {
        guard let p = try attribute(kAXPositionAttribute), let s = try attribute(kAXSizeAttribute) else { return nil }
        return Self.frame(position: p, size: s)
    }
    static func frame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
            CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
            AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}

func checkAX(_ error: AXError) throws {
    switch error {
    case .success: return
    case .apiDisabled: throw WindowAccessError.permission
    case .invalidUIElement, .invalidUIElementObserver: throw WindowAccessError.unavailable
    case .cannotComplete: throw WindowAccessError.busy
    case .attributeUnsupported, .actionUnsupported, .notImplemented: throw WindowAccessError.unsupported
    default: throw WindowAccessError.system(error)
    }
}
