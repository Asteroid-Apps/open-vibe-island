import AppKit
import ApplicationServices

/// The focused window's web area identifies the actual visible chat, including
/// its environment. Window titles alone are ambiguous across projects/windows.
struct T3ForegroundThread: Equatable {
    let environmentID: String
    let threadID: String

    static var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    init?(url: URL) {
        guard url.scheme == "t3code", url.host == "app",
              let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else { return nil }
        let parts = fragment.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        environmentID = parts[0]
        threadID = parts[1]
    }

    @MainActor static func current() -> Self? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.t3tools.t3code", !app.isHidden, AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           minimized as? Bool == true { return nil }
        var budget = 32
        return findThread(in: window, depth: 0, budget: &budget)
    }

    private static func findThread(in element: AXUIElement, depth: Int, budget: inout Int) -> Self? {
        guard budget > 0 else { return nil }
        budget -= 1
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
           let url = value as? URL, let thread = Self(url: url) { return thread }
        // The web area is near the window root. Never walk the conversation or
        // sidebar, which can contain thousands of accessibility elements.
        guard depth < 4 else { return nil }
        value = nil
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
           value as? String == "AXWebArea" { return nil }
        value = nil
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children.prefix(12) {
            if let thread = findThread(in: child, depth: depth + 1, budget: &budget) { return thread }
        }
        return nil
    }
}
