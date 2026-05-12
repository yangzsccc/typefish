import AppKit
import AVFoundation
import ApplicationServices

enum MainWindowSection: Int, CaseIterable {
    case home = 0
    case history = 1
    case dictionary = 2
    case modes = 3
    case diagnostics = 4
    case settings = 5

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .modes: return "Modes"
        case .diagnostics: return "Diagnostics"
        case .settings: return "Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .home: return "Daily dictation, recovery, and setup at a glance"
        case .history: return "Recent transcripts, raw text, and paste recovery"
        case .dictionary: return "Names, vocabulary, replacements, and learned corrections"
        case .modes: return "Dictation, translation, and AI command workflows"
        case .diagnostics: return "Reliability, latency, permissions, and recovery"
        case .settings: return "Microphone, compression, maintenance, and updates"
        }
    }

    var symbolName: String {
        switch self {
        case .home: return "waveform"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "book.closed"
        case .modes: return "sparkles"
        case .diagnostics: return "gauge.with.dots.needle.67percent"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct DictionaryColumnLayout {
    static let minimumWrongWidth: CGFloat = 200
    static let minimumReplacementWidth: CGFloat = 260
    static let sourceWidth: CGFloat = 112

    static func widths(availableWidth: CGFloat, showsReplacementColumns: Bool) -> (wrong: CGFloat, replacement: CGFloat, source: CGFloat) {
        let width = max(availableWidth, 1)
        guard showsReplacementColumns else {
            return (wrong: width, replacement: 0, source: 0)
        }

        let minimumTotal = minimumWrongWidth + minimumReplacementWidth + sourceWidth
        let usableWidth = max(width, minimumTotal)
        if usableWidth == minimumTotal {
            return (wrong: minimumWrongWidth, replacement: minimumReplacementWidth, source: sourceWidth)
        }

        let remainingWidth = usableWidth - sourceWidth
        var wrongWidth = max(minimumWrongWidth, floor(remainingWidth * 0.45))
        var replacementWidth = remainingWidth - wrongWidth
        if replacementWidth < minimumReplacementWidth {
            replacementWidth = minimumReplacementWidth
            wrongWidth = remainingWidth - replacementWidth
        }

        return (wrong: wrongWidth, replacement: replacementWidth, source: sourceWidth)
    }
}

private final class DictionaryTableView: NSTableView {
    var onFrameWidthChanged: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        super.setFrameSize(newSize)
        if abs(oldWidth - newSize.width) > 0.5 {
            onFrameWidthChanged?()
        }
    }
}

/// Regular Dock-accessible TypeFish control center.
/// Hosts status, settings, dictionary editing, and learning visibility.
class MainWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private enum DictionaryViewKind: Int {
        case hints = 0
        case vocabulary = 1
        case manual = 2
        case autoLearned = 3
    }

    private struct DictionaryRow {
        var wrong: String
        var right: String
        var source: ReplacementSource
        var kind: DictionaryViewKind
    }

    private var window: NSWindow?
    private weak var state: AppState?

    private var statusLabel: NSTextField?
    private var healthLabel: NSTextField?
    private var dictSummaryLabel: NSTextField?
    private var micSummaryLabel: NSTextField?
    private var compressionSummaryLabel: NSTextField?
    private var dashboardLearningSummaryLabel: NSTextField?
    private var learningSummaryLabel: NSTextField?

    private var mainTabs: NSTabView?
    private var navButtons: [NSButton] = []
    private var selectedSectionIndex = 0
    private var contentTitleLabel: NSTextField?
    private var contentSubtitleLabel: NSTextField?
    private var setupSummaryLabel: NSTextField?
    private var lastResultLabel: NSTextField?
    private var diagnosticsSummaryLabel: NSTextField?
    private var latencySummaryLabel: NSTextField?
    private var permissionSummaryLabel: NSTextField?
    private var dictionarySegment: NSSegmentedControl?
    private var dictionarySearch: NSSearchField?
    private var dictionaryTable: NSTableView?
    private var dictionaryRows: [DictionaryRow] = []
    private var historyTable: NSTableView?
    private var historyRows: [TranscriptionLogger.HistoryEntry] = []
    private var loggedAutoCorrectionKeys: Set<String> = []

    private var addButton: NSButton?
    private var editButton: NSButton?
    private var deleteButton: NSButton?

    private var micPopup: NSPopUpButton?
    private var compressionPopup: NSPopUpButton?

    init(state: AppState) {
        self.state = state
        super.init()
    }

    func showWindow() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "TypeFish"
        w.center()
        w.minSize = NSSize(width: 820, height: 560)
        w.isReleasedWhenClosed = false
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.styleMask.insert(.fullSizeContentView)
        w.backgroundColor = .clear

        let root = NSView(frame: w.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor

        let sidebarWidth: CGFloat = 206
        let sidebar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: root.bounds.height))
        sidebar.autoresizingMask = [.height]
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        root.addSubview(sidebar)

        buildSidebar(in: sidebar)

        let content = NSView(frame: NSRect(x: sidebarWidth, y: 0, width: root.bounds.width - sidebarWidth, height: root.bounds.height))
        content.autoresizingMask = [.width, .height]
        root.addSubview(content)

        let title = NSTextField(labelWithString: "")
        title.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: 32, y: content.bounds.height - 62, width: content.bounds.width - 64, height: 30)
        title.autoresizingMask = [.width, .minYMargin]
        content.addSubview(title)
        self.contentTitleLabel = title

        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 32, y: content.bounds.height - 86, width: content.bounds.width - 64, height: 20)
        subtitle.autoresizingMask = [.width, .minYMargin]
        content.addSubview(subtitle)
        self.contentSubtitleLabel = subtitle

        refreshLoggedAutoCorrectionKeys()
        refreshHistory()

        let tabs = NSTabView(frame: NSRect(x: 24, y: 22, width: content.bounds.width - 48, height: content.bounds.height - 118))
        tabs.autoresizingMask = [.width, .height]
        tabs.tabViewType = .noTabsNoBorder
        tabs.addTabViewItem(tabItem(label: MainWindowSection.home.title, view: dashboardView(frame: tabs.bounds)))
        tabs.addTabViewItem(tabItem(label: MainWindowSection.history.title, view: historyView(frame: tabs.bounds)))
        tabs.addTabViewItem(tabItem(label: MainWindowSection.dictionary.title, view: dictionaryView(frame: tabs.bounds)))
        tabs.addTabViewItem(tabItem(label: MainWindowSection.modes.title, view: modesView(frame: tabs.bounds)))
        tabs.addTabViewItem(tabItem(label: MainWindowSection.diagnostics.title, view: diagnosticsView(frame: tabs.bounds)))
        tabs.addTabViewItem(tabItem(label: MainWindowSection.settings.title, view: settingsView(frame: tabs.bounds)))
        content.addSubview(tabs)
        self.mainTabs = tabs
        updateNavigationSelection()
        updateContentHeader()

        w.contentView = root
        self.window = w

        refreshDictionaryTable()
        refreshPopups()
        updateStatus()

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateStatus() {
        guard let state = state else { return }

        if window?.isVisible == true {
            refreshLoggedAutoCorrectionKeys()
            refreshHistory()
            refreshDictionaryTable()
            refreshPopups()
        }

        if state.isRecording {
            if state.isCommandMode {
                statusLabel?.stringValue = "Recording AI command"
                statusLabel?.textColor = .systemPurple
            } else if state.isTranslateMode {
                statusLabel?.stringValue = "Recording translation"
                statusLabel?.textColor = .systemGreen
            } else {
                statusLabel?.stringValue = "Recording"
                statusLabel?.textColor = .systemRed
            }
        } else if state.isProcessing {
            statusLabel?.stringValue = "Processing"
            statusLabel?.textColor = .systemOrange
        } else {
            statusLabel?.stringValue = "Ready"
            statusLabel?.textColor = .systemGreen
        }

        healthLabel?.stringValue = healthStatsText()
        dictSummaryLabel?.stringValue = dictionarySummaryText()
        micSummaryLabel?.stringValue = state.config.preferredMicrophone ?? "System Default"
        compressionSummaryLabel?.stringValue = AppState.compressionTitle(for: state.config.audioCompressionBitrate)
        dashboardLearningSummaryLabel?.stringValue = learningSummaryText()
        learningSummaryLabel?.stringValue = learningSummaryText()
        setupSummaryLabel?.stringValue = setupSummaryText()
        lastResultLabel?.stringValue = lastResultSummaryText()
        diagnosticsSummaryLabel?.stringValue = diagnosticsSummaryText()
        latencySummaryLabel?.stringValue = latencySummaryText()
        permissionSummaryLabel?.stringValue = setupSummaryText()
        updateContentHeader()
    }

    // MARK: - Tabs

    private func tabItem(label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    private func buildSidebar(in sidebar: NSView) {
        let mark = NSTextField(labelWithString: "TF")
        mark.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        mark.alignment = .center
        mark.textColor = .white
        mark.frame = NSRect(x: 22, y: sidebar.bounds.height - 64, width: 34, height: 24)
        mark.wantsLayer = true
        mark.layer?.cornerRadius = 7
        mark.layer?.backgroundColor = NSColor.systemBlue.cgColor
        mark.autoresizingMask = [.minYMargin]
        sidebar.addSubview(mark)

        let name = NSTextField(labelWithString: "TypeFish")
        name.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        name.textColor = .labelColor
        name.frame = NSRect(x: 66, y: sidebar.bounds.height - 58, width: 100, height: 22)
        name.autoresizingMask = [.minYMargin]
        sidebar.addSubview(name)

        let version = NSTextField(labelWithString: "v\(Updater.currentVersion)")
        version.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        version.textColor = .secondaryLabelColor
        version.frame = NSRect(x: 66, y: sidebar.bounds.height - 76, width: 100, height: 16)
        version.autoresizingMask = [.minYMargin]
        sidebar.addSubview(version)

        navButtons = []
        for section in MainWindowSection.allCases {
            let button = makeNavButton(title: section.title, symbol: section.symbolName, index: section.rawValue)
            button.frame = NSRect(x: 12, y: sidebar.bounds.height - 126 - CGFloat(section.rawValue * 42), width: sidebar.bounds.width - 24, height: 34)
            button.autoresizingMask = [.width, .minYMargin]
            sidebar.addSubview(button)
            navButtons.append(button)
        }
    }

    private func makeNavButton(title: String, symbol: String, index: Int) -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.target = self
        button.action = #selector(navigationClicked(_:))
        button.tag = index
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.masksToBounds = true

        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.image = icon
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .left
        button.attributedTitle = navTitle(title, selected: false)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    private func navTitle(_ title: String, selected: Bool) -> NSAttributedString {
        let titleColor: NSColor = selected ? .controlAccentColor : .labelColor
        return NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: titleColor
            ]
        )
    }

    @objc private func navigationClicked(_ sender: NSButton) {
        selectedSectionIndex = sender.tag
        mainTabs?.selectTabViewItem(at: sender.tag)
        updateNavigationSelection()
        updateContentHeader()
    }

    private func updateNavigationSelection() {
        for (index, button) in navButtons.enumerated() {
            let selected = index == selectedSectionIndex
            button.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor
                : NSColor.clear.cgColor
            button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            button.attributedTitle = navTitle(sectionTitle(for: index), selected: selected)
        }
    }

    private func updateContentHeader() {
        contentTitleLabel?.stringValue = sectionTitle(for: selectedSectionIndex)
        contentSubtitleLabel?.stringValue = sectionSubtitle(for: selectedSectionIndex)
    }

    private func sectionTitle(for index: Int) -> String {
        MainWindowSection(rawValue: index)?.title ?? MainWindowSection.home.title
    }

    private func sectionSubtitle(for index: Int) -> String {
        guard let section = MainWindowSection(rawValue: index) else {
            return MainWindowSection.home.subtitle
        }

        switch section {
        case .dictionary:
            return dictionarySummaryText()
        case .settings:
            guard let state = state else { return "System Default" }
            let microphone = state.config.preferredMicrophone ?? "System Default"
            let compression = AppState.compressionTitle(for: state.config.audioCompressionBitrate)
            return "\(microphone) · \(compression)"
        case .diagnostics:
            return diagnosticsSummaryText()
        case .history:
            return lastResultSummaryText()
        default:
            return section.subtitle
        }
    }

    private func dashboardView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.autoresizingMask = [.width, .height]

        let topHeight: CGFloat = 124
        let topY = frame.height - topHeight - 22
        let statusPanel = surface(frame: NSRect(x: 0, y: topY, width: frame.width, height: topHeight))
        statusPanel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(statusPanel)

        addSectionTitle("TypeFish", to: statusPanel, x: 22, y: 84)
        let status = valueLabel("Ready", size: 26, weight: .semibold)
        status.textColor = .systemGreen
        status.frame = NSRect(x: 22, y: 48, width: 280, height: 34)
        statusPanel.addSubview(status)
        self.statusLabel = status

        let setup = valueLabel(setupSummaryText(), size: 12, weight: .regular)
        setup.textColor = .secondaryLabelColor
        setup.frame = NSRect(x: 22, y: 22, width: 360, height: 18)
        setup.autoresizingMask = [.width]
        statusPanel.addSubview(setup)
        self.setupSummaryLabel = setup

        let healthX = min(frame.width * 0.50, 420)
        addSectionTitle("Reliability", to: statusPanel, x: healthX, y: 84)
        let health = valueLabel(healthStatsText(), size: 12, weight: .regular)
        health.textColor = .secondaryLabelColor
        health.frame = NSRect(x: healthX, y: 58, width: statusPanel.bounds.width - healthX - 22, height: 20)
        health.autoresizingMask = [.width]
        statusPanel.addSubview(health)
        self.healthLabel = health

        addSectionTitle("Last Result", to: statusPanel, x: healthX, y: 34)
        let lastResult = valueLabel(lastResultSummaryText(), size: 12, weight: .regular)
        lastResult.textColor = .labelColor
        lastResult.frame = NSRect(x: healthX, y: 14, width: statusPanel.bounds.width - healthX - 22, height: 20)
        lastResult.autoresizingMask = [.width]
        statusPanel.addSubview(lastResult)
        self.lastResultLabel = lastResult

        let bodyHeight = frame.height - topHeight - 60
        let leftWidth = min(frame.width * 0.34, 280)
        let middleWidth = max(min(frame.width * 0.34, 300), 250)
        let rightX = leftWidth + 20
        let finalX = rightX + middleWidth + 20
        let rightWidth = max(frame.width - finalX, 250)

        let setupPanel = surface(frame: NSRect(x: 0, y: 22, width: leftWidth, height: bodyHeight))
        setupPanel.autoresizingMask = [.height, .maxXMargin]
        view.addSubview(setupPanel)

        addSectionTitle("Setup", to: setupPanel, x: 20, y: setupPanel.bounds.height - 36)
        let setupRows = setupRows()
        for (index, row) in setupRows.enumerated() {
            addStatusRow(row.title, row.value, ok: row.ok, to: setupPanel, x: 20, y: setupPanel.bounds.height - 78 - CGFloat(index * 46))
        }

        let recoveryPanel = surface(frame: NSRect(x: rightX, y: 22, width: middleWidth, height: bodyHeight))
        recoveryPanel.autoresizingMask = [.height]
        view.addSubview(recoveryPanel)

        addSectionTitle("Recovery", to: recoveryPanel, x: 20, y: recoveryPanel.bounds.height - 36)
        _ = addInfoRow("Recent output", lastResultSummaryText(), to: recoveryPanel, x: 20, y: recoveryPanel.bounds.height - 84)
        let copy = NSButton(title: "Copy Last Result", target: self, action: #selector(copyLastResult))
        copy.frame = NSRect(x: 20, y: recoveryPanel.bounds.height - 142, width: recoveryPanel.bounds.width - 40, height: 32)
        copy.autoresizingMask = [.width, .minYMargin]
        styleActionButton(copy, symbol: "doc.on.doc", prominent: true)
        recoveryPanel.addSubview(copy)

        let paste = NSButton(title: "Paste Last Result Again", target: self, action: #selector(pasteLastResult))
        paste.frame = NSRect(x: 20, y: recoveryPanel.bounds.height - 184, width: recoveryPanel.bounds.width - 40, height: 32)
        paste.autoresizingMask = [.width, .minYMargin]
        styleActionButton(paste, symbol: "arrow.turn.down.left")
        recoveryPanel.addSubview(paste)

        let openHistory = NSButton(title: "Open History", target: self, action: #selector(showHistory))
        openHistory.frame = NSRect(x: 20, y: recoveryPanel.bounds.height - 226, width: recoveryPanel.bounds.width - 40, height: 32)
        openHistory.autoresizingMask = [.width, .minYMargin]
        styleActionButton(openHistory, symbol: "clock.arrow.circlepath")
        recoveryPanel.addSubview(openHistory)

        let detailsPanel = surface(frame: NSRect(x: finalX, y: 22, width: rightWidth, height: bodyHeight))
        detailsPanel.autoresizingMask = [.width, .height]
        view.addSubview(detailsPanel)

        addSectionTitle("Daily Controls", to: detailsPanel, x: 20, y: detailsPanel.bounds.height - 36)
        let dict = addInfoRow("Dictionary", dictionarySummaryText(), to: detailsPanel, x: 20, y: detailsPanel.bounds.height - 84)
        self.dictSummaryLabel = dict

        addDivider(to: detailsPanel, x: 20, y: detailsPanel.bounds.height - 108)
        let mic = addInfoRow("Microphone", "System Default", to: detailsPanel, x: 20, y: detailsPanel.bounds.height - 158)
        self.micSummaryLabel = mic

        addDivider(to: detailsPanel, x: 20, y: detailsPanel.bounds.height - 182)
        let compression = addInfoRow("Compression", "", to: detailsPanel, x: 20, y: detailsPanel.bounds.height - 232)
        self.compressionSummaryLabel = compression

        addDivider(to: detailsPanel, x: 20, y: detailsPanel.bounds.height - 256)
        let learning = addInfoRow("Learning", learningSummaryText(), to: detailsPanel, x: 20, y: detailsPanel.bounds.height - 306)
        self.dashboardLearningSummaryLabel = learning

        return view
    }

    private func historyView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.autoresizingMask = [.width, .height]

        let actionsPanel = surface(frame: NSRect(x: 0, y: frame.height - 96, width: frame.width, height: 74))
        actionsPanel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(actionsPanel)

        addSectionTitle("Recent Results", to: actionsPanel, x: 20, y: 42)
        let summary = valueLabel(lastResultSummaryText(), size: 13, weight: .regular)
        summary.textColor = .secondaryLabelColor
        summary.frame = NSRect(x: 20, y: 18, width: actionsPanel.bounds.width - 350, height: 20)
        summary.autoresizingMask = [.width]
        actionsPanel.addSubview(summary)
        self.lastResultLabel = summary

        let copy = NSButton(title: "Copy Last", target: self, action: #selector(copyLastResult))
        copy.frame = NSRect(x: actionsPanel.bounds.width - 324, y: 22, width: 104, height: 30)
        copy.autoresizingMask = [.minXMargin]
        styleActionButton(copy, symbol: "doc.on.doc")
        actionsPanel.addSubview(copy)

        let paste = NSButton(title: "Paste Again", target: self, action: #selector(pasteLastResult))
        paste.frame = NSRect(x: actionsPanel.bounds.width - 212, y: 22, width: 110, height: 30)
        paste.autoresizingMask = [.minXMargin]
        styleActionButton(paste, symbol: "arrow.turn.down.left")
        actionsPanel.addSubview(paste)

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshHistoryAction))
        refresh.frame = NSRect(x: actionsPanel.bounds.width - 94, y: 22, width: 84, height: 30)
        refresh.autoresizingMask = [.minXMargin]
        styleActionButton(refresh, symbol: "arrow.clockwise")
        actionsPanel.addSubview(refresh)

        let tableSurface = surface(frame: NSRect(x: 0, y: 22, width: frame.width, height: frame.height - 140))
        tableSurface.autoresizingMask = [.width, .height]
        view.addSubview(tableSurface)

        let scroll = NSScrollView(frame: NSRect(x: 1, y: 1, width: tableSurface.bounds.width - 2, height: tableSurface.bounds.height - 2))
        scroll.autoresizingMask = [.width, .height]
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let table = NSTableView(frame: scroll.bounds)
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.rowHeight = 42
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.delegate = self
        table.dataSource = self
        table.allowsMultipleSelection = false

        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("historyTime"))
        timeColumn.title = "Time"
        timeColumn.width = 148
        table.addTableColumn(timeColumn)

        let modeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("historyMode"))
        modeColumn.title = "Mode"
        modeColumn.width = 92
        table.addTableColumn(modeColumn)

        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("historyText"))
        textColumn.title = "Result"
        textColumn.width = max(frame.width - 430, 260)
        table.addTableColumn(textColumn)

        let modelColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("historyModel"))
        modelColumn.title = "Model"
        modelColumn.width = 178
        table.addTableColumn(modelColumn)

        scroll.documentView = table
        tableSurface.addSubview(scroll)
        self.historyTable = table

        refreshHistory()
        return view
    }

    private func modesView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.autoresizingMask = [.width, .height]

        let columns: CGFloat = 2
        let gap: CGFloat = 18
        let cardWidth = floor((frame.width - gap) / columns)
        let cardHeight: CGFloat = 142
        let modes = [
            ("Default Dictation", "Option Space", "Light cleanup, original wording, bilingual text preserved.", "waveform", NSColor.systemBlue),
            ("Translate", "Control Option Space", "Speak any language and paste English output.", "globe", NSColor.systemGreen),
            ("AI Command", "Control Option Command Space", "Generate or transform selected text with a voice instruction.", "sparkles", NSColor.systemPurple),
            ("Recovery", "History", "Copy, retry manually, or paste the last successful result again.", "clock.arrow.circlepath", NSColor.systemOrange)
        ]

        for (index, mode) in modes.enumerated() {
            let col = CGFloat(index % 2)
            let row = CGFloat(index / 2)
            let x = col * (cardWidth + gap)
            let y = frame.height - 22 - cardHeight - row * (cardHeight + gap)
            let card = surface(frame: NSRect(x: x, y: y, width: cardWidth, height: cardHeight))
            card.autoresizingMask = [.width, .minYMargin]
            view.addSubview(card)

            let icon = NSImageView(frame: NSRect(x: 20, y: cardHeight - 58, width: 28, height: 28))
            icon.image = NSImage(systemSymbolName: mode.3, accessibilityDescription: mode.0)
            icon.contentTintColor = mode.4
            card.addSubview(icon)

            let title = valueLabel(mode.0, size: 16, weight: .semibold)
            title.frame = NSRect(x: 60, y: cardHeight - 55, width: cardWidth - 82, height: 22)
            title.autoresizingMask = [.width]
            card.addSubview(title)

            let shortcut = valueLabel(mode.1, size: 12, weight: .medium)
            shortcut.textColor = mode.4
            shortcut.frame = NSRect(x: 60, y: cardHeight - 78, width: cardWidth - 82, height: 18)
            shortcut.autoresizingMask = [.width]
            card.addSubview(shortcut)

            let desc = valueLabel(mode.2, size: 13, weight: .regular)
            desc.textColor = .secondaryLabelColor
            desc.lineBreakMode = .byWordWrapping
            desc.frame = NSRect(x: 20, y: 22, width: cardWidth - 40, height: 42)
            desc.autoresizingMask = [.width]
            card.addSubview(desc)
        }

        return view
    }

    private func diagnosticsView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.autoresizingMask = [.width, .height]

        let stats = MetricsLogger.recentStats(hours: 24)
        let topHeight: CGFloat = 116
        let cardWidth = floor((frame.width - 36) / 3)
        let tiles = [
            ("Success", stats.total == 0 ? "No data" : "\(stats.successRate)%", diagnosticsSummaryText(), NSColor.systemGreen),
            ("Latency", stats.avgTotalMs == 0 ? "No data" : "\(stats.avgTotalMs)ms", latencySummaryText(), NSColor.systemBlue),
            ("Setup", setupRows().allSatisfy { $0.ok } ? "Ready" : "Needs attention", setupSummaryText(), NSColor.systemOrange)
        ]

        for (index, tile) in tiles.enumerated() {
            let x = CGFloat(index) * (cardWidth + 18)
            let card = surface(frame: NSRect(x: x, y: frame.height - topHeight - 22, width: cardWidth, height: topHeight))
            card.autoresizingMask = [.width, .minYMargin]
            view.addSubview(card)
            addSectionTitle(tile.0, to: card, x: 18, y: 78)
            let value = valueLabel(tile.1, size: 24, weight: .semibold)
            value.textColor = tile.3
            value.frame = NSRect(x: 18, y: 42, width: cardWidth - 36, height: 30)
            value.autoresizingMask = [.width]
            card.addSubview(value)
            let detail = valueLabel(tile.2, size: 12, weight: .regular)
            detail.textColor = .secondaryLabelColor
            detail.frame = NSRect(x: 18, y: 18, width: cardWidth - 36, height: 18)
            detail.autoresizingMask = [.width]
            card.addSubview(detail)
            if index == 0 { self.diagnosticsSummaryLabel = detail }
            if index == 1 { self.latencySummaryLabel = detail }
            if index == 2 { self.permissionSummaryLabel = detail }
        }

        let detailsPanel = surface(frame: NSRect(x: 0, y: 22, width: frame.width, height: frame.height - topHeight - 64))
        detailsPanel.autoresizingMask = [.width, .height]
        view.addSubview(detailsPanel)

        addSectionTitle("Checks", to: detailsPanel, x: 20, y: detailsPanel.bounds.height - 36)
        let rows = setupRows()
        for (index, row) in rows.enumerated() {
            addStatusRow(row.title, row.value, ok: row.ok, to: detailsPanel, x: 20, y: detailsPanel.bounds.height - 78 - CGFloat(index * 44))
        }

        addSectionTitle("Recovery", to: detailsPanel, x: max(detailsPanel.bounds.width * 0.52, 340), y: detailsPanel.bounds.height - 36)
        let recoveryX = max(detailsPanel.bounds.width * 0.52, 340)
        let copy = NSButton(title: "Copy Last Result", target: self, action: #selector(copyLastResult))
        copy.frame = NSRect(x: recoveryX, y: detailsPanel.bounds.height - 86, width: 180, height: 32)
        copy.autoresizingMask = [.minXMargin, .minYMargin]
        styleActionButton(copy, symbol: "doc.on.doc", prominent: true)
        detailsPanel.addSubview(copy)

        let paste = NSButton(title: "Paste Last Result", target: self, action: #selector(pasteLastResult))
        paste.frame = NSRect(x: recoveryX, y: detailsPanel.bounds.height - 128, width: 180, height: 32)
        paste.autoresizingMask = [.minXMargin, .minYMargin]
        styleActionButton(paste, symbol: "arrow.turn.down.left")
        detailsPanel.addSubview(paste)

        let logs = NSButton(title: "Open Logs Folder", target: self, action: #selector(openLogsFolder))
        logs.frame = NSRect(x: recoveryX, y: detailsPanel.bounds.height - 170, width: 180, height: 32)
        logs.autoresizingMask = [.minXMargin, .minYMargin]
        styleActionButton(logs, symbol: "folder")
        detailsPanel.addSubview(logs)

        return view
    }

    private func dictionaryView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.autoresizingMask = [.width, .height]

        let segment = NSSegmentedControl(
            labels: ["Hints", "Vocabulary", "Manual", "Auto"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(dictionarySegmentChanged)
        )
        segment.selectedSegment = DictionaryViewKind.hints.rawValue
        segment.frame = NSRect(x: 0, y: frame.height - 44, width: 390, height: 30)
        segment.segmentStyle = .separated
        segment.autoresizingMask = [.minYMargin]
        view.addSubview(segment)
        self.dictionarySegment = segment

        let search = NSSearchField(frame: NSRect(x: frame.width - 240, y: frame.height - 44, width: 240, height: 30))
        search.placeholderString = "Search"
        search.target = self
        search.action = #selector(dictionarySearchChanged)
        search.autoresizingMask = [.minXMargin, .minYMargin]
        view.addSubview(search)
        self.dictionarySearch = search

        let tableSurface = surface(frame: NSRect(x: 0, y: 70, width: frame.width, height: frame.height - 132))
        tableSurface.autoresizingMask = [.width, .height]
        view.addSubview(tableSurface)

        let scroll = NSScrollView(frame: NSRect(x: 1, y: 1, width: tableSurface.bounds.width - 2, height: tableSurface.bounds.height - 2))
        scroll.autoresizingMask = [.width, .height]
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let table = DictionaryTableView(frame: scroll.bounds)
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.rowHeight = 30
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.delegate = self
        table.dataSource = self
        table.allowsMultipleSelection = false
        table.onFrameWidthChanged = { [weak self] in
            self?.updateDictionaryColumns(for: self?.selectedDictionaryKind() ?? .hints)
        }

        let wrongColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("wrong"))
        wrongColumn.title = "Term"
        wrongColumn.minWidth = DictionaryColumnLayout.minimumWrongWidth
        table.addTableColumn(wrongColumn)

        let rightColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("right"))
        rightColumn.title = "Replacement"
        rightColumn.minWidth = DictionaryColumnLayout.minimumReplacementWidth
        table.addTableColumn(rightColumn)

        let sourceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sourceColumn.title = "Source"
        sourceColumn.minWidth = DictionaryColumnLayout.sourceWidth
        sourceColumn.maxWidth = DictionaryColumnLayout.sourceWidth
        table.addTableColumn(sourceColumn)

        scroll.documentView = table
        tableSurface.addSubview(scroll)
        self.dictionaryTable = table

        let add = NSButton(title: "Add", target: self, action: #selector(addDictionaryEntry))
        add.frame = NSRect(x: 0, y: 22, width: 82, height: 30)
        styleActionButton(add, symbol: "plus")
        view.addSubview(add)
        self.addButton = add

        let edit = NSButton(title: "Edit", target: self, action: #selector(editDictionaryEntry))
        edit.frame = NSRect(x: 90, y: 22, width: 82, height: 30)
        styleActionButton(edit, symbol: "pencil")
        view.addSubview(edit)
        self.editButton = edit

        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteDictionaryEntry))
        delete.frame = NSRect(x: 180, y: 22, width: 94, height: 30)
        styleActionButton(delete, symbol: "trash")
        view.addSubview(delete)
        self.deleteButton = delete

        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadDictionary))
        reload.frame = NSRect(x: frame.width - 208, y: 22, width: 92, height: 30)
        reload.autoresizingMask = [.minXMargin]
        styleActionButton(reload, symbol: "arrow.clockwise")
        view.addSubview(reload)

        let open = NSButton(title: "Open File", target: self, action: #selector(openDictionaryFile))
        open.frame = NSRect(x: frame.width - 108, y: 22, width: 108, height: 30)
        open.autoresizingMask = [.minXMargin]
        styleActionButton(open, symbol: "doc")
        view.addSubview(open)

        return view
    }

    private func settingsView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.autoresizingMask = [.width, .height]

        let capturePanel = surface(frame: NSRect(x: 0, y: frame.height - 190, width: frame.width, height: 168))
        capturePanel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(capturePanel)

        addSectionTitle("Capture", to: capturePanel, x: 20, y: 128)
        let micLabel = mutedLabel("Microphone")
        micLabel.frame = NSRect(x: 20, y: 92, width: 140, height: 18)
        capturePanel.addSubview(micLabel)

        let mic = NSPopUpButton(frame: NSRect(x: 160, y: 86, width: 340, height: 30))
        mic.target = self
        mic.action = #selector(microphoneChanged)
        capturePanel.addSubview(mic)
        self.micPopup = mic

        let compressionLabel = mutedLabel("Compression")
        compressionLabel.frame = NSRect(x: 20, y: 48, width: 140, height: 18)
        capturePanel.addSubview(compressionLabel)

        let compression = NSPopUpButton(frame: NSRect(x: 160, y: 42, width: 340, height: 30))
        compression.target = self
        compression.action = #selector(compressionChanged)
        capturePanel.addSubview(compression)
        self.compressionPopup = compression

        let maintenancePanel = surface(frame: NSRect(x: 0, y: frame.height - 358, width: frame.width, height: 140))
        maintenancePanel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(maintenancePanel)

        addSectionTitle("Maintenance", to: maintenancePanel, x: 20, y: 100)
        let reload = NSButton(title: "Reload Dictionary", target: self, action: #selector(reloadDictionary))
        reload.frame = NSRect(x: 20, y: 52, width: 160, height: 32)
        styleActionButton(reload, symbol: "arrow.clockwise")
        maintenancePanel.addSubview(reload)

        let open = NSButton(title: "Open Dictionary File", target: self, action: #selector(openDictionaryFile))
        open.frame = NSRect(x: 190, y: 52, width: 178, height: 32)
        styleActionButton(open, symbol: "doc")
        maintenancePanel.addSubview(open)

        let update = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdates))
        update.frame = NSRect(x: 378, y: 52, width: 160, height: 32)
        styleActionButton(update, symbol: "arrow.down.circle")
        maintenancePanel.addSubview(update)

        let exitPanel = surface(frame: NSRect(x: 0, y: 22, width: frame.width, height: 92))
        exitPanel.autoresizingMask = [.width, .maxYMargin]
        view.addSubview(exitPanel)

        addSectionTitle("App", to: exitPanel, x: 20, y: 52)

        let quit = NSButton(title: "Quit TypeFish", target: self, action: #selector(quit))
        quit.frame = NSRect(x: frame.width - 160, y: 30, width: 138, height: 32)
        quit.autoresizingMask = [.minXMargin]
        styleActionButton(quit, symbol: "power", destructive: true)
        exitPanel.addSubview(quit)

        return view
    }

    private func learningView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.autoresizingMask = [.width, .height]

        let summaryPanel = surface(frame: NSRect(x: 0, y: frame.height - 168, width: frame.width, height: 146))
        summaryPanel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(summaryPanel)

        addSectionTitle("Auto-Learned Corrections", to: summaryPanel, x: 20, y: 106)
        let summary = valueLabel(learningSummaryText(), size: 13, weight: .regular)
        summary.textColor = .secondaryLabelColor
        summary.frame = NSRect(x: 20, y: 76, width: frame.width - 40, height: 22)
        summary.autoresizingMask = [.width, .minYMargin]
        summaryPanel.addSubview(summary)
        self.learningSummaryLabel = summary

        let jump = NSButton(title: "Open Auto Corrections", target: self, action: #selector(showAutoLearnedCorrections))
        jump.frame = NSRect(x: 20, y: 28, width: 188, height: 32)
        jump.autoresizingMask = [.minYMargin]
        styleActionButton(jump, symbol: "sparkles", prominent: true)
        summaryPanel.addSubview(jump)

        let log = NSButton(title: "Open Logs Folder", target: self, action: #selector(openLogsFolder))
        log.frame = NSRect(x: 218, y: 28, width: 148, height: 32)
        log.autoresizingMask = [.minYMargin]
        styleActionButton(log, symbol: "folder")
        summaryPanel.addSubview(log)

        let filesPanel = surface(frame: NSRect(x: 0, y: 22, width: frame.width, height: frame.height - 214))
        filesPanel.autoresizingMask = [.width, .height]
        view.addSubview(filesPanel)

        addSectionTitle("Files", to: filesPanel, x: 20, y: filesPanel.bounds.height - 36)
        _ = addInfoRow("Dictionary", CustomDictionary.fileURL.path, to: filesPanel, x: 20, y: filesPanel.bounds.height - 84)
        addDivider(to: filesPanel, x: 20, y: filesPanel.bounds.height - 108)
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/typefish/logs/auto-corrections.jsonl")
            .path
        _ = addInfoRow("Learning Log", logPath, to: filesPanel, x: 20, y: filesPanel.bounds.height - 158)

        return view
    }

    // MARK: - Dictionary Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === historyTable {
            return historyRows.count
        }
        return dictionaryRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let identifier = column.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier

        let textField: NSTextField
        if let existing = cell.textField {
            textField = existing
        } else {
            textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.frame = NSRect(x: 8, y: 3, width: column.width - 16, height: 20)
            textField.autoresizingMask = [.width]
            cell.addSubview(textField)
            cell.textField = textField
        }

        if tableView === historyTable {
            guard row >= 0, row < historyRows.count else { return nil }
            let item = historyRows[row]
            switch identifier.rawValue {
            case "historyTime":
                textField.stringValue = displayTimestamp(item.timestamp)
                textField.textColor = .secondaryLabelColor
            case "historyMode":
                textField.stringValue = item.displayMode
                textField.textColor = modeColor(item.mode)
            case "historyText":
                textField.stringValue = item.preview
                textField.textColor = .labelColor
            case "historyModel":
                textField.stringValue = item.polisherModel.isEmpty ? item.whisperModel : item.polisherModel
                textField.textColor = .tertiaryLabelColor
            default:
                textField.stringValue = ""
            }
            return cell
        }

        guard row >= 0, row < dictionaryRows.count else { return nil }
        let item = dictionaryRows[row]
        switch identifier.rawValue {
        case "wrong":
            textField.stringValue = item.wrong
            textField.textColor = .labelColor
        case "right":
            textField.stringValue = item.right
            textField.textColor = .labelColor
        case "source":
            textField.stringValue = sourceTitle(item.source)
            textField.textColor = item.source == .autoLearned ? .systemBlue : .secondaryLabelColor
        default:
            textField.stringValue = ""
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDictionaryButtons()
    }

    private func selectedDictionaryKind() -> DictionaryViewKind {
        let value = dictionarySegment?.selectedSegment ?? DictionaryViewKind.hints.rawValue
        return DictionaryViewKind(rawValue: value) ?? .hints
    }

    private func refreshDictionaryTable() {
        guard let state = state else { return }
        let kind = selectedDictionaryKind()
        let query = dictionarySearch?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        var rows: [DictionaryRow]
        switch kind {
        case .hints:
            rows = state.dictionary.hints.sorted().map {
                DictionaryRow(wrong: $0, right: "", source: .manual, kind: .hints)
            }
        case .vocabulary:
            rows = state.dictionary.vocabulary.sorted().map {
                DictionaryRow(wrong: $0, right: "", source: .manual, kind: .vocabulary)
            }
        case .manual:
            rows = state.dictionary.replacements
                .map { wrong, right in
                    DictionaryRow(wrong: wrong, right: right, source: effectiveSource(wrong: wrong, right: right), kind: .manual)
                }
                .filter { $0.source != .autoLearned }
                .sorted { $0.wrong.localizedCaseInsensitiveCompare($1.wrong) == .orderedAscending }
        case .autoLearned:
            rows = state.dictionary.replacements
                .map { wrong, right in
                    DictionaryRow(wrong: wrong, right: right, source: effectiveSource(wrong: wrong, right: right), kind: .autoLearned)
                }
                .filter { $0.source == .autoLearned }
                .sorted { $0.wrong.localizedCaseInsensitiveCompare($1.wrong) == .orderedAscending }
        }

        if !query.isEmpty {
            rows = rows.filter {
                $0.wrong.lowercased().contains(query)
                    || $0.right.lowercased().contains(query)
                    || sourceTitle($0.source).lowercased().contains(query)
            }
        }

        dictionaryRows = rows
        updateDictionaryColumns(for: kind)
        dictionaryTable?.reloadData()
        updateDictionaryButtons()
    }

    private func updateDictionaryColumns(for kind: DictionaryViewKind) {
        guard let table = dictionaryTable else { return }
        guard let wrongColumn = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("wrong")),
              let rightColumn = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("right")),
              let sourceColumn = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("source")) else {
            return
        }

        let showsReplacementColumns = !(kind == .hints || kind == .vocabulary)
        let availableWidth = table.enclosingScrollView?.contentView.bounds.width ?? table.bounds.width
        let widths = DictionaryColumnLayout.widths(
            availableWidth: availableWidth,
            showsReplacementColumns: showsReplacementColumns
        )

        wrongColumn.title = showsReplacementColumns ? "Wrong" : "Term"
        rightColumn.isHidden = !showsReplacementColumns
        sourceColumn.isHidden = !showsReplacementColumns

        wrongColumn.width = widths.wrong
        rightColumn.width = widths.replacement
        sourceColumn.width = widths.source
    }

    private func updateDictionaryButtons() {
        let hasSelection = (dictionaryTable?.selectedRow ?? -1) >= 0
        editButton?.isEnabled = hasSelection
        deleteButton?.isEnabled = hasSelection
    }

    private func effectiveSource(wrong: String, right: String) -> ReplacementSource {
        guard let state = state else { return .imported }
        let metadata = state.dictionary.metadata(for: wrong)
        if metadata.source != .imported {
            return metadata.source
        }
        return loggedAutoCorrectionKeys.contains(logKey(wrong: wrong, right: right)) ? .autoLearned : .imported
    }

    private func sourceTitle(_ source: ReplacementSource) -> String {
        switch source {
        case .manual: return "Manual"
        case .autoLearned: return "Auto"
        case .imported: return "Imported"
        }
    }

    // MARK: - Dictionary Actions

    @objc private func dictionarySegmentChanged() {
        refreshDictionaryTable()
    }

    @objc private func dictionarySearchChanged() {
        refreshDictionaryTable()
    }

    @objc private func addDictionaryEntry() {
        switch selectedDictionaryKind() {
        case .hints:
            if let value = promptForSingleValue(title: "Add Hint", value: "") {
                state?.addDictionaryHint(value)
            }
        case .vocabulary:
            if let value = promptForSingleValue(title: "Add Vocabulary", value: "") {
                state?.addDictionaryVocabulary(value)
            }
        case .manual, .autoLearned:
            if let pair = promptForReplacement(title: "Add Correction", wrong: "", right: "") {
                state?.addDictionaryReplacement(wrong: pair.wrong, right: pair.right, source: selectedDictionaryKind() == .autoLearned ? .autoLearned : .manual)
            }
        }
        refreshDictionaryTable()
    }

    @objc private func editDictionaryEntry() {
        guard let table = dictionaryTable else { return }
        let rowIndex = table.selectedRow
        guard rowIndex >= 0, rowIndex < dictionaryRows.count else { return }
        let row = dictionaryRows[rowIndex]

        switch row.kind {
        case .hints:
            if let value = promptForSingleValue(title: "Edit Hint", value: row.wrong) {
                state?.updateDictionaryHint(oldValue: row.wrong, newValue: value)
            }
        case .vocabulary:
            if let value = promptForSingleValue(title: "Edit Vocabulary", value: row.wrong) {
                state?.updateDictionaryVocabulary(oldValue: row.wrong, newValue: value)
            }
        case .manual, .autoLearned:
            if let pair = promptForReplacement(title: "Edit Correction", wrong: row.wrong, right: row.right) {
                state?.updateDictionaryReplacement(oldWrong: row.wrong, wrong: pair.wrong, right: pair.right, source: row.source)
            }
        }
        refreshDictionaryTable()
    }

    @objc private func deleteDictionaryEntry() {
        guard let table = dictionaryTable else { return }
        let rowIndex = table.selectedRow
        guard rowIndex >= 0, rowIndex < dictionaryRows.count else { return }
        let row = dictionaryRows[rowIndex]

        switch row.kind {
        case .hints:
            state?.removeDictionaryHint(row.wrong)
        case .vocabulary:
            state?.removeDictionaryVocabulary(row.wrong)
        case .manual, .autoLearned:
            state?.removeDictionaryReplacement(row.wrong)
        }
        refreshDictionaryTable()
    }

    @objc private func reloadDictionary() {
        state?.reloadDictionary()
        refreshLoggedAutoCorrectionKeys()
        refreshDictionaryTable()
    }

    @objc private func openDictionaryFile() {
        NSWorkspace.shared.open(CustomDictionary.fileURL)
    }

    @objc private func showAutoLearnedCorrections() {
        selectedSectionIndex = MainWindowSection.dictionary.rawValue
        mainTabs?.selectTabViewItem(at: MainWindowSection.dictionary.rawValue)
        dictionarySegment?.selectedSegment = DictionaryViewKind.autoLearned.rawValue
        refreshDictionaryTable()
        updateNavigationSelection()
        updateContentHeader()
    }

    // MARK: - History & Recovery Actions

    @objc private func showHistory() {
        selectedSectionIndex = MainWindowSection.history.rawValue
        mainTabs?.selectTabViewItem(at: MainWindowSection.history.rawValue)
        refreshHistory()
        updateNavigationSelection()
        updateContentHeader()
    }

    @objc private func refreshHistoryAction() {
        refreshHistory()
        updateStatus()
    }

    @objc private func copyLastResult() {
        guard let text = lastHistoryText() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func pasteLastResult() {
        guard let text = lastHistoryText() else { return }
        if !PasteService.paste(text) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            overlayResult(text)
        }
    }

    private func overlayResult(_ text: String) {
        state?.overlay.showResult(text)
    }

    private func refreshHistory() {
        historyRows = TranscriptionLogger.recentHistory(limit: 80)
        historyTable?.reloadData()
    }

    private func lastHistoryText() -> String? {
        let selectedRow = historyTable?.selectedRow ?? -1
        if selectedRow >= 0, selectedRow < historyRows.count {
            let text = historyRows[selectedRow].preview
            return text.isEmpty ? nil : text
        }
        guard let text = historyRows.first?.preview, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Settings Actions

    @objc private func microphoneChanged() {
        guard let popup = micPopup else { return }
        let selected = popup.titleOfSelectedItem ?? "System Default"
        state?.setPreferredMicrophone(selected == "System Default" ? nil : selected)
        updateStatus()
    }

    @objc private func compressionChanged() {
        guard let popup = compressionPopup else { return }
        let options = compressionOptions()
        let index = max(0, min(popup.indexOfSelectedItem, options.count - 1))
        state?.setAudioCompressionBitrate(options[index].bitrate)
        updateStatus()
    }

    @objc private func checkForUpdates() {
        Updater.checkManually()
    }

    @objc private func openLogsFolder() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/typefish/logs")
        NSWorkspace.shared.open(logsDir)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshPopups() {
        guard let state = state else { return }

        if let micPopup = micPopup {
            let currentTitle = micPopup.titleOfSelectedItem
            micPopup.removeAllItems()
            micPopup.addItem(withTitle: "System Default")
            for device in microphoneDevices() {
                micPopup.addItem(withTitle: device.localizedName)
            }
            let preferred = state.config.preferredMicrophone ?? "System Default"
            micPopup.selectItem(withTitle: preferred)
            if micPopup.titleOfSelectedItem == nil {
                micPopup.selectItem(withTitle: currentTitle ?? "System Default")
            }
        }

        if let compressionPopup = compressionPopup {
            compressionPopup.removeAllItems()
            let options = compressionOptions()
            for option in options {
                compressionPopup.addItem(withTitle: option.title)
            }
            if let index = options.firstIndex(where: { $0.bitrate == state.config.audioCompressionBitrate }) {
                compressionPopup.selectItem(at: index)
            }
        }
    }

    private func microphoneDevices() -> [AVCaptureDevice] {
        if #available(macOS 14.0, *) {
            return AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            ).devices
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    private func compressionOptions() -> [(title: String, bitrate: Int)] {
        [
            ("Off (WAV)", 0),
            ("Aggressive (32kbps)", 32000),
            ("Fast (48kbps)", 48000),
            ("Balanced (64kbps)", 64000),
            ("Quality (96kbps)", 96000)
        ]
    }

    // MARK: - Prompts

    private func promptForSingleValue(title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = EditableTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        input.stringValue = value
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func promptForReplacement(title: String, wrong: String, right: String) -> (wrong: String, right: String)? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 64))
        let wrongLabel = NSTextField(labelWithString: "Wrong")
        wrongLabel.frame = NSRect(x: 0, y: 40, width: 60, height: 18)
        container.addSubview(wrongLabel)

        let wrongInput = EditableTextField(frame: NSRect(x: 68, y: 36, width: 292, height: 24))
        wrongInput.stringValue = wrong
        container.addSubview(wrongInput)

        let rightLabel = NSTextField(labelWithString: "Right")
        rightLabel.frame = NSRect(x: 0, y: 8, width: 60, height: 18)
        container.addSubview(rightLabel)

        let rightInput = EditableTextField(frame: NSRect(x: 68, y: 4, width: 292, height: 24))
        rightInput.stringValue = right
        container.addSubview(rightInput)

        alert.accessoryView = container
        alert.window.initialFirstResponder = wrongInput

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let w = wrongInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = rightInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty else { return nil }
        return (w, r)
    }

    // MARK: - Log Provenance

    private func refreshLoggedAutoCorrectionKeys() {
        loggedAutoCorrectionKeys.removeAll()
        let logFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/typefish/logs/auto-corrections.jsonl")
        guard let content = try? String(contentsOf: logFile, encoding: .utf8) else { return }

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let corrections = json["corrections"] as? [[String: Any]] else {
                continue
            }
            for correction in corrections {
                guard let wrong = correction["wrong"] as? String,
                      let right = correction["right"] as? String else { continue }
                loggedAutoCorrectionKeys.insert(logKey(wrong: wrong, right: right))
            }
        }
    }

    private func logKey(wrong: String, right: String) -> String {
        "\(wrong)\u{1F}\(right)"
    }

    // MARK: - Text Helpers

    private func setupRows() -> [(title: String, value: String, ok: Bool)] {
        let accessibility = AXIsProcessTrusted()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let microphone = micStatus == .authorized
        let apiKey = state?.groqAPIKey != nil
        let dictionaryLoaded = state?.dictionary != nil

        return [
            ("Accessibility", accessibility ? "Enabled" : "Open System Settings to allow hotkeys and paste", accessibility),
            ("Microphone", microphone ? "Enabled" : permissionTitle(for: micStatus), microphone),
            ("API Key", apiKey ? "Groq key loaded" : "Missing GROQ_API_KEY or ~/.config/typefish/groq_key", apiKey),
            ("Dictionary", dictionaryLoaded ? dictionarySummaryText() : "No dictionary loaded", dictionaryLoaded)
        ]
    }

    private func permissionTitle(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not requested yet"
        case .restricted: return "Restricted by system policy"
        case .denied: return "Denied in System Settings"
        case .authorized: return "Enabled"
        @unknown default: return "Unknown"
        }
    }

    private func setupSummaryText() -> String {
        let rows = setupRows()
        let ready = rows.filter { $0.ok }.count
        return "\(ready)/\(rows.count) setup checks ready"
    }

    private func lastResultSummaryText() -> String {
        guard let first = historyRows.first else { return "No saved transcription yet" }
        let preview = first.preview.replacingOccurrences(of: "\n", with: " ")
        if preview.count <= 88 { return preview }
        return String(preview.prefix(88)) + "..."
    }

    private func diagnosticsSummaryText() -> String {
        let stats = MetricsLogger.recentStats(hours: 24)
        if stats.total == 0 { return "No recent pipeline metrics" }
        return "\(stats.success)/\(stats.total) successful in 24h"
    }

    private func latencySummaryText() -> String {
        let stats = MetricsLogger.recentStats(hours: 24)
        var parts: [String] = []
        if stats.avgWhisperMs > 0 { parts.append("Whisper \(stats.avgWhisperMs)ms") }
        if stats.avgPolishMs > 0 { parts.append("Polish \(stats.avgPolishMs)ms") }
        if stats.avgTotalMs > 0 { parts.append("Total \(stats.avgTotalMs)ms") }
        return parts.isEmpty ? "No latency samples yet" : parts.joined(separator: " · ")
    }

    private func displayTimestamp(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        let out = DateFormatter()
        out.dateStyle = .none
        out.timeStyle = .short
        return out.string(from: date)
    }

    private func modeColor(_ mode: String) -> NSColor {
        switch mode {
        case "command": return .systemPurple
        case "translate": return .systemGreen
        default: return .controlAccentColor
        }
    }

    private func dictionarySummaryText() -> String {
        guard let dict = state?.dictionary else { return "No dictionary loaded" }
        return "\(dict.hints.count) hints · \(dict.replacements.count) corrections · \(dict.vocabulary.count) vocabulary"
    }

    private func learningSummaryText() -> String {
        guard let state = state else { return "No learning data loaded" }
        let autoCount = state.dictionary.replacements.filter { wrong, right in
            effectiveSource(wrong: wrong, right: right) == .autoLearned
        }.count
        return "\(autoCount) auto-learned corrections"
    }

    private func healthStatsText() -> String {
        let stats = MetricsLogger.recentStats(hours: 24)
        if stats.total == 0 { return "No transcriptions yet" }
        let rate = stats.total > 0 ? Int(Double(stats.success) / Double(stats.total) * 100) : 0
        let styleProgress = StyleLearner.shared.progressPercent
        var text = "\(stats.success)/\(stats.total) (\(rate)%) · style \(styleProgress)%"
        if !stats.errors.isEmpty {
            let errStr = stats.errors.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            text += " · \(errStr)"
        }
        if stats.avgWhisperMs > 0 {
            text += " · \(stats.avgWhisperMs)ms"
        }
        return text
    }

    private func surface(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.58).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
        return view
    }

    private func styleActionButton(
        _ button: NSButton,
        symbol: String,
        prominent: Bool = false,
        destructive: Bool = false
    ) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        if prominent {
            button.contentTintColor = .controlAccentColor
        } else if destructive {
            button.contentTintColor = .systemRed
        } else {
            button.contentTintColor = .secondaryLabelColor
        }
    }

    private func mutedLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func addSectionTitle(_ text: String, to view: NSView, x: CGFloat, y: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: x, y: y, width: 240, height: 18)
        view.addSubview(label)
    }

    @discardableResult
    private func addInfoRow(_ title: String, _ value: String, to view: NSView, x: CGFloat, y: CGFloat) -> NSTextField {
        let titleLabel = mutedLabel(title)
        titleLabel.frame = NSRect(x: x, y: y + 24, width: view.bounds.width - x - 20, height: 18)
        titleLabel.autoresizingMask = [.width]
        view.addSubview(titleLabel)

        let valueField = valueLabel(value, size: 13, weight: .regular)
        valueField.textColor = .labelColor
        valueField.frame = NSRect(x: x, y: y, width: view.bounds.width - x - 20, height: 20)
        valueField.autoresizingMask = [.width]
        view.addSubview(valueField)
        return valueField
    }

    private func addDivider(to view: NSView, x: CGFloat, y: CGFloat) {
        let line = NSBox(frame: NSRect(x: x, y: y, width: view.bounds.width - x - 20, height: 1))
        line.boxType = .separator
        line.autoresizingMask = [.width]
        view.addSubview(line)
    }

    private func valueLabel(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func addKeyValue(_ key: String, _ value: String, to view: NSView, x: CGFloat, y: CGFloat) {
        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        keyLabel.frame = NSRect(x: x, y: y, width: 106, height: 20)
        view.addSubview(keyLabel)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont.systemFont(ofSize: 13)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.frame = NSRect(x: x + 118, y: y, width: view.bounds.width - x - 138, height: 20)
        valueLabel.autoresizingMask = [.width]
        view.addSubview(valueLabel)
    }

    private func addStatusRow(_ title: String, _ value: String, ok: Bool, to view: NSView, x: CGFloat, y: CGFloat) {
        let dot = NSView(frame: NSRect(x: x, y: y + 5, width: 9, height: 9))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        dot.layer?.backgroundColor = (ok ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        view.addSubview(dot)

        let titleLabel = valueLabel(title, size: 13, weight: .semibold)
        titleLabel.frame = NSRect(x: x + 18, y: y + 14, width: view.bounds.width - x - 38, height: 20)
        titleLabel.autoresizingMask = [.width]
        view.addSubview(titleLabel)

        let detailLabel = valueLabel(value, size: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x: x + 18, y: y - 4, width: view.bounds.width - x - 38, height: 18)
        detailLabel.autoresizingMask = [.width]
        view.addSubview(detailLabel)
    }
}
