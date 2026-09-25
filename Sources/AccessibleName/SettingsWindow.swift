import AppKit
import ServiceManagement

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Called when the user records a new shortcut (already saved to preferences).
    var onShortcutChange: (() -> Void)?
    /// Called with `true` when recording starts (so the live hotkey can be suspended) and `false` when it ends.
    var onRecordingChange: ((Bool) -> Void)?
    var onSpeakChange: (() -> Void)?
    /// Called after the text size changes, with a screen point where a preview popup can be shown.
    var onTextSizeChange: ((NSPoint) -> Void)?

    private let prefs = Preferences.shared
    private let shortcutField = ShortcutField(shortcut: Preferences.shared.shortcut)
    private lazy var speechPopup: NSPopUpButton = {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: Preferences.Speech.allCases.map(\.title))
        popup.target = self
        popup.action = #selector(speechChanged)
        return popup
    }()
    private lazy var hideSlider = NSSlider(
        value: Preferences.hideDelayRange.lowerBound,
        minValue: Preferences.hideDelayRange.lowerBound,
        // One step past the range means "Never".
        maxValue: Preferences.hideDelayRange.upperBound + 1,
        target: self,
        action: #selector(hideDelayChanged)
    )
    private let hideValueLabel = NSTextField(labelWithString: "")
    private lazy var textSizePopup: NSPopUpButton = {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: Preferences.textSizes.map(\.name))
        popup.target = self
        popup.action = #selector(textSizeChanged)
        return popup
    }()
    private lazy var pinCheck = NSButton(checkboxWithTitle: "Pin popup in place", target: self, action: #selector(pinChanged))
    private let pinnedFrameLabel = NSTextField(labelWithString: "")
    private lazy var dismissCheck = NSButton(checkboxWithTitle: "Dismiss with Esc or by clicking elsewhere", target: self, action: #selector(dismissChanged))
    private lazy var outlineCheck = NSButton(checkboxWithTitle: "Outline the element on screen", target: self, action: #selector(outlineChanged))
    private lazy var loginCheck = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(loginChanged))

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AccessibleName Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: Preferences.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        refresh()
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    @objc private func preferencesChanged() {
        updatePinControls()
    }

    private func updatePinControls() {
        pinCheck.state = prefs.isPinned ? .on : .off
        pinnedFrameLabel.stringValue = prefs.pinnedFrame.map { frame in
            // Report the position from the top-left of the screen, as people read it.
            let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
            let top = screen?.frame.maxY ?? frame.maxY
            let left = screen?.frame.minX ?? 0
            return "Saved: \(Int(frame.width)) × \(Int(frame.height)) at \(Int(frame.minX - left)), \(Int(top - frame.maxY))"
        } ?? "Drag the popup to move it, or its corner to resize it."
    }

    func windowWillClose(_ notification: Notification) {
        shortcutField.stopRecording()
    }

    // MARK: Layout

    private func buildContent() {
        shortcutField.onRecordingChange = { [weak self] in self?.onRecordingChange?($0) }
        shortcutField.onChange = { [weak self] shortcut in
            self?.prefs.shortcut = shortcut
            self?.onShortcutChange?()
        }

        let shortcutNote = NSTextField(labelWithString: "Click, then press a new combination using ⌃, ⌥ or ⌘.")
        shortcutNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shortcutNote.textColor = .secondaryLabelColor

        hideSlider.numberOfTickMarks = Int(Preferences.hideDelayRange.upperBound - Preferences.hideDelayRange.lowerBound) + 2
        hideSlider.allowsTickMarkValuesOnly = true
        hideSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        hideValueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        // Fixed width so the row doesn't shift between "1 second", "10 seconds" and "Never".
        hideValueLabel.stringValue = "10 seconds"
        hideValueLabel.widthAnchor.constraint(equalToConstant: hideValueLabel.fittingSize.width).isActive = true
        pinCheck.toolTip = "The popup always opens in the same place at the same size. Drag the popup to move it, or its corner to resize it."
        hideSlider.toolTip = "At Never, the popup stays open and follows the pointer. Press the shortcut again to close it."
        pinnedFrameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pinnedFrameLabel.textColor = .secondaryLabelColor
        let hideRow = NSStackView(views: [hideSlider, hideValueLabel])

        let grid = NSGridView(views: [
            [label("Shortcut:"), shortcutField],
            [NSGridCell.emptyContentView, shortcutNote],
            [label("Speak:"), speechPopup],
            [label("Text size:"), textSizePopup],
            [label("Hide after:"), hideRow],
            [label("Position:"), pinCheck],
            [NSGridCell.emptyContentView, pinnedFrameLabel],
            [label("Dismiss:"), dismissCheck],
            [label("Highlight:"), outlineCheck],
            [label("Startup:"), loginCheck],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.row(at: 1).topPadding = -6
        grid.cell(for: pinnedFrameLabel)?.row?.topPadding = -6

        let resetButton = NSButton(title: "Reset All Settings", target: self, action: #selector(resetAll))

        grid.translatesAutoresizingMaskIntoConstraints = false
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        content.addSubview(resetButton)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            resetButton.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            resetButton.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            resetButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window?.contentView = content
        refresh()
        window?.setContentSize(content.fittingSize)
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func refresh() {
        shortcutField.shortcut = prefs.shortcut
        speechPopup.selectItem(at: Preferences.Speech.allCases.firstIndex(of: prefs.speech) ?? 0)
        hideSlider.doubleValue = prefs.hideDelay ?? Preferences.hideDelayRange.upperBound + 1
        updateHideValueLabel()
        textSizePopup.selectItem(at: Preferences.textSizes.firstIndex { $0.scale == prefs.textScale } ?? 1)
        updatePinControls()
        dismissCheck.state = prefs.dismissOnClickOrEscape ? .on : .off
        outlineCheck.state = prefs.showOutline ? .on : .off
        loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: Actions

    @objc private func resetAll() {
        guard let window else { return }
        shortcutField.stopRecording()
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Shortcut, speech options, text size, advanced display (in the popup), hide after, pinned position and size, dismiss and highlight will return to their defaults."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.prefs.resetAll()
            self.refresh()
            self.onShortcutChange?()
            self.onSpeakChange?()
        }
    }

    @objc private func speechChanged() {
        prefs.speech = Preferences.Speech.allCases[max(speechPopup.indexOfSelectedItem, 0)]
        onSpeakChange?()
    }

    @objc private func hideDelayChanged() {
        let seconds = hideSlider.doubleValue.rounded()
        prefs.hideDelay = seconds > Preferences.hideDelayRange.upperBound ? nil : seconds
        updateHideValueLabel()
    }

    private func updateHideValueLabel() {
        guard let seconds = prefs.hideDelay.map(Int.init) else {
            hideValueLabel.stringValue = "Never"
            return
        }
        hideValueLabel.stringValue = seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    @objc private func textSizeChanged() {
        let index = textSizePopup.indexOfSelectedItem
        guard Preferences.textSizes.indices.contains(index), let window else { return }
        prefs.textScale = Preferences.textSizes[index].scale
        // Preview just outside the window's right edge, level with the popup button.
        let buttonFrame = window.convertToScreen(textSizePopup.convert(textSizePopup.bounds, to: nil))
        onTextSizeChange?(NSPoint(x: window.frame.maxX, y: buttonFrame.maxY + 24))
    }

    @objc private func pinChanged() {
        // The saved frame is kept either way, so pinning again restores it.
        if pinCheck.state == .on { prefs.pin() } else { prefs.isPinned = false }
    }

    @objc private func dismissChanged() {
        prefs.dismissOnClickOrEscape = dismissCheck.state == .on
    }

    @objc private func outlineChanged() {
        prefs.showOutline = outlineCheck.state == .on
    }

    @objc private func loginChanged() {
        do {
            if loginCheck.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
        loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

/// A button that records the next key combination when clicked.
final class ShortcutField: NSButton {
    var shortcut: Shortcut {
        didSet { if !isRecording { title = shortcut.displayString } }
    }
    var onChange: ((Shortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private var monitor: Any?
    private var isRecording: Bool { monitor != nil }

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        title = shortcut.displayString
        widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        onRecordingChange?(true)
        title = "Type shortcut…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window
        )
    }

    func stopRecording() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        title = shortcut.displayString
        onRecordingChange?(false)
    }

    @objc private func windowResignedKey() { stopRecording() }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        if event.keyCode == UInt16(53), flags.isEmpty { // Escape cancels
            stopRecording()
            return
        }
        if flags.intersection([.command, .option, .control]).isEmpty, !Shortcut.isFunctionKey(event.keyCode) {
            title = "Add ⌃, ⌥ or ⌘"
            NSSound.beep()
            return
        }
        let newShortcut = Shortcut(event: event)
        if newShortcut.conflictsWithVoiceOver {
            title = "⌃⌥ is used by VoiceOver"
            NSSound.beep()
            return
        }
        shortcut = newShortcut
        onChange?(newShortcut)
        stopRecording()
    }
}
