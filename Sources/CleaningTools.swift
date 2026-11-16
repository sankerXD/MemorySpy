import AppKit
import ApplicationServices

private final class KeySwallowingWindow: NSWindow {
    var onEscapePressed: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onEscapePressed?()
        }
        // Swallow all key events silently without triggering system beep
    }

    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            onEscapePressed?()
        }
        return true
    }
}

private final class HoverPillView: NSVisualEffectView {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        animator().alphaValue = 0.96
    }

    override func mouseExited(with event: NSEvent) {
        animator().alphaValue = 0.50
    }
}

final class CleaningManager {
    private(set) var isKeyboardCleaning = false
    private(set) var isScreenCleaning = false

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var allowEscapeInTap = false

    private var keyboardWindow: KeySwallowingWindow?
    private var keyboardTitleLabel: NSTextField?
    private var keyboardSubtitleLabel: NSTextField?
    private var grantAccessButton: NSButton?
    private var permissionPollTimer: Timer?

    private var screenWindows: [KeySwallowingWindow] = []

    func toggleKeyboardCleaning() {
        if isKeyboardCleaning {
            stopAll()
        } else {
            startKeyboardCleaning()
        }
    }

    func toggleScreenCleaning() {
        if isScreenCleaning {
            stopAll()
        } else {
            startScreenCleaning()
        }
    }

    func stopAll() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil

        teardownEventTap()

        keyboardWindow?.orderOut(nil)
        keyboardWindow = nil
        keyboardTitleLabel = nil
        keyboardSubtitleLabel = nil
        grantAccessButton = nil

        for win in screenWindows {
            win.orderOut(nil)
        }
        screenWindows.removeAll()

        isKeyboardCleaning = false
        isScreenCleaning = false
    }

    // MARK: - Keyboard Cleaning

    private func startKeyboardCleaning() {
        stopAll()
        isKeyboardCleaning = true
        allowEscapeInTap = false

        let tapStarted = installEventTap(allowEscape: false)
        showKeyboardHUD(globalTapActive: tapStarted)

        if !tapStarted {
            startPermissionPolling()
        }
    }

    private func showKeyboardHUD(globalTapActive: Bool) {
        let width: CGFloat = 340
        let height: CGFloat = globalTapActive ? 148 : 182
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = NSPoint(
            x: screenFrame.midX - width / 2.0,
            y: screenFrame.midY - height / 2.0 + 40
        )

        let window = KeySwallowingWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true

        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        iconView.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        iconView.contentTintColor = .labelColor

        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 14.5, weight: .semibold)
        titleLabel.alignment = .center

        let subtitleLabel = NSTextField(wrappingLabelWithString: "")
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        let grantButton = NSButton(title: "Grant Accessibility Access", target: self, action: #selector(requestAccessibilityAccess))
        grantButton.translatesAutoresizingMaskIntoConstraints = false
        grantButton.bezelStyle = .rounded
        grantButton.controlSize = .small

        let unlockButton = NSButton(title: "Unlock & Exit", target: self, action: #selector(exitCleaningClicked))
        unlockButton.translatesAutoresizingMaskIntoConstraints = false
        unlockButton.bezelStyle = .rounded
        unlockButton.controlSize = .regular
        unlockButton.keyEquivalent = "" // Never trigger by pressing Return/Esc

        container.addSubview(iconView)
        container.addSubview(titleLabel)
        container.addSubview(subtitleLabel)
        container.addSubview(grantButton)
        container.addSubview(unlockButton)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            subtitleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            grantButton.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
            grantButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            unlockButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            unlockButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            unlockButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        window.contentView = container
        keyboardWindow = window
        keyboardTitleLabel = titleLabel
        keyboardSubtitleLabel = subtitleLabel
        grantAccessButton = grantButton

        updateKeyboardHUDState(globalTapActive: globalTapActive)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func updateKeyboardHUDState(globalTapActive: Bool) {
        guard let window = keyboardWindow else { return }
        if globalTapActive {
            keyboardTitleLabel?.stringValue = "Keyboard Locked for Cleaning"
            keyboardSubtitleLabel?.stringValue = "All keys & shortcuts are blocked. Click below when done."
            grantAccessButton?.isHidden = true
            var frame = window.frame
            if abs(frame.height - 148) > 1 {
                frame.origin.y += (frame.height - 148) / 2.0
                frame.size.height = 148
                window.setFrame(frame, display: true, animate: true)
            }
        } else {
            keyboardTitleLabel?.stringValue = "Keyboard Cleaning Mode"
            keyboardSubtitleLabel?.stringValue = "Grant Accessibility access to block system & media keys globally."
            grantAccessButton?.isHidden = false
        }
    }

    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.isKeyboardCleaning else { return }
            if AXIsProcessTrusted(), self.installEventTap(allowEscape: false) {
                self.permissionPollTimer?.invalidate()
                self.permissionPollTimer = nil
                self.updateKeyboardHUDState(globalTapActive: true)
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    @objc private func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Screen Cleaning

    private func startScreenCleaning() {
        stopAll()
        isScreenCleaning = true
        allowEscapeInTap = true

        _ = installEventTap(allowEscape: true)

        let screens = NSScreen.screens
        let primaryScreen = NSScreen.main ?? screens.first
        var primaryWindow: KeySwallowingWindow?

        for screen in screens {
            let window = KeySwallowingWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = true
            window.backgroundColor = .black
            window.level = .screenSaver
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.onEscapePressed = { [weak self] in
                self?.stopAll()
            }

            let rootView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            rootView.wantsLayer = true
            rootView.layer?.backgroundColor = NSColor.black.cgColor
            window.contentView = rootView

            if screen == primaryScreen {
                addScreenExitPill(to: rootView)
                primaryWindow = window
            }

            screenWindows.append(window)
            window.orderFrontRegardless()
        }

        NSApp.activate(ignoringOtherApps: true)
        (primaryWindow ?? screenWindows.first)?.makeKeyAndOrderFront(nil)
    }

    private func addScreenExitPill(to rootView: NSView) {
        let pill = HoverPillView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.alphaValue = 0.50
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 16
        pill.layer?.masksToBounds = true
        pill.layer?.borderWidth = 0.5
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let hintLabel = NSTextField(labelWithString: "Screen Cleaning · Press Esc or click Exit")
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        hintLabel.textColor = .white.withAlphaComponent(0.9)

        let exitButton = NSButton(title: "Exit", target: self, action: #selector(exitCleaningClicked))
        exitButton.translatesAutoresizingMaskIntoConstraints = false
        exitButton.bezelStyle = .rounded
        exitButton.controlSize = .small

        pill.addSubview(hintLabel)
        pill.addSubview(exitButton)
        rootView.addSubview(pill)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -42),
            pill.heightAnchor.constraint(equalToConstant: 34),

            hintLabel.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            hintLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            exitButton.leadingAnchor.constraint(equalTo: hintLabel.trailingAnchor, constant: 10),
            exitButton.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            exitButton.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
    }

    @objc private func exitCleaningClicked() {
        stopAll()
    }

    // MARK: - Global CGEventTap

    private func installEventTap(allowEscape: Bool) -> Bool {
        teardownEventTap()
        guard AXIsProcessTrusted() else { return false }

        self.allowEscapeInTap = allowEscape

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << 14) // NX_SYSDEFINED (media / brightness / volume keys)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<CleaningManager>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            if manager.allowEscapeInTap,
               type == .keyDown,
               event.getIntegerValueField(.keyboardEventKeycode) == 53
            {
                DispatchQueue.main.async {
                    manager.stopAll()
                }
                return nil
            }

            return nil
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.eventTapSource = source
        return true
    }

    private func teardownEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil
    }
}
