import AppKit
import AVFoundation

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
    private var learningSummaryLabel: NSTextField?

    private var mainTabs: NSTabView?
    private var dictionarySegment: NSSegmentedControl?
    private var dictionarySearch: NSSearchField?
    private var dictionaryTable: NSTableView?
    private var dictionaryRows: [DictionaryRow] = []
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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "TypeFish"
        w.center()
        w.minSize = NSSize(width: 680, height: 480)
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.backgroundColor = .windowBackgroundColor

        let root = NSView(frame: w.contentView!.bounds)
        root.autoresizingMask = [.width, .height]

        let title = NSTextField(labelWithString: "TypeFish")
        title.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        title.frame = NSRect(x: 24, y: root.bounds.height - 54, width: 220, height: 30)
        title.autoresizingMask = [.minYMargin]
        root.addSubview(title)

        let version = NSTextField(labelWithString: "v\(Updater.currentVersion)")
        version.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        version.textColor = .secondaryLabelColor
        version.frame = NSRect(x: 118, y: root.bounds.height - 47, width: 120, height: 18)
        version.autoresizingMask = [.minYMargin]
        root.addSubview(version)

        let tabs = NSTabView(frame: NSRect(x: 18, y: 18, width: root.bounds.width - 36, height: root.bounds.height - 82))
        tabs.autoresizingMask = [.width, .height]
        tabs.tabViewType = .topTabsBezelBorder
        tabs.addTabViewItem(tabItem(label: "Dashboard", view: dashboardView(frame: tabs.bounds)))
        tabs.addTabViewItem(tabItem(label: "Dictionary", view: dictionaryView(frame: tabs.bounds)))
        tabs.addTabViewItem(tabItem(label: "Settings", view: settingsView(frame: tabs.bounds)))
        tabs.addTabViewItem(tabItem(label: "Learning", view: learningView(frame: tabs.bounds)))
        root.addSubview(tabs)
        self.mainTabs = tabs

        w.contentView = root
        self.window = w

        refreshLoggedAutoCorrectionKeys()
        refreshDictionaryTable()
        refreshPopups()
        updateStatus()

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateStatus() {
        guard let state = state else { return }

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
        learningSummaryLabel?.stringValue = learningSummaryText()

        if window?.isVisible == true {
            refreshLoggedAutoCorrectionKeys()
            refreshDictionaryTable()
            refreshPopups()
        }
    }

    // MARK: - Tabs

    private func tabItem(label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    private func dashboardView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.autoresizingMask = [.width, .height]

        addSectionTitle("Status", to: view, x: 24, y: 388)
        let status = valueLabel("Ready", size: 26, weight: .semibold)
        status.textColor = .systemGreen
        status.frame = NSRect(x: 24, y: 350, width: 300, height: 34)
        view.addSubview(status)
        self.statusLabel = status

        addSectionTitle("Shortcuts", to: view, x: 24, y: 302)
        let shortcuts = [
            ("⌥ Space", "Toggle Recording"),
            ("⌃⌥ Space", "Translate to English"),
            ("⌃⌥⌘ Space", "AI Command"),
            ("Esc", "Cancel Recording")
        ]
        for (index, item) in shortcuts.enumerated() {
            addKeyValue(item.0, item.1, to: view, x: 24, y: CGFloat(272 - index * 28))
        }

        addSectionTitle("Dictionary", to: view, x: 390, y: 388)
        let dict = valueLabel(dictionarySummaryText(), size: 14, weight: .regular)
        dict.frame = NSRect(x: 390, y: 358, width: 300, height: 22)
        view.addSubview(dict)
        self.dictSummaryLabel = dict

        addSectionTitle("Microphone", to: view, x: 390, y: 316)
        let mic = valueLabel("System Default", size: 14, weight: .regular)
        mic.frame = NSRect(x: 390, y: 286, width: 300, height: 22)
        view.addSubview(mic)
        self.micSummaryLabel = mic

        addSectionTitle("Compression", to: view, x: 390, y: 244)
        let compression = valueLabel("", size: 14, weight: .regular)
        compression.frame = NSRect(x: 390, y: 214, width: 300, height: 22)
        view.addSubview(compression)
        self.compressionSummaryLabel = compression

        addSectionTitle("Health", to: view, x: 390, y: 172)
        let health = valueLabel(healthStatsText(), size: 12, weight: .regular)
        health.textColor = .secondaryLabelColor
        health.frame = NSRect(x: 390, y: 142, width: 320, height: 22)
        view.addSubview(health)
        self.healthLabel = health

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
        segment.frame = NSRect(x: 22, y: frame.height - 58, width: 360, height: 28)
        segment.autoresizingMask = [.minYMargin]
        view.addSubview(segment)
        self.dictionarySegment = segment

        let search = NSSearchField(frame: NSRect(x: frame.width - 250, y: frame.height - 58, width: 220, height: 28))
        search.placeholderString = "Search"
        search.target = self
        search.action = #selector(dictionarySearchChanged)
        search.autoresizingMask = [.minXMargin, .minYMargin]
        view.addSubview(search)
        self.dictionarySearch = search

        let scroll = NSScrollView(frame: NSRect(x: 22, y: 72, width: frame.width - 44, height: frame.height - 144))
        scroll.autoresizingMask = [.width, .height]
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true

        let table = NSTableView(frame: scroll.bounds)
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 26
        table.delegate = self
        table.dataSource = self
        table.allowsMultipleSelection = false

        let wrongColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("wrong"))
        wrongColumn.title = "Term"
        wrongColumn.width = 260
        table.addTableColumn(wrongColumn)

        let rightColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("right"))
        rightColumn.title = "Replacement"
        rightColumn.width = 260
        table.addTableColumn(rightColumn)

        let sourceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sourceColumn.title = "Source"
        sourceColumn.width = 120
        table.addTableColumn(sourceColumn)

        scroll.documentView = table
        view.addSubview(scroll)
        self.dictionaryTable = table

        let add = NSButton(title: "Add", target: self, action: #selector(addDictionaryEntry))
        add.frame = NSRect(x: 22, y: 28, width: 76, height: 30)
        view.addSubview(add)
        self.addButton = add

        let edit = NSButton(title: "Edit", target: self, action: #selector(editDictionaryEntry))
        edit.frame = NSRect(x: 106, y: 28, width: 76, height: 30)
        view.addSubview(edit)
        self.editButton = edit

        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteDictionaryEntry))
        delete.frame = NSRect(x: 190, y: 28, width: 82, height: 30)
        view.addSubview(delete)
        self.deleteButton = delete

        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadDictionary))
        reload.frame = NSRect(x: frame.width - 198, y: 28, width: 82, height: 30)
        reload.autoresizingMask = [.minXMargin]
        view.addSubview(reload)

        let open = NSButton(title: "Open File", target: self, action: #selector(openDictionaryFile))
        open.frame = NSRect(x: frame.width - 108, y: 28, width: 86, height: 30)
        open.autoresizingMask = [.minXMargin]
        view.addSubview(open)

        return view
    }

    private func settingsView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.autoresizingMask = [.width, .height]

        addSectionTitle("Microphone", to: view, x: 24, y: 390)
        let mic = NSPopUpButton(frame: NSRect(x: 24, y: 352, width: 360, height: 30))
        mic.target = self
        mic.action = #selector(microphoneChanged)
        view.addSubview(mic)
        self.micPopup = mic

        addSectionTitle("Audio Compression", to: view, x: 24, y: 296)
        let compression = NSPopUpButton(frame: NSRect(x: 24, y: 258, width: 360, height: 30))
        compression.target = self
        compression.action = #selector(compressionChanged)
        view.addSubview(compression)
        self.compressionPopup = compression

        addSectionTitle("Dictionary", to: view, x: 430, y: 390)
        let reload = NSButton(title: "Reload Dictionary", target: self, action: #selector(reloadDictionary))
        reload.frame = NSRect(x: 430, y: 352, width: 170, height: 30)
        view.addSubview(reload)

        let open = NSButton(title: "Open Dictionary File", target: self, action: #selector(openDictionaryFile))
        open.frame = NSRect(x: 430, y: 314, width: 170, height: 30)
        view.addSubview(open)

        addSectionTitle("Updates", to: view, x: 430, y: 246)
        let update = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdates))
        update.frame = NSRect(x: 430, y: 208, width: 170, height: 30)
        view.addSubview(update)

        let quit = NSButton(title: "Quit TypeFish", target: self, action: #selector(quit))
        quit.frame = NSRect(x: 430, y: 96, width: 170, height: 30)
        view.addSubview(quit)

        return view
    }

    private func learningView(frame: NSRect) -> NSView {
        let view = NSView(frame: frame)
        view.autoresizingMask = [.width, .height]

        addSectionTitle("Auto-Learned Corrections", to: view, x: 24, y: frame.height - 60)
        let summary = valueLabel(learningSummaryText(), size: 13, weight: .regular)
        summary.textColor = .secondaryLabelColor
        summary.frame = NSRect(x: 24, y: frame.height - 90, width: frame.width - 48, height: 22)
        summary.autoresizingMask = [.width, .minYMargin]
        view.addSubview(summary)
        self.learningSummaryLabel = summary

        let jump = NSButton(title: "Open Auto Corrections", target: self, action: #selector(showAutoLearnedCorrections))
        jump.frame = NSRect(x: 24, y: frame.height - 132, width: 170, height: 30)
        jump.autoresizingMask = [.minYMargin]
        view.addSubview(jump)

        let log = NSButton(title: "Open Logs Folder", target: self, action: #selector(openLogsFolder))
        log.frame = NSRect(x: 204, y: frame.height - 132, width: 140, height: 30)
        log.autoresizingMask = [.minYMargin]
        view.addSubview(log)

        let note = NSTextField(wrappingLabelWithString: "Corrections marked Auto come from new provenance metadata or matching entries in auto-corrections.jsonl.")
        note.font = NSFont.systemFont(ofSize: 12)
        note.textColor = .tertiaryLabelColor
        note.frame = NSRect(x: 24, y: frame.height - 182, width: frame.width - 48, height: 42)
        note.autoresizingMask = [.width, .minYMargin]
        view.addSubview(note)

        return view
    }

    // MARK: - Dictionary Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        dictionaryRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < dictionaryRows.count, let column = tableColumn else { return nil }
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

        let item = dictionaryRows[row]
        switch identifier.rawValue {
        case "wrong":
            textField.stringValue = item.wrong
        case "right":
            textField.stringValue = item.right
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
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("wrong"))?.title = (kind == .hints || kind == .vocabulary) ? "Term" : "Wrong"
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("right"))?.isHidden = (kind == .hints || kind == .vocabulary)
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("source"))?.isHidden = (kind == .hints || kind == .vocabulary)
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
        mainTabs?.selectTabViewItem(at: 1)
        dictionarySegment?.selectedSegment = DictionaryViewKind.autoLearned.rawValue
        refreshDictionaryTable()
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

    private func addSectionTitle(_ text: String, to view: NSView, x: CGFloat, y: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: x, y: y, width: 240, height: 18)
        view.addSubview(label)
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
        keyLabel.frame = NSRect(x: x, y: y, width: 110, height: 20)
        view.addSubview(keyLabel)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont.systemFont(ofSize: 13)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.frame = NSRect(x: x + 122, y: y, width: 190, height: 20)
        view.addSubview(valueLabel)
    }
}
