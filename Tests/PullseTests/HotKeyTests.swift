import Foundation
import Testing
@testable import PullseCore

@Test func hotKeysShowInApplesModifierOrder() {
    let hotKey = HotKey(keyCode: 35, key: "P", modifiers: [.command, .shift, .control, .option])
    #expect(hotKey.display == "⌃⌥⇧⌘P")
    #expect(HotKey(keyCode: 96, key: "F5", modifiers: [.option]).display == "⌥F5")
}

@Test func aGlobalShortcutNeedsCommandOptionOrControl() {
    #expect(HotKey(keyCode: 35, key: "P", modifiers: [.control, .option]).isValid)
    #expect(HotKey(keyCode: 96, key: "F5", modifiers: [.command]).isValid)
    #expect(!HotKey(keyCode: 35, key: "P", modifiers: [.shift]).isValid)
    #expect(!HotKey(keyCode: 35, key: "P", modifiers: []).isValid)
}

@Test func theMenuShortcutIsSavedAndReadBack() throws {
    var settings = PullseSettings()
    #expect(settings.openMenuShortcut == nil)
    settings.openMenuShortcut = HotKey(keyCode: 35, key: "P", modifiers: [.control, .option])
    let saved = try JSONDecoder().decode(PullseSettings.self, from: JSONEncoder().encode(settings))
    #expect(saved.openMenuShortcut == settings.openMenuShortcut)

    let handWritten = #"{ "openMenuShortcut": { "keyCode": 35, "key": "P", "modifiers": ["control", "option"] } }"#
    let decoded = try JSONDecoder().decode(PullseSettings.self, from: Data(handWritten.utf8))
    #expect(decoded.openMenuShortcut?.display == "⌃⌥P")
}

@Test func aMalformedShortcutIsIgnoredNotTheWholeFile() throws {
    let text = #"{ "org": "acme", "openMenuShortcut": { "keyCode": "P", "modifiers": ["hyper"] } }"#
    let decoded = try JSONDecoder().decode(PullseSettings.self, from: Data(text.utf8))
    #expect(decoded.openMenuShortcut == nil)
    #expect(decoded.org == "acme")
}

@Test func theKeyboardMovesThroughHeadingsAndRowsAndStopsAtTheEnds() {
    let ids = ["group:a", "event:1", "event:2", "group:b"]
    #expect(ActivityGroups.next(after: nil, in: ids, by: 1) == "group:a")
    #expect(ActivityGroups.next(after: nil, in: ids, by: -1) == "group:b")
    #expect(ActivityGroups.next(after: "event:1", in: ids, by: 1) == "event:2")
    #expect(ActivityGroups.next(after: "group:b", in: ids, by: 1) == "group:b")
    #expect(ActivityGroups.next(after: "group:a", in: ids, by: -1) == "group:a")
    #expect(ActivityGroups.next(after: "gone", in: ids, by: 1) == "group:a")
    #expect(ActivityGroups.next(after: nil, in: [], by: 1) == nil)
}

@Test func rowIDsListEachHeadingThenItsEvents() {
    let event = PREvent(
        id: "c1", kind: .comment, repo: "acme/api", number: 1, prTitle: "A change",
        prURL: "https://github.com/acme/api/pull/1", author: "alice", headline: "alice commented",
        snippet: "", url: "https://github.com/c/c1", date: now
    )
    let quiet = OpenPullRequest(
        repo: "acme/web", number: 2, title: "Other", url: "https://github.com/acme/web/pull/2", createdAt: t0
    )
    let groups = ActivityGroups.build(history: [event], open: [quiet])
    #expect(ActivityGroups.rowIDs(groups) == [
        "group:https://github.com/acme/api/pull/1", "event:c1", "group:https://github.com/acme/web/pull/2",
    ])
}
