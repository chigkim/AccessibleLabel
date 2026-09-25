import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private lazy var hotKey = HotKey { [weak self] in self?.inspectUnderPointer() }
    private let hud = HUDController()
    private let prefs = Preferences.shared
    private lazy var settings = makeSettingsWindow()
    /// What clicking the popup copies: the name, or every attribute in the advanced display.
    private var lastCopyText: String?
    private var lastInfo: ElementInfo?
    private let synthesizer = AVSpeechSynthesizer()

    /// Polls the pointer while the popup stays open ("Hide after: Never").
    private var followTimer: Timer?
    private var lastFollowPoint: CGPoint?
    private var lastShownKey: String?
    private var lookupInFlight = false

    private let shortcutItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let grantItem = NSMenuItem(title: "Grant Accessibility Permission…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let grantSeparator = NSMenuItem.separator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        registerHotKey()

        hud.onHide = { [weak self] in self?.stopFollowingPointer() }
        hud.onAdvancedChange = { [weak self] in self?.updateCopyText() }
        hud.onCopy = { [weak self] in self?.copyLastResult() ?? false }

        // Shows the system prompt the first time if permission hasn't been granted.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Inspecting

    private func inspectUnderPointer() {
        // While the popup is following the pointer, the shortcut closes it.
        if followTimer != nil {
            hud.hide()
            return
        }
        let mouse = NSEvent.mouseLocation
        guard AXIsProcessTrusted() else {
            hud.show(
                title: "Accessibility access needed",
                detail: "Turn on AccessibleLabel in System Settings → Privacy & Security → Accessibility, then press the shortcut again.",
                at: mouse
            )
            speak("Accessibility access needed")
            openAccessibilitySettings()
            return
        }

        // Hide our own windows so they can't be hit, then query off the main thread
        // so a slow or hung app can't freeze the HUD.
        hud.hide()
        let point = CGEvent(source: nil)?.location ?? .zero
        lookUp(at: point, mouse: mouse, following: false)
        if prefs.hideDelay == nil { startFollowingPointer(from: point) }
    }

    private func lookUp(at point: CGPoint, mouse: NSPoint, following: Bool) {
        lookupInFlight = true
        DispatchQueue.global(qos: .userInitiated).async {
            let info = AccessibilityReader.inspect(at: point)
            DispatchQueue.main.async {
                self.lookupInFlight = false
                let key = info.map { [$0.name, $0.details.joined(), $0.hint, $0.frame.map { "\($0)" }].map { $0 ?? "" }.joined(separator: "|") }
                if following {
                    // Keep showing the last element when nothing (or our own popup) is under the pointer,
                    // and don't redraw or re-speak while the pointer stays on the same element.
                    guard self.followTimer != nil, let info, key != self.lastShownKey else { return }
                    self.show(info, at: NSEvent.mouseLocation, key: key)
                    return
                }
                if let info {
                    self.show(info, at: mouse, key: key)
                } else {
                    self.lastShownKey = nil
                    self.lastInfo = nil
                    self.lastCopyText = nil
                    self.hud.show(title: "Nothing found", dimTitle: true, detail: "No accessible element under the pointer.", at: mouse)
                    self.speak("Nothing found")
                }
            }
        }
    }

    private func show(_ info: ElementInfo, at mouse: NSPoint, key: String?) {
        lastShownKey = key
        lastInfo = info
        updateCopyText()
        hud.clickThrough = followTimer != nil
        hud.show(info: info, at: mouse)
        // Like VoiceOver: name, value and role, then the hint after a pause.
        let speech = prefs.speech
        let summary = ([info.name ?? "No label"] + (speech == .everything ? info.details : [])).joined(separator: ", ")
        let hint = speech == .nameAndHint || speech == .everything ? info.hint : nil
        speak(hint.map { "\(summary). \($0)" } ?? summary)
    }

    private func updateCopyText() {
        lastCopyText = lastInfo.map { prefs.advancedDisplay ? $0.attributesText : $0.name } ?? nil
    }

    private func startFollowingPointer(from point: CGPoint) {
        lastFollowPoint = point
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, !self.lookupInFlight, let point = CGEvent(source: nil)?.location,
                  point != self.lastFollowPoint
            else { return }
            self.lastFollowPoint = point
            self.lookUp(at: point, mouse: NSEvent.mouseLocation, following: true)
        }
    }

    private func stopFollowingPointer() {
        followTimer?.invalidate()
        followTimer = nil
    }

    // MARK: Menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "AccessibleLabel")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        grantItem.target = self
        grantItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        menu.addItem(grantItem)
        menu.addItem(grantSeparator)

        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AccessibleLabel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        updateShortcutItem()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Checked each time so the item disappears as soon as permission is granted.
        let trusted = AXIsProcessTrusted()
        grantItem.isHidden = trusted
        grantSeparator.isHidden = trusted
    }

    private func updateShortcutItem() {
        shortcutItem.title = "Shortcut: \(prefs.shortcut.displayString)"
    }

    private func registerHotKey() {
        updateShortcutItem()
        let shortcut = prefs.shortcut
        guard hotKey.register(shortcut) else {
            showAlert(
                "Couldn't register \(shortcut.displayString)",
                "Another app may already be using this shortcut. Choose a different one in Settings."
            )
            return
        }
    }

    private func makeSettingsWindow() -> SettingsWindowController {
        let controller = SettingsWindowController()
        controller.onShortcutChange = { [weak self] in self?.registerHotKey() }
        controller.onRecordingChange = { [weak self] recording in
            // Suspend the live hotkey so the current shortcut can be typed into the recorder.
            if recording { self?.hotKey.unregister() } else { self?.registerHotKey() }
        }
        controller.onTextSizeChange = { [weak self] point in
            self?.hud.show(title: "Sample Button", detail: "button", hint: "Hint: Help text the app provides, read by VoiceOver after a pause.", footer: "Text size preview", at: point)
        }
        controller.onSpeakChange = { [weak self] in
            if self?.prefs.speech == Preferences.Speech.none { self?.synthesizer.stopSpeaking(at: .immediate) }
        }
        return controller
    }

    @objc private func openSettings() {
        settings.show()
    }

    private func speak(_ text: String) {
        guard prefs.speech != .none else { return }
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    @discardableResult
    private func copyLastResult() -> Bool {
        guard let lastCopyText else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastCopyText, forType: .string)
        return true
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAlert(_ message: String, _ info: String) {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
}
