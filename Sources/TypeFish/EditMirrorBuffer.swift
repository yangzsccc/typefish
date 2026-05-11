import AppKit

enum EditCaptureMode: String, Equatable {
    case accessibility
    case clipboardSnapshot
    case eventMirror
    case terminalShellIntegration
    case unsupported

    var usesEventMirror: Bool {
        self == .eventMirror || self == .terminalShellIntegration
    }
}

enum EditMirrorEvent {
    case text(String)
    case leftArrow
    case rightArrow
    case deleteBackward
    case deleteForward
    case commandKey(keyCode: UInt16, characters: String)
    case ignored
    case unsupported(String)

    static func fromKeyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) -> EditMirrorEvent {
        if modifiers.contains(.command) {
            return .commandKey(keyCode: keyCode, characters: characters)
        }

        if modifiers.contains(.control) {
            return .unsupported("control-key")
        }

        switch keyCode {
        case 36, 76: // Return / keypad enter
            return .ignored
        case 48: // Tab
            return .text("\t")
        case 51:
            return .deleteBackward
        case 117:
            return .deleteForward
        case 123:
            return .leftArrow
        case 124:
            return .rightArrow
        case 125, 126:
            return .unsupported("vertical-arrow")
        case 53: // Escape
            return .unsupported("escape")
        default:
            if !characters.isEmpty {
                return .text(characters)
            }
            return .unsupported("unhandled-key-\(keyCode)")
        }
    }
}

struct EditMirrorBuffer {
    private let originalCharacters: [Character]
    private var characters: [Character]
    private var cursor: Int
    private var selection: Range<Int>?

    private(set) var isReliable = true

    init(originalText: String) {
        let chars = Array(originalText)
        self.originalCharacters = chars
        self.characters = chars
        self.cursor = chars.count
        self.selection = nil
    }

    var currentText: String {
        String(characters)
    }

    var hasChanged: Bool {
        characters != originalCharacters
    }

    var authoritativeTextForAnalysis: String? {
        guard isReliable, hasChanged else { return nil }
        let text = currentText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    mutating func apply(
        _ event: EditMirrorEvent,
        pasteboardStringProvider: () -> String? = {
            NSPasteboard.general.string(forType: .string)
        }
    ) {
        guard isReliable else { return }

        switch event {
        case .text(let text):
            insert(text)
        case .leftArrow:
            moveLeft()
        case .rightArrow:
            moveRight()
        case .deleteBackward:
            deleteBackward()
        case .deleteForward:
            deleteForward()
        case .commandKey(let keyCode, _):
            applyCommandKey(keyCode: keyCode, pasteboardStringProvider: pasteboardStringProvider)
        case .ignored:
            break
        case .unsupported:
            isReliable = false
            selection = nil
        }
    }

    private mutating func applyCommandKey(
        keyCode: UInt16,
        pasteboardStringProvider: () -> String?
    ) {
        switch keyCode {
        case 0: // A
            selection = 0..<characters.count
            cursor = characters.count
        case 9: // V
            guard let pasted = pasteboardStringProvider() else {
                isReliable = false
                return
            }
            insert(pasted)
        case 123: // Left
            selection = nil
            cursor = 0
        case 124: // Right
            selection = nil
            cursor = characters.count
        default:
            isReliable = false
            selection = nil
        }
    }

    private mutating func insert(_ text: String) {
        guard !text.isEmpty else { return }
        replaceSelectionIfNeeded()
        let inserted = Array(text)
        characters.insert(contentsOf: inserted, at: cursor)
        cursor += inserted.count
    }

    private mutating func moveLeft() {
        if let selection {
            cursor = selection.lowerBound
            self.selection = nil
            return
        }
        cursor = max(0, cursor - 1)
    }

    private mutating func moveRight() {
        if let selection {
            cursor = selection.upperBound
            self.selection = nil
            return
        }
        cursor = min(characters.count, cursor + 1)
    }

    private mutating func deleteBackward() {
        if replaceSelectionIfNeeded() { return }
        guard cursor > 0 else { return }
        characters.remove(at: cursor - 1)
        cursor -= 1
    }

    private mutating func deleteForward() {
        if replaceSelectionIfNeeded() { return }
        guard cursor < characters.count else { return }
        characters.remove(at: cursor)
    }

    @discardableResult
    private mutating func replaceSelectionIfNeeded() -> Bool {
        guard let range = selection else { return false }
        characters.removeSubrange(range)
        cursor = range.lowerBound
        selection = nil
        return true
    }
}

