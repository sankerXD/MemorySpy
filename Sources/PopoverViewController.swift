import AppKit

protocol PopoverViewControllerDelegate: AnyObject {
    func popoverDidRequestSettingsMenu(from anchorView: NSView)
    func popoverDidChangeGrouping(_ grouped: Bool)
}

private final class SegmentedMemoryBar: NSView {
    private var appRatio: CGFloat = 0
    private var wiredRatio: CGFloat = 0
    private var compressedRatio: CGFloat = 0
    private var cachedRatio: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(snapshot: SystemMemorySnapshot) {
        let total = max(1.0, Double(snapshot.totalBytes))
        appRatio = CGFloat(min(1.0, Double(snapshot.appBytes) / total))
        wiredRatio = CGFloat(min(1.0, Double(snapshot.wiredBytes) / total))
        compressedRatio = CGFloat(min(1.0, Double(snapshot.compressedBytes) / total))
        cachedRatio = CGFloat(min(1.0, Double(snapshot.cachedBytes) / total))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let radius = rect.height / 2.0
        let clipPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        clipPath.addClip()

        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        rect.fill()

        var x: CGFloat = 0
        let segments: [(CGFloat, NSColor)] = [
            (appRatio, NSColor.systemBlue.withAlphaComponent(0.88)),
            (wiredRatio, NSColor.systemOrange.withAlphaComponent(0.88)),
            (compressedRatio, NSColor.systemPurple.withAlphaComponent(0.85)),
            (cachedRatio, NSColor.secondaryLabelColor.withAlphaComponent(0.28)),
        ]

        for (ratio, color) in segments where ratio > 0.002 {
            let w = min(rect.width - x, rect.width * ratio)
            guard w > 0 else { break }
            color.setFill()
            NSRect(x: x, y: 0, width: w, height: rect.height).fill()
            x += w
        }
    }
}

private final class ProcessCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let memLabel = NSTextField(labelWithString: "")
    private let killButton = NSButton()
    private var onKill: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        subLabel.textColor = .tertiaryLabelColor
        subLabel.setContentHuggingPriority(.required, for: .horizontal)

        memLabel.translatesAutoresizingMaskIntoConstraints = false
        memLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        memLabel.textColor = .secondaryLabelColor
        memLabel.alignment = .right
        memLabel.setContentHuggingPriority(.required, for: .horizontal)
        memLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        killButton.translatesAutoresizingMaskIntoConstraints = false
        killButton.isBordered = false
        killButton.bezelStyle = .inline
        killButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Quit Process")
        killButton.contentTintColor = .tertiaryLabelColor
        killButton.target = self
        killButton.action = #selector(handleKillClick)
        killButton.isHidden = true
        killButton.toolTip = "Quit process (Hold Option for Force Quit)"

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(subLabel)
        addSubview(memLabel)
        addSubview(killButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            subLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 5),
            subLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            subLabel.trailingAnchor.constraint(lessThanOrEqualTo: memLabel.leadingAnchor, constant: -6),

            killButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            killButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            killButton.widthAnchor.constraint(equalToConstant: 16),
            killButton.heightAnchor.constraint(equalToConstant: 16),

            memLabel.trailingAnchor.constraint(equalTo: killButton.leadingAnchor, constant: -4),
            memLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            memLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        killButton.isHidden = true
        onKill = nil
    }

    func configure(item: ProcessMemoryItem, icon: NSImage, isHovered: Bool, onKill: @escaping (Bool) -> Void) {
        iconView.image = icon
        nameLabel.stringValue = item.name
        subLabel.stringValue = item.isGrouped ? "×\(item.processCount)" : "#\(item.pid)"
        memLabel.stringValue = ByteFormatting.short(item.footprintBytes)
        killButton.isHidden = !isHovered
        self.onKill = onKill
    }

    func setHovered(_ hovered: Bool) {
        killButton.isHidden = !hovered
    }

    @objc private func handleKillClick() {
        let force = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        onKill?(force)
    }
}

private final class HoverTableView: NSTableView {
    private(set) var hoveredRow: Int = -1
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: visibleRect,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(windowPoint: event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(windowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredRow(-1)
    }

    func updateHoverForCurrentMouseLocation() {
        guard let window else {
            setHoveredRow(-1)
            return
        }
        updateHover(windowPoint: window.mouseLocationOutsideOfEventStream)
    }

    func resetHover() {
        setHoveredRow(-1)
    }

    private func updateHover(windowPoint: NSPoint) {
        let pt = convert(windowPoint, from: nil)
        guard visibleRect.contains(pt) else {
            setHoveredRow(-1)
            return
        }
        let targetRow = row(at: pt)
        setHoveredRow(targetRow)
    }

    private func setHoveredRow(_ newRow: Int) {
        guard newRow != hoveredRow else { return }
        let oldRow = hoveredRow
        hoveredRow = newRow

        if oldRow >= 0, oldRow < numberOfRows,
           let oldCell = view(atColumn: 0, row: oldRow, makeIfNecessary: false) as? ProcessCellView {
            oldCell.setHovered(false)
        }
        if newRow >= 0, newRow < numberOfRows,
           let newCell = view(atColumn: 0, row: newRow, makeIfNecessary: false) as? ProcessCellView {
            newCell.setHovered(true)
        }
    }
}

final class PopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var delegate: PopoverViewControllerDelegate?

    private let monitor: MemoryMonitor
    private var isGrouped: Bool
    private var items: [ProcessMemoryItem] = []
    private var filterText: String = ""

    private let titleLabel = NSTextField(labelWithString: "Memory")
    private let pressureBadge = NSTextField(labelWithString: "Normal")
    private let summaryLabel = NSTextField(labelWithString: "-- / -- GB")
    private let memoryBar = SegmentedMemoryBar()
    private let breakdownLabel = NSTextField(labelWithString: "")

    private let groupingControl = NSSegmentedControl(labels: ["All", "Grouped"], trackingMode: .selectOne, target: nil, action: nil)
    private let searchField = NSSearchField()

    private let scrollView = NSScrollView()
    private let tableView = HoverTableView()

    private let footerLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let settingsButton = NSButton()

    private let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    init(monitor: MemoryMonitor, grouped: Bool) {
        self.monitor = monitor
        self.isGrouped = grouped
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 344, height: 446))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        self.view = root
        buildLayout(in: root)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Prevent search field from stealing focus on open so Esc closes the popover immediately
        view.window?.makeFirstResponder(nil)
    }

    private func buildLayout(in root: NSView) {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)

        pressureBadge.translatesAutoresizingMaskIntoConstraints = false
        pressureBadge.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        pressureBadge.wantsLayer = true
        pressureBadge.layer?.cornerRadius = 4
        pressureBadge.alignment = .center

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        summaryLabel.textColor = .labelColor
        summaryLabel.alignment = .right

        memoryBar.translatesAutoresizingMaskIntoConstraints = false

        breakdownLabel.translatesAutoresizingMaskIntoConstraints = false
        breakdownLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        breakdownLabel.textColor = .secondaryLabelColor
        breakdownLabel.lineBreakMode = .byTruncatingTail

        groupingControl.translatesAutoresizingMaskIntoConstraints = false
        groupingControl.controlSize = .small
        groupingControl.segmentStyle = .rounded
        groupingControl.selectedSegment = isGrouped ? 1 : 0
        groupingControl.target = self
        groupingControl.action = #selector(groupingChanged)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.controlSize = .small
        searchField.placeholderString = "Filter processes..."
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true

        let topDivider = NSBox()
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        topDivider.boxType = .separator

        let bottomDivider = NSBox()
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        bottomDivider.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ProcessColumn"))
        column.width = 324
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.dataSource = self
        tableView.delegate = self

        let contextMenu = NSMenu()
        contextMenu.addItem(NSMenuItem(title: "Quit Process", action: #selector(menuQuitProcess), keyEquivalent: ""))
        contextMenu.addItem(NSMenuItem(title: "Force Quit Process", action: #selector(menuForceQuitProcess), keyEquivalent: ""))
        contextMenu.addItem(.separator())
        contextMenu.addItem(NSMenuItem(title: "Copy PID", action: #selector(menuCopyPID), keyEquivalent: ""))
        contextMenu.addItem(NSMenuItem(title: "Reveal in Finder", action: #selector(menuRevealInFinder), keyEquivalent: ""))
        for item in contextMenu.items {
            item.target = self
        }
        tableView.menu = contextMenu

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentViewBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        footerLabel.textColor = .tertiaryLabelColor

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.target = self
        refreshButton.action = #selector(manualRefresh)
        refreshButton.toolTip = "Refresh now"

        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.isBordered = false
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.toolTip = "Settings & Quit"

        root.addSubview(titleLabel)
        root.addSubview(pressureBadge)
        root.addSubview(summaryLabel)
        root.addSubview(memoryBar)
        root.addSubview(breakdownLabel)
        root.addSubview(groupingControl)
        root.addSubview(searchField)
        root.addSubview(topDivider)
        root.addSubview(scrollView)
        root.addSubview(bottomDivider)
        root.addSubview(footerLabel)
        root.addSubview(refreshButton)
        root.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),

            pressureBadge.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pressureBadge.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 7),
            pressureBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            pressureBadge.heightAnchor.constraint(equalToConstant: 17),

            summaryLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            memoryBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 9),
            memoryBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            memoryBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            memoryBar.heightAnchor.constraint(equalToConstant: 7),

            breakdownLabel.topAnchor.constraint(equalTo: memoryBar.bottomAnchor, constant: 6),
            breakdownLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            breakdownLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            groupingControl.topAnchor.constraint(equalTo: breakdownLabel.bottomAnchor, constant: 10),
            groupingControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),

            searchField.centerYAnchor.constraint(equalTo: groupingControl.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: groupingControl.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            topDivider.topAnchor.constraint(equalTo: groupingControl.bottomAnchor, constant: 8),
            topDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),

            bottomDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -30),

            footerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footerLabel.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -15),

            settingsButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            settingsButton.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 20),
            settingsButton.heightAnchor.constraint(equalToConstant: 20),

            refreshButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 20),
            refreshButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    func refresh(snapshot: SystemMemorySnapshot) {
        updateHeader(with: snapshot)
        items = monitor.sampleProcesses(limit: 50, grouped: isGrouped, filter: filterText)
        tableView.reloadData()
        tableView.updateHoverForCurrentMouseLocation()
        footerLabel.stringValue = "Top \(items.count) · Updated \(timeFormatter.string(from: Date()))"
    }

    func releaseTransientData() {
        tableView.resetHover()
        items.removeAll(keepingCapacity: false)
        tableView.reloadData()
        monitor.clearTransientCaches()
    }

    private func updateHeader(with snapshot: SystemMemorySnapshot) {
        summaryLabel.stringValue = "\(ByteFormatting.compact(snapshot.usedBytes)) / \(ByteFormatting.compact(snapshot.totalBytes)) (\(snapshot.usedPercentInt)%)"
        memoryBar.update(snapshot: snapshot)

        let swapText = snapshot.swapUsedBytes > 0 ? ByteFormatting.compact(snapshot.swapUsedBytes) : "0M"
        breakdownLabel.stringValue = "App \(ByteFormatting.compact(snapshot.appBytes)) · Wired \(ByteFormatting.compact(snapshot.wiredBytes)) · Comp \(ByteFormatting.compact(snapshot.compressedBytes)) · Swap \(swapText)"

        pressureBadge.stringValue = " \(snapshot.pressure.label) "
        switch snapshot.pressure {
        case .normal, .unknown:
            pressureBadge.textColor = .systemGreen
            pressureBadge.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.14).cgColor
        case .warning:
            pressureBadge.textColor = .systemOrange
            pressureBadge.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.16).cgColor
        case .critical:
            pressureBadge.textColor = .systemRed
            pressureBadge.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.18).cgColor
        }
    }

    // MARK: - NSTableViewDataSource & NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < items.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ProcessCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ProcessCellView)
            ?? ProcessCellView(frame: .zero)
        cell.identifier = identifier

        let item = items[row]
        let icon = monitor.icon(for: item)
        let isHovered = (row == self.tableView.hoveredRow)
        cell.configure(item: item, icon: icon, isHovered: isHovered) { [weak self] force in
            self?.terminateItem(item, force: force)
        }
        return cell
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        filterText = searchField.stringValue
        items = monitor.sampleProcesses(limit: 50, grouped: isGrouped, filter: filterText)
        tableView.reloadData()
        tableView.updateHoverForCurrentMouseLocation()
    }

    // MARK: - Actions

    @objc private func contentViewBoundsChanged() {
        tableView.updateHoverForCurrentMouseLocation()
    }

    @objc private func groupingChanged() {
        isGrouped = (groupingControl.selectedSegment == 1)
        delegate?.popoverDidChangeGrouping(isGrouped)
        manualRefresh()
    }

    @objc private func manualRefresh() {
        let snapshot = monitor.sampleSystemMemory()
        refresh(snapshot: snapshot)
    }

    @objc private func openSettings() {
        delegate?.popoverDidRequestSettingsMenu(from: settingsButton)
    }

    private func clickedItem() -> ProcessMemoryItem? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    @objc private func menuQuitProcess() {
        guard let item = clickedItem() else { return }
        terminateItem(item, force: false)
    }

    @objc private func menuForceQuitProcess() {
        guard let item = clickedItem() else { return }
        terminateItem(item, force: true)
    }

    @objc private func menuCopyPID() {
        guard let item = clickedItem() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(item.pid), forType: .string)
    }

    @objc private func menuRevealInFinder() {
        guard let item = clickedItem() else { return }
        if let bundleURL = item.bundleURL {
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        } else if let path = item.executablePath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    private func terminateItem(_ item: ProcessMemoryItem, force: Bool) {
        monitor.terminateItem(item, force: force)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.manualRefresh()
        }
    }
}
