import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, PopoverViewControllerDelegate {
    private enum PrefKey {
        static let showPercentage = "showPercentage"
        static let monochromeOnly = "monochromeOnly"
        static let groupedProcesses = "groupedProcesses"
    }

    private let monitor = MemoryMonitor()
    private lazy var cleaningManager = CleaningManager()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var popoverVC: PopoverViewController?

    private var idleTimer: Timer?
    private var popoverTimer: Timer?
    private var globalClickMonitor: Any?

    private var lastSnapshot: SystemMemorySnapshot?
    private var lastRenderedPercent: Int = -1
    private var lastRenderedPressure: MemoryPressureLevel = .unknown
    private var lastRenderedMonochrome: Bool = false

    private var showPercentage: Bool {
        get { UserDefaults.standard.bool(forKey: PrefKey.showPercentage) }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.showPercentage) }
    }

    private var monochromeOnly: Bool {
        get { UserDefaults.standard.bool(forKey: PrefKey.monochromeOnly) }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.monochromeOnly) }
    }

    private var groupedProcesses: Bool {
        get { UserDefaults.standard.bool(forKey: PrefKey.groupedProcesses) }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.groupedProcesses) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            let currentPID = ProcessInfo.processInfo.processIdentifier
            if running.contains(where: { $0.processIdentifier != currentPID }) {
                NSApp.terminate(nil)
                return
            }
        }

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            button.target = self
            button.action = #selector(statusBarClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        updateSystemSnapshot(forceRedraw: true)
        startIdleTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleaningManager.stopAll()
        idleTimer?.invalidate()
        popoverTimer?.invalidate()
        removeGlobalClickMonitor()
    }

    // MARK: - Timers & Sampling

    private func startIdleTimer() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.updateSystemSnapshot(forceRedraw: false)
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func updateSystemSnapshot(forceRedraw: Bool) {
        let snapshot = monitor.sampleSystemMemory()
        lastSnapshot = snapshot

        let percent = snapshot.usedPercentInt
        let pressure = snapshot.pressure
        let monochrome = monochromeOnly

        if forceRedraw
            || percent != lastRenderedPercent
            || pressure != lastRenderedPressure
            || monochrome != lastRenderedMonochrome
        {
            lastRenderedPercent = percent
            lastRenderedPressure = pressure
            lastRenderedMonochrome = monochrome
            updateStatusButton(snapshot: snapshot)
        }
    }

    private func updateStatusButton(snapshot: SystemMemorySnapshot) {
        guard let button = statusItem.button else { return }

        button.image = RingIconRenderer.renderRingImage(
            fraction: snapshot.usedFraction,
            pressure: snapshot.pressure,
            monochromeOnly: monochromeOnly
        )

        if showPercentage {
            button.title = " \(snapshot.usedPercentInt)%"
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }

        button.toolTip = "Memory: \(snapshot.usedPercentInt)% (\(ByteFormatting.short(snapshot.usedBytes)) / \(ByteFormatting.short(snapshot.totalBytes))) · Pressure: \(snapshot.pressure.label)"
    }

    // MARK: - Status Item Interaction

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showSettingsMenu(from: sender)
            return
        }
        togglePopover(from: sender)
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let vc = popoverVC ?? PopoverViewController(monitor: monitor, grouped: groupedProcesses)
        vc.delegate = self
        popoverVC = vc

        let pop = popover ?? {
            let p = NSPopover()
            p.behavior = .transient
            p.animates = true
            p.delegate = self
            return p
        }()
        pop.contentViewController = vc
        popover = pop

        let snapshot = monitor.sampleSystemMemory()
        lastSnapshot = snapshot
        updateStatusButton(snapshot: snapshot)

        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        vc.refresh(snapshot: snapshot)

        startPopoverTimer()
        installGlobalClickMonitor()
    }

    private func startPopoverTimer() {
        popoverTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, let pop = self.popover, pop.isShown else { return }
            let snapshot = self.monitor.sampleSystemMemory()
            self.lastSnapshot = snapshot
            self.updateStatusButton(snapshot: snapshot)
            self.popoverVC?.refresh(snapshot: snapshot)
        }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        popoverTimer = timer
    }

    private func installGlobalClickMonitor() {
        removeGlobalClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let pop = self.popover, pop.isShown else { return }
            pop.performClose(nil)
        }
    }

    private func removeGlobalClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        popoverTimer?.invalidate()
        popoverTimer = nil
        removeGlobalClickMonitor()
        popoverVC?.releaseTransientData()
    }

    // MARK: - PopoverViewControllerDelegate

    func popoverDidChangeGrouping(_ grouped: Bool) {
        groupedProcesses = grouped
    }

    func popoverDidRequestSettingsMenu(from anchorView: NSView) {
        showSettingsMenu(from: anchorView)
    }

    // MARK: - Settings Menu

    private func showSettingsMenu(from view: NSView) {
        let menu = NSMenu()

        let showPctItem = NSMenuItem(title: "Show Percentage Next to Ring", action: #selector(toggleShowPercentage), keyEquivalent: "")
        showPctItem.state = showPercentage ? .on : .off
        showPctItem.target = self
        menu.addItem(showPctItem)

        let monoItem = NSMenuItem(title: "Always Monochrome Ring", action: #selector(toggleMonochrome), keyEquivalent: "")
        monoItem.state = monochromeOnly ? .on : .off
        monoItem.target = self
        menu.addItem(monoItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let cleanKeyboardItem = NSMenuItem(title: "Clean Keyboard", action: #selector(toggleCleanKeyboard), keyEquivalent: "")
        cleanKeyboardItem.state = cleaningManager.isKeyboardCleaning ? .on : .off
        cleanKeyboardItem.target = self
        menu.addItem(cleanKeyboardItem)

        let cleanScreenItem = NSMenuItem(title: "Clean Screen", action: #selector(toggleCleanScreen), keyEquivalent: "")
        cleanScreenItem.state = cleaningManager.isScreenCleaning ? .on : .off
        cleanScreenItem.target = self
        menu.addItem(cleanScreenItem)

        menu.addItem(.separator())

        let amItem = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
        amItem.target = self
        menu.addItem(amItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MemorySpy", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        let location = NSPoint(x: 0, y: view.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: view)
    }

    @objc private func toggleShowPercentage() {
        showPercentage.toggle()
        updateSystemSnapshot(forceRedraw: true)
    }

    @objc private func toggleMonochrome() {
        monochromeOnly.toggle()
        updateSystemSnapshot(forceRedraw: true)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("MemorySpy: failed to toggle launch at login: \(error.localizedDescription)")
        }
    }

    @objc private func toggleCleanKeyboard() {
        popover?.performClose(nil)
        cleaningManager.toggleKeyboardCleaning()
    }

    @objc private func toggleCleanScreen() {
        popover?.performClose(nil)
        cleaningManager.toggleScreenCleaning()
    }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
