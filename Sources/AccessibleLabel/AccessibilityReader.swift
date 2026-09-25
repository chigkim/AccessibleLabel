import AppKit
import ApplicationServices

/// What VoiceOver would announce for an element, split into displayable parts.
struct ElementInfo {
    /// The accessible name (label). `nil` when the element is unlabeled.
    var name: String?
    /// Value, role description and state, in roughly VoiceOver's reading order.
    var details: [String]
    /// The help text VoiceOver reads as a hint after a pause.
    var hint: String?
    var appName: String?
    /// Element frame in Accessibility coordinates (top-left origin of the primary screen).
    var frame: CGRect?
    /// Raw accessibility attributes for the advanced display, in display order. Empty ones are omitted.
    var attributes: [(label: String, value: String)] = []

    /// All attributes as "Label: value" lines, for copying.
    var attributesText: String {
        attributes.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }
}

enum AccessibilityReader {
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        // Don't hang for long on unresponsive apps.
        AXUIElementSetMessagingTimeout(element, 1.0)
        return element
    }()

    /// Roles a user would actually click or interact with. When the pointer hits a
    /// piece of text or an image inside one of these, VoiceOver announces the control.
    private static let interactiveRoles: Set<String> = [
        kAXButtonRole, "AXLink", kAXMenuItemRole, kAXMenuBarItemRole, kAXCheckBoxRole,
        kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXDisclosureTriangleRole,
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXSliderRole, kAXIncrementorRole,
        kAXColorWellRole, "AXDockItem",
    ]

    /// Containers we never climb past when looking for the interactive ancestor.
    private static let boundaryRoles: Set<String> = [
        kAXApplicationRole, kAXWindowRole, kAXSheetRole, "AXWebArea", kAXScrollAreaRole, kAXMenuRole,
    ]

    /// Point is in global top-left-origin coordinates (as returned by `CGEvent.location`).
    static func inspect(at point: CGPoint) -> ElementInfo? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit, hit.pid != getpid()
        else { return nil }

        let target = interactiveAncestor(of: hit) ?? hit
        let role = target.role ?? ""

        var details = valueDescription(of: target, role: role)
        if role != kAXStaticTextRole, let roleDescription = target.string(kAXRoleDescriptionAttribute) {
            details.append(roleDescription)
        }
        if let enabled = target.value(kAXEnabledAttribute) as? Bool, !enabled {
            details.append("dimmed")
        }

        let name = directName(of: target) ?? descendantText(of: target)
        // Help is usually on the control, but some apps only set it on the child that was hit.
        let helps: [String] = [target, hit].compactMap { $0.string(kAXHelpAttribute) }
        let hint = helps.first { $0 != name }

        return ElementInfo(
            name: name,
            details: details,
            hint: hint,
            appName: NSRunningApplication(processIdentifier: target.pid)?.localizedName,
            frame: target.frame,
            attributes: attributes(of: target, hit: hit, name: name)
        )
    }

    /// The attributes a developer would check when debugging what VoiceOver says.
    private static func attributes(of el: AXUIElement, hit: AXUIElement, name: String?) -> [(label: String, value: String)] {
        var rows: [(String, String?)] = [
            ("Name", name.map { "“\($0)”" } ?? "none (VoiceOver won't announce a label)"),
            ("Title", el.string(kAXTitleAttribute)),
            ("Title element", el.element(kAXTitleUIElementAttribute).flatMap { $0.string(kAXValueAttribute) ?? $0.string(kAXTitleAttribute) }),
            ("Description", el.string(kAXDescriptionAttribute)),
            ("Value", el.value(kAXValueAttribute).flatMap(describe)),
            ("Value description", el.string(kAXValueDescriptionAttribute)),
            ("Placeholder", el.string(kAXPlaceholderValueAttribute)),
            ("Help", el.string(kAXHelpAttribute) ?? (CFEqual(el, hit) ? nil : hit.string(kAXHelpAttribute))),
            ("Role", el.role),
            ("Subrole", el.string(kAXSubroleAttribute)),
            ("Role description", el.string(kAXRoleDescriptionAttribute)),
            ("Identifier", el.string(kAXIdentifierAttribute)),
            ("Enabled", el.value(kAXEnabledAttribute).flatMap(describe)),
            ("Focused", el.value(kAXFocusedAttribute).flatMap(describe)),
            ("Selected", el.value(kAXSelectedAttribute).flatMap(describe)),
            ("Actions", el.actionNames.isEmpty ? nil : el.actionNames.joined(separator: ", ")),
            ("Frame", el.frame.map { "x \(Int($0.minX)), y \(Int($0.minY)), \(Int($0.width)) × \(Int($0.height))" }),
        ]
        if !CFEqual(el, hit) {
            // Make it clear the details above belong to the control, not the exact element under the pointer.
            rows.append(("Under pointer", [hit.role, directName(of: hit).map { "“\($0)”" }].compactMap { $0 }.joined(separator: " ")))
        }
        return rows.compactMap { label, value in value.map { (label, $0) } }
    }

    /// Readable form of an attribute value of any type.
    private static func describe(_ value: CFTypeRef) -> String? {
        let type = CFGetTypeID(value)
        if type == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) ? "true" : "false" }
        if let s = value as? String { return s.cleanedForDisplay.map { "“\($0.truncated(200))”" } ?? "“”" }
        if let n = value as? NSNumber { return n.stringValue }
        if type == AXUIElementGetTypeID() { return (value as! AXUIElement).role ?? "element" }
        if type == AXValueGetTypeID() {
            let axValue = value as! AXValue
            var range = CFRange()
            if AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) {
                return "location \(range.location), length \(range.length)"
            }
        }
        if let array = value as? [Any] { return array.count == 1 ? "1 item" : "\(array.count) items" }
        return String(describing: value).cleanedForDisplay?.truncated(200)
    }

    private static func interactiveAncestor(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let el = current, let role = el.role, !boundaryRoles.contains(role) else { return nil }
            if interactiveRoles.contains(role) { return el }
            current = el.element(kAXParentAttribute)
        }
        return nil
    }

    /// Approximates VoiceOver's label computation for a single element.
    private static func directName(of el: AXUIElement) -> String? {
        let role = el.role
        if role == kAXStaticTextRole {
            return el.string(kAXValueAttribute) ?? el.string(kAXDescriptionAttribute) ?? el.string(kAXTitleAttribute)
        }
        if let title = el.string(kAXTitleAttribute) { return title }
        if let label = el.element(kAXTitleUIElementAttribute),
           let text = label.string(kAXValueAttribute) ?? label.string(kAXTitleAttribute) {
            return text
        }
        if let description = el.string(kAXDescriptionAttribute) { return description }
        if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole {
            return el.string(kAXPlaceholderValueAttribute)
        }
        return nil
    }

    /// For containers without their own label (web buttons, links, table rows),
    /// VoiceOver reads the text of their contents.
    private static func descendantText(of el: AXUIElement) -> String? {
        var parts: [String] = []
        var queue = el.children
        var visited = 0
        while !queue.isEmpty, visited < 60, parts.count < 6 {
            let child = queue.removeFirst()
            visited += 1
            let role = child.role
            let text: String?
            if role == kAXImageRole {
                text = child.string(kAXDescriptionAttribute) ?? child.string(kAXTitleAttribute)
            } else {
                text = directName(of: child)
            }
            if let text {
                if parts.last != text { parts.append(text) }
            } else {
                queue.append(contentsOf: child.children)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func valueDescription(of el: AXUIElement, role: String) -> [String] {
        let raw = el.value(kAXValueAttribute)
        switch role {
        case kAXCheckBoxRole:
            guard let n = raw as? NSNumber else { return [] }
            if el.string(kAXSubroleAttribute) == kAXSwitchSubrole {
                return [n.intValue == 1 ? "on" : "off"]
            }
            return [["unchecked", "checked", "mixed"][min(max(n.intValue, 0), 2)]]
        case kAXRadioButtonRole:
            return (raw as? NSNumber)?.intValue == 1 ? ["selected"] : []
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXPopUpButtonRole:
            guard let s = el.string(kAXValueAttribute) else { return [] }
            return ["“\(s.truncated(80))”"]
        case kAXSliderRole, kAXIncrementorRole, kAXProgressIndicatorRole, kAXValueIndicatorRole, "AXLevelIndicator":
            if let s = el.string(kAXValueDescriptionAttribute) { return [s] }
            if let n = raw as? NSNumber { return [n.stringValue] }
            return []
        default:
            return []
        }
    }
}

// MARK: - AXUIElement helpers

extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// A display-ready string attribute; `nil` when missing or blank.
    func string(_ attribute: String) -> String? {
        guard let s = value(attribute) as? String else { return nil }
        return String(s.prefix(1000)).cleanedForDisplay
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let v = value(attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    var role: String? { value(kAXRoleAttribute) as? String }

    var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(self, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    var children: [AXUIElement] { (value(kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(self, &pid)
        return pid
    }

    var frame: CGRect? {
        guard let p = value(kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}

extension String {
    /// Collapses whitespace/newlines and strips object-replacement characters common in web content.
    var cleanedForDisplay: String? {
        let s = replacingOccurrences(of: "\u{FFFC}", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return s.isEmpty ? nil : s
    }

    func truncated(_ length: Int) -> String {
        count > length ? prefix(length - 1) + "…" : self
    }
}
