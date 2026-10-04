import Foundation

/// A keyboard shortcut, as recorded in Settings and kept in the settings file:
/// `{"keyCode": 35, "key": "P", "modifiers": ["control", "option"]}`.
public struct HotKey: Codable, Equatable, Sendable {
    public enum Modifier: String, Codable, Sendable, CaseIterable {
        // Apple's display order: ⌃⌥⇧⌘.
        case control, option, shift, command

        var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }
    }

    /// The virtual key code, which is what the system registers.
    public var keyCode: Int
    /// The key as shown: "P", "5", "F5", "Space".
    public var key: String
    public var modifiers: Set<Modifier>

    public init(keyCode: Int, key: String, modifiers: Set<Modifier>) {
        self.keyCode = keyCode
        self.key = key
        self.modifiers = modifiers
    }

    /// "⌃⌥P"
    public var display: String {
        Modifier.allCases.filter(modifiers.contains).map(\.symbol).joined() + key
    }

    /// A global shortcut needs ⌘, ⌥ or ⌃; with only ⇧ (or nothing) it would swallow
    /// ordinary typing in every app.
    public var isValid: Bool {
        !modifiers.isDisjoint(with: [.command, .option, .control]) && !key.isEmpty
    }
}

extension ActivityGroups {
    /// Row ids in the menu's order, for moving through it with the keyboard: each
    /// group's heading, then its events.
    public static func rowIDs(_ groups: [Group]) -> [String] {
        groups.flatMap { [headingID($0)] + $0.events.map(eventID) }
    }

    public static func headingID(_ group: Group) -> String { "group:" + group.prURL }
    public static func eventID(_ event: PREvent) -> String { "event:" + event.id }

    /// The row `offset` steps from `current`, stopping at either end. With nothing
    /// selected, down starts at the first row and up at the last.
    public static func next(after current: String?, in ids: [String], by offset: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return offset >= 0 ? ids.first : ids.last
        }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }
}
