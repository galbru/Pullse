import Foundation
import Testing
@testable import PullseCore

@Test func firstRunBaselinesSilently() throws {
    let snap = try snapshot(mine: [pr(comments: [comment("c1")], checks: [checkRun("k1", name: "test", conclusion: "FAILURE")])])
    let (events, state) = EventDetector.detect(snap, state: SeenState(), settings: DetectorSettings(), now: now)
    #expect(events.isEmpty)
    #expect(state.lastPollAt == now)
    #expect(state.seen["c1"] != nil)
    // …and the same items are not reported on the next poll either.
    #expect(EventDetector.detect(snap, state: state, settings: DetectorSettings(), now: now).events.isEmpty)
}

@Test func newCommentIsReportedOnce() throws {
    let snap = try snapshot(mine: [pr(comments: [comment("c1")], threads: [[comment("rc1", body: "nit")]])])
    let (events, state) = EventDetector.detect(snap, state: polled, settings: DetectorSettings(), now: now)
    #expect(events.map(\.id).sorted() == ["c1", "rc1"])
    #expect(events.first?.headline == "reviewer commented")
    #expect(EventDetector.detect(snap, state: state, settings: DetectorSettings(), now: now).events.isEmpty)
}

@Test func draftedReviewCommentsCountFromWhenTheReviewWasSubmitted() throws {
    // Written as drafts an hour ago, published just now when the review was submitted.
    let drafted = lastPoll.addingTimeInterval(-3_600)
    let snap = try snapshot(mine: [pr(reviews: [review("r1", state: "COMMENTED", comments: [
        comment("rc1", at: drafted, publishedAt: now),
        comment("rc2", at: drafted, publishedAt: now),
    ])])])
    let events = detect(snap)
    #expect(events.map(\.id).sorted() == ["rc1", "rc2"])
    #expect(events.allSatisfy { $0.date == now })
}

@Test func itemsBeforeThePreviousPollAreIgnored() throws {
    // e.g. a PR that just appeared in the search, carrying days of history.
    let old = comment("c1", at: lastPoll.addingTimeInterval(-3_600))
    #expect(detect(try snapshot(mine: [pr(comments: [old])])).isEmpty)
}

@Test func ownCommentsAndBotsAreFiltered() throws {
    let snap = try snapshot(mine: [pr(comments: [
        comment("mine", by: actor("Me")),
        comment("bot1", by: actor("github-actions", bot: true)),
        comment("bot2", by: actor("renovate[bot]")),
    ])])
    #expect(detect(snap).isEmpty)

    var settings = DetectorSettings()
    settings.includeBots = true
    #expect(detect(snap, settings: settings).map(\.id).sorted() == ["bot1", "bot2"])
}

@Test func disabledTypesAndMutedReposAreSilentAndNotReplayed() throws {
    let snap = try snapshot(mine: [pr(comments: [comment("c1")])])
    var off = DetectorSettings()
    off.comments = false
    let (events, state) = EventDetector.detect(snap, state: polled, settings: off, now: now)
    #expect(events.isEmpty)
    // Turning the type back on doesn't replay what was skipped.
    #expect(EventDetector.detect(snap, state: state, settings: DetectorSettings(), now: now).events.isEmpty)

    var muted = DetectorSettings()
    muted.mutedRepos = ["api"]
    #expect(detect(snap, settings: muted).isEmpty)
    muted.mutedRepos = ["acme/api"]
    #expect(detect(snap, settings: muted).isEmpty)
}

@Test func ignoredDraftsAreSilentAndNotReplayedWhenMarkedReady() throws {
    let draft = try snapshot(mine: [pr(
        comments: [comment("c1")],
        checks: [checkRun("k1", name: "test", conclusion: "FAILURE")], isDraft: true
    )])
    var ignore = DetectorSettings()
    ignore.ignoreDrafts = true
    let (events, state) = EventDetector.detect(draft, state: polled, settings: ignore, now: now)
    #expect(events.isEmpty)
    #expect(state.seen["c1"] != nil)
    // Marked ready: what happened while it was a draft stays skipped.
    let ready = try snapshot(mine: [pr(
        comments: [comment("c1")], checks: [checkRun("k1", name: "test", conclusion: "FAILURE")]
    )])
    #expect(EventDetector.detect(ready, state: state, settings: ignore, now: now).events.isEmpty)
    // Off, a draft notifies like any other pull request.
    #expect(detect(draft).count == 2)
}

@Test func reviews() throws {
    let snap = try snapshot(mine: [pr(reviews: [
        review("r1", state: "APPROVED"),
        review("r2", state: "CHANGES_REQUESTED", body: "please add tests"),
        review("r3", state: "COMMENTED"),  // just the envelope of inline comments
        review("r4", state: "COMMENTED", body: "<!-- bot marker -->"),
        review("r5", state: "COMMENTED", body: "overall fine"),
        review("r6", state: "PENDING", at: nil),
    ])])
    let events = detect(snap)
    #expect(Set(events.map(\.id)) == ["r1", "r2", "r5"])
    let changes = try #require(events.first { $0.id == "r2" })
    #expect(changes.headline == "reviewer requested changes")
    #expect(changes.isNegative)
    #expect(changes.snippet == "please add tests")
}

@Test func ciFailuresAreGroupedPerPullRequest() throws {
    let snap = try snapshot(mine: [pr(checks: [
        checkRun("k1", name: "lint", conclusion: "FAILURE"),
        checkRun("k2", name: "test", conclusion: "FAILURE"),
        checkRun("k3", name: "test", conclusion: "TIMED_OUT"),  // matrix shard
        checkRun("k4", name: "build", conclusion: "FAILURE"),
        checkRun("k5", name: "deploy", conclusion: "SUCCESS"),
        checkRun("k6", name: "e2e", conclusion: nil),
    ])])
    let (events, state) = EventDetector.detect(snap, state: polled, settings: DetectorSettings(), now: now)
    #expect(events.count == 1)
    #expect(events[0].headline == "CI failed: lint, test +1")
    #expect(events[0].url == "https://github.com/acme/api/pull/1/checks")
    #expect(EventDetector.detect(snap, state: state, settings: DetectorSettings(), now: now).events.isEmpty)

    var all = DetectorSettings()
    all.ciMode = .all
    let allEvents = detect(snap, settings: all)
    #expect(allEvents.map(\.headline).sorted() == ["CI failed: lint, test +1", "CI finished: deploy"])
}

@Test func ciRerunFailureIsReportedAgain() throws {
    let first = try snapshot(mine: [pr(checks: [checkRun("k1", name: "test", conclusion: "FAILURE")])])
    let (_, state) = EventDetector.detect(first, state: polled, settings: DetectorSettings(), now: now)
    let later = now.addingTimeInterval(120)
    let rerun = try snapshot(mine: [pr(checks: [checkRun("k2", name: "test", conclusion: "FAILURE", at: later)])])
    let events = EventDetector.detect(rerun, state: state, settings: DetectorSettings(), now: later).events
    #expect(events.count == 1)
    #expect(events[0].url == "https://github.com/checks/k2")
}

@Test func statusContextFailingAgainOnTheSameCommitIsReported() throws {
    // A legacy commit status keeps its id: failed, then passed, now failed again.
    func status(_ state: String, at date: Date) -> [String: Any] {
        ["__typename": "StatusContext", "id": "sc1", "context": "ci/jenkins", "state": state,
         "targetUrl": "https://ci.example/1", "createdAt": stamp(date)]
    }
    let (first, afterFirst) = EventDetector.detect(
        try snapshot(mine: [pr(checks: [status("FAILURE", at: now)])]),
        state: polled, settings: DetectorSettings(), now: now
    )
    #expect(first.count == 1)
    let passAt = now.addingTimeInterval(120)
    let (_, afterPass) = EventDetector.detect(
        try snapshot(mine: [pr(checks: [status("SUCCESS", at: passAt)])]),
        state: afterFirst, settings: DetectorSettings(), now: passAt
    )
    let failAt = passAt.addingTimeInterval(120)
    let again = EventDetector.detect(
        try snapshot(mine: [pr(checks: [status("FAILURE", at: failAt)])]),
        state: afterPass, settings: DetectorSettings(), now: failAt
    ).events
    #expect(again.map(\.headline) == ["CI failed: ci/jenkins"])
}

@Test func mentionsNeedTheHandleInTheBody() throws {
    let other = pr(
        repo: "acme/web", number: 9, body: "cc @me for review", author: actor("alice"),
        comments: [
            comment("m1", by: actor("bob"), body: "@ME what do you think?"),
            comment("m2", by: actor("bob"), body: "ping @meredith"),
            comment("m3", by: actor("bob"), body: "mail me@me.com"),
            comment("m4", by: actor("bob"), body: "no mention here"),
        ],
        threads: [[comment("m5", by: actor("carol"), body: "@me, see line 3")]]
    )
    // The PR body is a day old, so only the new comments count.
    let events = detect(try snapshot(mentioned: [other]))
    #expect(Set(events.map(\.id)) == ["mention:m1", "mention:m5"])
    #expect(events.allSatisfy { $0.kind == .mention })
    #expect(events.first { $0.id == "mention:m1" }?.headline == "bob mentioned you")
}

@Test func mentionHandleMatching() {
    #expect(EventDetector.mentions("hey @me", handle: "@me"))
    #expect(EventDetector.mentions("(@me)", handle: "@me"))
    #expect(!EventDetector.mentions("@me-bot", handle: "@me"))
    #expect(!EventDetector.mentions("x@me.io", handle: "@me"))
    #expect(!EventDetector.mentions(nil, handle: "@me"))
}

@Test func seenEntriesArePruned() throws {
    let state = SeenState(lastPollAt: lastPoll, seen: [
        "ancient": now.addingTimeInterval(-3 * 86_400), "recent": now.addingTimeInterval(-60),
    ])
    let next = EventDetector.detect(try snapshot(), state: state, settings: DetectorSettings(), now: now).state
    #expect(next.seen.keys.sorted() == ["recent"])
}

@Test func cleaning() {
    #expect(TextCleaner.clean("<!-- hidden -->Hello <b>there</b>\n\n  friend") == "Hello there friend")
    #expect(TextCleaner.clean(String(repeating: "a", count: 300), limit: 10) == "aaaaaaaaa…")
}

@Test func historyDedupsAndCaps() {
    var state = PersistedState()
    let event = { (id: String, date: Date) in
        PREvent(id: id, kind: .comment, repo: "o/r", number: 1, prTitle: "t", prURL: "u",
                author: nil, headline: "h", snippet: "", url: "u", date: date)
    }
    state.record([event("a", t0)])
    state.record([event("a", t0), event("b", now)])
    #expect(state.history.map(\.id) == ["b", "a"])
    state.record((0..<150).map { event("x\($0)", t0.addingTimeInterval(Double($0))) })
    #expect(state.history.count == PersistedState.historyLimit)
}

@Test func graphQLErrorsWithoutDataThrow() {
    let json = Data(#"{"data": null, "errors": [{"message": "Bad credentials"}]}"#.utf8)
    #expect(throws: GitHubError.self) {
        let _: MentionsData = try GitHubClient.decode(json)
    }
}
