import AppKit

/// User settings, stored in UserDefaults.
final class Preferences {
    static let shared = Preferences()

    /// Range offered for `hideDelay`, in whole seconds.
    static let hideDelayRange: ClosedRange<TimeInterval> = 1...10

    /// Popup text sizes offered in Settings, as multipliers of the base font sizes.
    static let textSizes: [(name: String, scale: Double)] = [
        ("Small", 0.8), ("Medium", 1.0), ("Large", 1.3), ("Extra Large", 1.6), ("Huge", 2.0),
    ]

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "hideDelay": 6.0,
            "dismissOnClickOrEscape": true,
            "showOutline": true,
            "textScale": 1.0,
            "advancedDisplay": false,
        ])
    }

    /// Restores every setting stored here to its default. (Launch at login is a system setting and isn't affected.)
    func resetAll() {
        for key in ["shortcut", "speak", "speech", "hideDelay", "dismissOnClickOrEscape", "showOutline", "textScale", "advancedDisplay", "pinned", "pinnedFrame"] {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Posted when a setting changes outside the Settings window (e.g. pinning from the popup).
    static let didChange = Notification.Name("PreferencesDidChange")

    /// Whether the popup always opens at `pinnedFrame` instead of next to the pointer.
    var isPinned: Bool {
        get { defaults.bool(forKey: "pinned") }
        set {
            defaults.set(newValue, forKey: "pinned")
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// The frame to open the popup with while pinned, if pinned.
    var activePinnedFrame: NSRect? { isPinned ? pinnedFrame : nil }

    /// The last pinned position and size, in screen coordinates. Kept after unpinning so pinning again restores it.
    var pinnedFrame: NSRect? {
        get { defaults.string(forKey: "pinnedFrame").map(NSRectFromString).flatMap { $0.width > 0 ? $0 : nil } }
        set {
            if let newValue { defaults.set(NSStringFromRect(newValue), forKey: "pinnedFrame") }
            else { defaults.removeObject(forKey: "pinnedFrame") }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// Pins the popup, at the saved frame if there is one, else at `frame`, else near the top right of the screen.
    func pin(defaultFrame frame: NSRect? = nil) {
        if pinnedFrame == nil {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            pinnedFrame = frame ?? NSRect(x: visible.maxX - 460, y: visible.maxY - 340, width: 440, height: 320)
        }
        isPinned = true
    }

    var shortcut: Shortcut {
        get { Shortcut.load() }
        set { newValue.save() }
    }

    enum Speech: String, CaseIterable {
        case none, name, nameAndHint, everything

        var title: String {
            switch self {
            case .none: "None"
            case .name: "Name only"
            case .nameAndHint: "Name and hint"
            case .everything: "Name, value, role and hint"
            }
        }
    }

    /// What is read aloud when the popup appears.
    var speech: Speech {
        get {
            if let raw = defaults.string(forKey: "speech"), let speech = Speech(rawValue: raw) { return speech }
            // Before this setting, speech was on/off and read everything.
            return defaults.bool(forKey: "speak") ? .everything : .none
        }
        set {
            defaults.set(newValue.rawValue, forKey: "speech")
            defaults.removeObject(forKey: "speak")
        }
    }

    /// Seconds before the popup hides, or `nil` for never (the popup then follows the pointer). Stored as 0 for never.
    var hideDelay: TimeInterval? {
        get {
            let seconds = defaults.double(forKey: "hideDelay")
            return seconds == 0 ? nil : min(max(seconds, Self.hideDelayRange.lowerBound), Self.hideDelayRange.upperBound)
        }
        set { defaults.set(newValue ?? 0, forKey: "hideDelay") }
    }

    var dismissOnClickOrEscape: Bool {
        get { defaults.bool(forKey: "dismissOnClickOrEscape") }
        set { defaults.set(newValue, forKey: "dismissOnClickOrEscape") }
    }

    var showOutline: Bool {
        get { defaults.bool(forKey: "showOutline") }
        set { defaults.set(newValue, forKey: "showOutline") }
    }

    /// Show every accessibility attribute instead of just what VoiceOver says.
    var advancedDisplay: Bool {
        get { defaults.bool(forKey: "advancedDisplay") }
        set { defaults.set(newValue, forKey: "advancedDisplay") }
    }

    var textScale: Double {
        get { Self.textSizes.map(\.scale).contains(defaults.double(forKey: "textScale")) ? defaults.double(forKey: "textScale") : 1.0 }
        set { defaults.set(newValue, forKey: "textScale") }
    }
}
