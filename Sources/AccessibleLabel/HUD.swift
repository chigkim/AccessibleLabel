import AppKit
import Carbon.HIToolbox

/// Floating panel showing the result, plus an outline around the element.
/// Normally it sits next to the pointer and sizes itself to fit; once pinned (by the pin button,
/// by moving or resizing it, or in Settings) it always appears with the saved frame and scrolls.
final class HUDController {
    /// Called by the Copy button; returns whether there was anything to copy.
    var onCopy: (() -> Bool)?
    /// Called whenever the popup goes away (timer, Esc, click elsewhere, or `hide()`).
    var onHide: (() -> Void)?
    /// Called after the popup's Advanced checkbox changes `Preferences.advancedDisplay`.
    var onAdvancedChange: (() -> Void)?
    var isVisible: Bool { panel.isVisible }
    /// While following the pointer, lets the pointer look through the popup at whatever is underneath,
    /// like the outline window. A pinned popup stays clickable so it can still be moved, resized or unpinned.
    var clickThrough = false

    private let panel: NSPanel
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let copyButton = FirstMouseButton(title: "Copy", target: nil, action: nil)
    private let advancedCheck = FirstMouseButton(checkboxWithTitle: "Advanced", target: nil, action: nil)
    /// App name, Copy and Advanced.
    private let footerRow: NSStackView
    private var copiedReset: Timer?
    private lazy var copyWidthConstraint = copyButton.widthAnchor.constraint(equalToConstant: 60)
    /// The element being shown, so the Advanced checkbox can redraw it.
    private var info: ElementInfo?
    private var mouse = NSPoint.zero
    /// Attribute table for the advanced display; replaced on each layout.
    private var attributesGrid = NSGridView()
    private let stack: NSStackView
    private let background = DraggableEffectView()
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private let pinButton = FirstMouseButton()
    private let resizeGrip = ResizeGrip()
    /// Padding between the text and the popup's edges: leading, trailing, top, bottom.
    private var paddingConstraints: [NSLayoutConstraint] = []
    private let highlight = HighlightWindow()
    private var hideTimer: Timer?
    private var clickMonitor: Any?
    private lazy var escapeKey = HotKey { [weak self] in self?.hide() }
    private var attributes: [(label: String, value: String)] = []

    private static let maxTextWidth: CGFloat = 440
    private static let minimumPinnedSize = NSSize(width: 180, height: 80)

    private var prefs: Preferences { .shared }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        detailLabel.textColor = .secondaryLabelColor
        hintLabel.textColor = .secondaryLabelColor
        footerLabel.textColor = .tertiaryLabelColor
        for label in [titleLabel, detailLabel, hintLabel] {
            label.isSelectable = false
        }

        advancedCheck.controlSize = .small
        advancedCheck.toolTip = "Show every accessibility attribute: title, description, value, role, help, identifier, actions and more."
        copyButton.bezelStyle = .push
        copyButton.controlSize = .small
        footerRow = NSStackView(views: [footerLabel, copyButton, advancedCheck])
        footerRow.alignment = .centerY

        stack = NSStackView(views: [titleLabel, detailLabel, hintLabel, attributesGrid, footerRow])
        advancedCheck.target = self
        advancedCheck.action = #selector(toggleAdvanced)
        copyButton.target = self
        copyButton.action = #selector(copyResult)
        copyWidthConstraint.isActive = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        paddingConstraints = [
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            document.trailingAnchor.constraint(greaterThanOrEqualTo: stack.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            document.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
        ]
        NSLayoutConstraint.activate(paddingConstraints)

        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.autoresizingMask = [.width, .height]

        pinButton.isBordered = false
        pinButton.imagePosition = .imageOnly
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        pinButton.contentTintColor = .secondaryLabelColor
        pinButton.autoresizingMask = [.minXMargin, .minYMargin]
        resizeGrip.autoresizingMask = [.minXMargin, .maxYMargin]
        resizeGrip.toolTip = "Drag to resize (pins the popup)"

        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.masksToBounds = true
        background.addSubview(scrollView)
        background.addSubview(pinButton)
        background.addSubview(resizeGrip)
        background.onDragBegan = { [weak self] in self?.hideTimer?.invalidate() }
        background.onDragEnded = { [weak self] in self?.pinCurrentFrame() }
        resizeGrip.onResize = { [weak self] frame in self?.resizePanel(to: frame) }
        resizeGrip.onResizeBegan = { [weak self] in self?.hideTimer?.invalidate() }
        resizeGrip.onResizeEnded = { [weak self] in self?.pinCurrentFrame() }
        panel.contentView = background
    }

    func show(info: ElementInfo, at mouse: NSPoint) {
        self.info = info
        self.mouse = mouse
        let advanced = prefs.advancedDisplay && !info.attributes.isEmpty
        var details = info.details
        if info.name == nil { details.append("VoiceOver won't announce a label") }
        show(
            title: info.name ?? "(no label)",
            dimTitle: info.name == nil,
            // The table already lists the value, role and help.
            detail: advanced ? nil : details.joined(separator: ", "),
            hint: advanced ? nil : info.hint.map { "Hint: \($0)" },
            attributes: advanced ? info.attributes : [],
            footer: info.appName,
            showsControls: true,
            at: mouse
        )
        if prefs.showOutline, let frame = info.frame { highlight.show(axFrame: frame) }
    }

    func show(title: String, dimTitle: Bool = false, detail: String?, hint: String? = nil,
              attributes: [(label: String, value: String)] = [], footer: String? = nil,
              showsControls: Bool = false, at mouse: NSPoint) {
        if !showsControls { info = nil }
        copyButton.isHidden = !showsControls
        copyButton.isEnabled = info?.name != nil || prefs.advancedDisplay
        copyButton.toolTip = prefs.advancedDisplay ? "Copy all attributes" : "Copy the name"
        showCopied(false)
        advancedCheck.isHidden = !showsControls || info?.attributes.isEmpty != false
        advancedCheck.state = prefs.advancedDisplay ? .on : .off
        titleLabel.stringValue = title.truncated(300)
        titleLabel.textColor = dimTitle ? .secondaryLabelColor : .labelColor
        set(detailLabel, detail)
        set(hintLabel, hint)
        set(footerLabel, footer)
        footerRow.isHidden = footerLabel.isHidden && !showsControls
        self.attributes = attributes

        if let pinned = prefs.activePinnedFrame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(pinned) }) {
            panel.setFrame(pinned, display: false)
            layoutContent(width: pinned.width)
        } else {
            let size = layoutContent(width: nil)
            panel.setFrame(NSRect(origin: origin(for: size, near: mouse), size: size), display: false)
        }
        document.scroll(.zero)
        updatePinButton()
        panel.display()
        panel.ignoresMouseEvents = clickThrough && !prefs.isPinned
        panel.orderFrontRegardless()

        restartHideTimer()
        if prefs.dismissOnClickOrEscape { startDismissWatchers() }
    }

    /// Below-right of the pointer, flipping sides when it would go off screen.
    private func origin(for size: NSSize, near mouse: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: mouse.x + 18, y: mouse.y - 24 - size.height)
        if origin.x + size.width > visible.maxX { origin.x = mouse.x - 18 - size.width }
        if origin.y < visible.minY { origin.y = mouse.y + 24 }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return origin
    }

    private func restartHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
        if let delay = prefs.hideDelay {
            hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.hide()
            }
        }
    }

    /// Esc is taken over only while the panel is visible. Clicks elsewhere still
    /// reach the app underneath; we just observe them.
    private func startDismissWatchers() {
        escapeKey.register(keyCode: UInt32(kVK_Escape), carbonModifiers: 0)
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in self?.hide() }
        }
    }

    private func stopDismissWatchers() {
        escapeKey.unregister()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel.orderOut(nil)
        highlight.orderOut(nil)
        stopDismissWatchers()
        clickThrough = false
        onHide?()
    }

    @objc private func copyResult() {
        guard onCopy?() == true else { return }
        showCopied(true)
        copiedReset = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.showCopied(false) }
        restartHideTimer()
    }

    /// Briefly confirms the copy on the button itself, keeping its width so the row doesn't shift.
    private func showCopied(_ copied: Bool) {
        copiedReset?.invalidate()
        copiedReset = nil
        copyButton.title = copied ? "Copied" : "Copy"
    }

    @objc private func toggleAdvanced() {
        guard let info else { return }
        prefs.advancedDisplay = advancedCheck.state == .on
        onAdvancedChange?()
        // Redraw in place: an unpinned popup keeps its top-left corner rather than jumping back to the pointer.
        let top = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        show(info: info, at: mouse)
        if !prefs.isPinned, let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            let size = panel.frame.size
            let origin = NSPoint(x: min(max(top.x, visible.minX), visible.maxX - size.width),
                                 y: min(max(top.y - size.height, visible.minY), visible.maxY - size.height))
            panel.setFrameOrigin(origin)
        }
    }

    // MARK: Pinning

    @objc private func togglePin() {
        if prefs.isPinned {
            // Back to fitting the content, keeping the top-left corner where it is.
            // The pinned frame is kept, so pinning again puts the popup back there.
            prefs.isPinned = false
            let top = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            let size = layoutContent(width: nil)
            panel.setFrame(NSRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height), display: true)
        } else {
            prefs.pin(defaultFrame: panel.frame)
            if let frame = prefs.pinnedFrame, frame != panel.frame {
                panel.setFrame(frame, display: false)
                layoutContent(width: frame.width)
                panel.display()
            }
        }
        updatePinButton()
        restartHideTimer()
    }

    private func pinCurrentFrame() {
        prefs.pinnedFrame = panel.frame
        prefs.isPinned = true
        updatePinButton()
        restartHideTimer()
    }

    private func resizePanel(to frame: NSRect) {
        var frame = frame
        frame.size.width = max(frame.width, Self.minimumPinnedSize.width)
        let height = max(frame.height, Self.minimumPinnedSize.height)
        frame.origin.y += frame.height - height // keep the top edge fixed
        frame.size.height = height
        panel.setFrame(frame, display: false)
        layoutContent(width: frame.width)
        panel.display()
    }

    private func updatePinButton() {
        let pinned = prefs.isPinned
        let scale = prefs.textScale
        let config = NSImage.SymbolConfiguration(pointSize: 12 * scale, weight: .regular)
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: pinned ? "Unpin" : "Pin")?
            .withSymbolConfiguration(config)
        pinButton.toolTip = pinned
            ? "Pinned: the popup opens here at this size. Click to unpin."
            : "Pin the popup here so it always opens in this place at this size"
        pinButton.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
    }

    // MARK: Layout

    /// Lays out the text for a popup `width` wide (pinned), or at its natural width when `nil`.
    /// Returns the size the content needs.
    @discardableResult
    private func layoutContent(width: CGFloat?) -> NSSize {
        let scale = prefs.textScale
        let padding: [CGFloat] = [16, 16, 12, 10].map { $0 * scale }
        let textWidth = (width.map { $0 - padding[0] - padding[1] } ?? Self.maxTextWidth * scale)
        let buttonSize = 22 * scale

        titleLabel.font = .systemFont(ofSize: 22 * scale, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 15 * scale)
        hintLabel.font = .systemFont(ofSize: 13 * scale)
        footerLabel.font = .systemFont(ofSize: 11 * scale)
        advancedCheck.font = .systemFont(ofSize: 11 * scale)
        copyButton.font = .systemFont(ofSize: 11 * scale)
        footerRow.spacing = 10 * scale
        // Wide enough for "Copied" so the title change doesn't move the checkbox.
        let copyWidth = ("Copied" as NSString).size(withAttributes: [.font: copyButton.font!]).width + 20 * scale
        copyWidthConstraint.constant = copyWidth
        // Leave room for the pin button beside the title.
        titleLabel.preferredMaxLayoutWidth = max(textWidth - buttonSize, 40)
        detailLabel.preferredMaxLayoutWidth = textWidth
        hintLabel.preferredMaxLayoutWidth = textWidth
        stack.spacing = 4 * scale
        stack.setCustomSpacing(8 * scale, after: hintLabel)
        for (constraint, value) in zip(paddingConstraints, padding) {
            constraint.constant = value
        }
        paddingConstraints[1].constant = padding[1] + (width == nil ? buttonSize * 0.5 : 0)
        background.layer?.cornerRadius = 12 * scale
        setAttributes(attributes, scale: scale, textWidth: textWidth, natural: width == nil)

        document.layoutSubtreeIfNeeded()
        var content = document.fittingSize
        let visibleHeight = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let panelSize: NSSize
        if let width {
            panelSize = NSSize(width: width, height: panel.frame.height)
            content.width = width
        } else {
            // Unpinned popups fit their content, up to the screen height (then scroll).
            panelSize = NSSize(width: content.width, height: min(content.height, visibleHeight - 20))
        }
        let bounds = NSRect(origin: .zero, size: panelSize)
        background.frame = bounds
        scrollView.frame = bounds
        document.frame = NSRect(origin: .zero, size: NSSize(width: panelSize.width, height: content.height))
        pinButton.frame = NSRect(x: panelSize.width - buttonSize - 6 * scale, y: panelSize.height - buttonSize - 6 * scale,
                                 width: buttonSize, height: buttonSize)
        let grip = 14 * scale
        resizeGrip.frame = NSRect(x: panelSize.width - grip - 2, y: 2, width: grip, height: grip)
        return panelSize
    }

    private func setAttributes(_ attributes: [(label: String, value: String)], scale: CGFloat, textWidth: CGFloat, natural: Bool) {
        let font = NSFont.systemFont(ofSize: 13 * scale)
        let names = attributes.map { row -> NSTextField in
            let name = NSTextField(labelWithString: row.label)
            name.font = .systemFont(ofSize: 13 * scale, weight: .medium)
            name.textColor = .secondaryLabelColor
            return name
        }
        let columnSpacing = 10 * scale
        let nameWidth = names.map(\.fittingSize.width).max() ?? 0
        let maxWidth = natural ? Self.maxTextWidth * scale * 0.7 : max(textWidth - nameWidth - columnSpacing, 60)
        let grid = NSGridView(views: zip(names, attributes).map { name, row in
            // Wrapping labels can measure short text a point too narrow and clip its last
            // character, so only wrap values that don't fit on one line.
            var value = NSTextField(labelWithString: row.value)
            value.font = font
            if value.fittingSize.width > maxWidth {
                value = NSTextField(wrappingLabelWithString: row.value)
                value.font = font
                value.preferredMaxLayoutWidth = maxWidth
            }
            value.isSelectable = false
            return [name, value]
        })
        if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .trailing }
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 3 * scale
        grid.columnSpacing = columnSpacing
        grid.isHidden = attributes.isEmpty

        let index = stack.arrangedSubviews.firstIndex(of: attributesGrid) ?? 3
        stack.removeArrangedSubview(attributesGrid)
        attributesGrid.removeFromSuperview()
        stack.insertArrangedSubview(grid, at: index)
        stack.setCustomSpacing(8 * scale, after: titleLabel)
        stack.setCustomSpacing(8 * scale, after: grid)
        attributesGrid = grid
    }

    private func set(_ label: NSTextField, _ text: String?) {
        label.stringValue = text ?? ""
        label.isHidden = (text ?? "").isEmpty
    }
}

/// Background that moves the popup on drag.
private final class DraggableEffectView: NSVisualEffectView {
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var dragged = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame.origin)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - dragStart.mouse.x, dy = mouse.y - dragStart.mouse.y
        if !dragged, hypot(dx, dy) < 3 { return }
        if !dragged { onDragBegan?() }
        dragged = true
        window.setFrameOrigin(NSPoint(x: dragStart.origin.x + dx, y: dragStart.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onDragEnded?() }
        dragStart = nil
        dragged = false
    }
}

/// Resize handle in the bottom-right corner; the top-left corner stays put.
private final class ResizeGrip: NSView {
    var onResize: ((NSRect) -> Void)?
    var onResizeBegan: (() -> Void)?
    var onResizeEnded: (() -> Void)?
    private var start: (mouse: NSPoint, frame: NSRect)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setStroke()
        for inset in stride(from: CGFloat(3), to: bounds.width, by: 4) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: inset, y: 1))
            path.line(to: NSPoint(x: bounds.width - 1, y: bounds.height - inset))
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        start = (NSEvent.mouseLocation, window.frame)
        onResizeBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let mouse = NSEvent.mouseLocation
        let width = start.frame.width + mouse.x - start.mouse.x
        let height = start.frame.height - (mouse.y - start.mouse.y)
        onResize?(NSRect(x: start.frame.minX, y: start.frame.maxY - height, width: width, height: height))
    }

    override func mouseUp(with event: NSEvent) {
        if start != nil { onResizeEnded?() }
        start = nil
    }
}

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Transparent, click-through window that outlines the inspected element.
private final class HighlightWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contentView = HighlightView()
    }

    func show(axFrame: CGRect) {
        // AX uses a top-left origin relative to the primary screen; Cocoa uses bottom-left.
        guard let primary = NSScreen.screens.first, axFrame.width > 0, axFrame.height > 0 else { return }
        let rect = NSRect(
            x: axFrame.minX,
            y: primary.frame.maxY - axFrame.maxY,
            width: axFrame.width,
            height: axFrame.height
        ).insetBy(dx: -4, dy: -4)
        setFrame(rect, display: true)
        orderFrontRegardless()
    }
}

private final class HighlightView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 5, yRadius: 5)
        path.lineWidth = 3
        NSColor.systemOrange.setStroke()
        path.stroke()
    }
}
