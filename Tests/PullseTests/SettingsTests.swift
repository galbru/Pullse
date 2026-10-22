import Foundation
import Testing
@testable import PullseCore

private func temporaryFile() -> (SettingsFile, cleanup: () -> Void) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pullse-settings-\(UUID().uuidString)", isDirectory: true)
    let file = SettingsFile(url: dir.appendingPathComponent("nested/settings.json"))
    return (file, { try? FileManager.default.removeItem(at: dir) })
}

private func write(_ text: String, to file: SettingsFile) throws {
    try FileManager.default.createDirectory(
        at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: file.url)
}

@Test func defaultsNameNoOrganization() {
    let settings = PullseSettings()
    #expect(settings.organization == nil)
    #expect(settings.bundleIdentifier == nil)
    #expect(settings.mutedRepos.isEmpty)
    #expect(!settings.ignoreDrafts)
}

@Test func missingFileIsTheDefaults() throws {
    let (file, cleanup) = temporaryFile()
    defer { cleanup() }
    #expect(!file.exists)
    #expect(try file.load() == PullseSettings())
    #expect(!file.exists)  // loading never creates the file
}

@Test func settingsRoundTrip() throws {
    let (file, cleanup) = temporaryFile()
    defer { cleanup() }
    var settings = PullseSettings()
    settings.org = "acme"
    settings.pollSeconds = 300
    settings.notifyMentions = false
    settings.ciResults = .all
    settings.includeBots = true
    settings.mutedRepos = ["sandbox", "acme/legacy"]
    settings.ignoreDrafts = true
    settings.bundleIdentifier = "com.example.test"
    try file.save(settings)  // creates the missing directories
    #expect(try file.load() == settings)
}

@Test func savedFileIsReadableJSON() throws {
    let (file, cleanup) = temporaryFile()
    defer { cleanup() }
    var settings = PullseSettings()
    settings.org = "acme"
    try file.save(settings)
    let text = try String(contentsOf: file.url, encoding: .utf8)
    #expect(text.contains("\"org\" : \"acme\""))
    #expect(text.contains("\"ciResults\" : \"failuresOnly\""))
}

@Test func partialFileFillsInDefaults() throws {
    let (file, cleanup) = temporaryFile()
    defer { cleanup() }
    try write(#"{ "org": "acme", "notifyCI": false }"#, to: file)
    let settings = try file.load()
    #expect(settings.organization == "acme")
    #expect(!settings.notifyCI)
    #expect(settings.notifyComments)
    #expect(settings.pollSeconds == 60)
    #expect(settings.ciResults == .failuresOnly)
}

@Test func unknownKeysAreIgnored() throws {
    let (file, cleanup) = temporaryFile()
    defer { cleanup() }
    try write(#"{ "org": "acme", "comment": "my notes" }"#, to: file)
    #expect(try file.load().org == "acme")
}

@Test func brokenFileThrowsAndIsLeftAlone() throws {
    let (file, cleanup) = temporaryFile()
    defer { cleanup() }
    let broken = #"{ "org": "acme""#  // cut off mid-edit
    try write(broken, to: file)
    #expect(throws: SettingsFileError.self) { try file.load() }
    #expect(try String(contentsOf: file.url, encoding: .utf8) == broken)
}

@Test func wrongTypesAndUnknownModesThrow() throws {
    let (file, cleanup) = temporaryFile()
    defer { cleanup() }
    try write(#"{ "pollSeconds": "often" }"#, to: file)
    #expect {
        try file.load()
    } throws: { error in
        (error as? SettingsFileError)?.localizedDescription.contains("pollSeconds") == true
    }
    try write(#"{ "ciResults": "sometimes" }"#, to: file)
    #expect(throws: SettingsFileError.self) { try file.load() }
}

@Test func organizationIsTrimmed() {
    var settings = PullseSettings()
    settings.org = "  \n"
    #expect(settings.organization == nil)
    settings.org = " acme "
    #expect(settings.organization == "acme")
}

@Test func pollIntervalHasAFloor() {
    var settings = PullseSettings()
    settings.pollSeconds = 5
    #expect(settings.pollInterval == 30)
    settings.pollSeconds = 120
    #expect(settings.pollInterval == 120)
}

@Test func detectorSettingsFollowTheFile() {
    var settings = PullseSettings()
    settings.notifyComments = false
    settings.notifyReviews = false
    settings.ciResults = .all
    settings.includeBots = true
    settings.mutedRepos = ["Sandbox", "Acme/Legacy, docs"]
    settings.ignoreDrafts = true
    let detector = settings.detectorSettings
    #expect(!detector.comments)
    #expect(!detector.reviews)
    #expect(detector.ci)
    #expect(detector.mentions)
    #expect(detector.ciMode == .all)
    #expect(detector.includeBots)
    #expect(detector.mutedRepos == ["sandbox", "acme/legacy", "docs"])
    #expect(detector.ignoreDrafts)
}
