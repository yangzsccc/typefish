import AppKit
import ApplicationServices

enum NativePasteCommandResult {
    case unavailable, dispatched, uncertain, targetChanged
}

/// The standard Command-V menu item in the recording target. Resolve it while recording.
struct NativePasteCommand {
    let pid: pid_t
    private let item: AXUIElement

    static func usesPasteShortcut(character: String?, modifiers: NSNumber?) -> Bool {
        guard let character, let modifiers else { return false }
        // In the AX menu modifier mask, zero denotes Command alone.
        return character.uppercased() == "V" && modifiers.intValue == 0
    }

    static func find(in app: NSRunningApplication) -> Self? {
        guard !Thread.isMainThread else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let rawBar = attribute(kAXMenuBarAttribute, of: root),
              CFGetTypeID(rawBar) == AXUIElementGetTypeID() else { return nil }
        let bar = unsafeBitCast(rawBar, to: AXUIElement.self)
        var match: AXUIElement?
        for header in children(of: bar) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            for menu in children(of: header) {
                for item in children(of: menu) {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                    guard let character = attribute(kAXMenuItemCmdCharAttribute, of: item) as? String,
                          character.uppercased() == "V",
                          usesPasteShortcut(character: character, modifiers: attribute(kAXMenuItemCmdModifiersAttribute, of: item) as? NSNumber)
                    else { continue }
                    guard match == nil else { return nil }
                    match = item
                }
            }
        }
        return match.map { Self(pid: app.processIdentifier, item: $0) }
    }

    fileprivate static func attribute(_ key: String, of element: AXUIElement) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.02)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
    }

    func perform() -> NativePasteCommandResult {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return .targetChanged }
        guard Self.attribute(kAXEnabledAttribute, of: item) as? Bool == true else { return .unavailable }
        switch AXUIElementPerformAction(item, kAXPressAction as CFString) {
        case .success: return .dispatched
        case .actionUnsupported, .invalidUIElement, .notImplemented: return .unavailable
        default: return .uncertain  // A timeout can arrive after the app accepted the command.
        }
    }
}
