import Foundation
import Testing
@testable import PullseCore

private func v(_ text: String) -> SemanticVersion {
    guard let version = SemanticVersion(text) else { fatalError("bad test version \(text)") }
    return version
}

// MARK: - Versions

@Test func parsesVersions() {
    #expect(v("1.2.3").description == "1.2.3")
    #expect(v("v1.2.3").description == "1.2.3")
    #expect(v(" 0.10.0\n").description == "0.10.0")
    #expect(v("1.0.0-beta.1").prerelease == ["beta", "1"])
    #expect(v("1.0.0+build.7").description == "1.0.0")
    #expect(v("1.0.0-rc.1+sha.abc").description == "1.0.0-rc.1")
}

@Test func rejectsMalformedVersions() {
    for text in ["", "1", "1.2", "1.2.3.4", "a.b.c", "1.2.x", "1.2.3-", "1.2.3-beta..1", "1.2.3-bé", "١.٢.٣", "-1.2.3"] {
        #expect(SemanticVersion(text) == nil, "\(text)")
    }
}

@Test func ordersVersionsLikeSemVer() {
    // The example chain from the SemVer spec, plus numeric-not-textual core ordering.
    let chain = [
        "0.9.9", "0.10.0", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
        "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0",
    ].map(v)
    for (lower, higher) in zip(chain, chain.dropFirst()) {
        #expect(lower < higher, "\(lower) < \(higher)")
        #expect(!(higher < lower), "\(higher) < \(lower)")
    }
    #expect(v("1.0.0") == v("v1.0.0+meta"))
}

// MARK: - Choosing a release

private func release(
    _ tag: String, draft: Bool = false, prerelease: Bool = false,
    assets: [String]? = nil
) -> [String: Any] {
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    let names = assets ?? ["Pullse-\(version).zip", "Pullse-\(version).zip.sha256"]
    return [
        "tag_name": tag, "name": "Pullse \(version)", "body": "notes for \(version)",
        "draft": draft, "prerelease": prerelease,
        "html_url": "https://github.com/acme/pullse/releases/tag/\(tag)",
        "published_at": "2026-09-23T10:00:00Z",
        "assets": names.enumerated().map { index, name in
            ["id": index + 1, "name": name, "size": 1024,
             "url": "https://api.github.com/repos/acme/pullse/releases/assets/\(index + 1)",
             "browser_download_url": "https://github.com/acme/pullse/releases/download/\(tag)/\(name)"]
        },
    ]
}

private func releases(_ items: [[String: Any]]) throws -> [Release] {
    try JSONDecoder.githubREST.decode([Release].self, from: JSONSerialization.data(withJSONObject: items))
}

@Test func decodesTheReleasesResponse() throws {
    let decoded = try releases([release("v1.2.0")])
    #expect(decoded[0].tagName == "v1.2.0")
    #expect(decoded[0].htmlUrl == "https://github.com/acme/pullse/releases/tag/v1.2.0")
    #expect(decoded[0].assets.map(\.name) == ["Pullse-1.2.0.zip", "Pullse-1.2.0.zip.sha256"])
    #expect(decoded[0].assets[0].url == "https://api.github.com/repos/acme/pullse/releases/assets/1")
    #expect(decoded[0].publishedAt != nil)
}

@Test func picksTheNewestNewerRelease() throws {
    let list = try releases([release("v1.1.0"), release("v1.3.0"), release("v1.2.0"), release("v0.9.0")])
    let update = try #require(UpdateChecker.latest(from: list, current: v("1.0.0"), includePrereleases: false))
    #expect(update.version == v("1.3.0"))
    #expect(update.archive.name == "Pullse-1.3.0.zip")
    #expect(update.checksum.name == "Pullse-1.3.0.zip.sha256")
    #expect(update.notes == "notes for 1.3.0")
    #expect(update.pageURL.hasSuffix("/v1.3.0"))
}

@Test func nothingWhenUpToDateOrAhead() throws {
    let list = try releases([release("v1.0.0"), release("v0.9.0")])
    #expect(UpdateChecker.latest(from: list, current: v("1.0.0"), includePrereleases: false) == nil)
    #expect(UpdateChecker.latest(from: list, current: v("1.1.0"), includePrereleases: false) == nil)
    #expect(UpdateChecker.latest(from: [], current: v("1.0.0"), includePrereleases: false) == nil)
}

@Test func draftsAreNeverOffered() throws {
    let list = try releases([release("v2.0.0", draft: true)])
    #expect(UpdateChecker.latest(from: list, current: v("1.0.0"), includePrereleases: true) == nil)
}

@Test func prereleasesOnlyWhenAskedFor() throws {
    // Either GitHub's flag or a SemVer suffix makes it a prerelease.
    let list = try releases([release("v1.1.0"), release("v1.2.0-beta.1"), release("v1.3.0", prerelease: true)])
    #expect(UpdateChecker.latest(from: list, current: v("1.0.0"), includePrereleases: false)?.version == v("1.1.0"))
    #expect(UpdateChecker.latest(from: list, current: v("1.0.0"), includePrereleases: true)?.version == v("1.3.0"))
}

@Test func releasesWithoutBothAssetsAreSkipped() throws {
    let list = try releases([
        release("v1.3.0", assets: ["Pullse-1.3.0.zip"]),           // checksum still uploading
        release("v1.2.0", assets: ["Pullse-1.2.0.zip.sha256"]),
        release("v1.1.0", assets: ["Pullse-v1.1.0.zip", "Pullse-v1.1.0.zip.sha256"]),  // wrong names
        release("v1.0.1"),
    ])
    #expect(UpdateChecker.latest(from: list, current: v("1.0.0"), includePrereleases: false)?.version == v("1.0.1"))
}

@Test func tagsThatAreNotVersionsAreIgnored() throws {
    let list = try releases([release("nightly"), release("v1.0.1")])
    #expect(UpdateChecker.latest(from: list, current: v("1.0.0"), includePrereleases: true)?.version == v("1.0.1"))
}

// MARK: - Checksums and repository names

private let hash = String(repeating: "ab", count: 32)

@Test func readsShasumOutput() {
    #expect(UpdateChecker.checksum(in: "\(hash)  Pullse-1.0.0.zip\n", for: "Pullse-1.0.0.zip") == hash)
    #expect(UpdateChecker.checksum(in: "\(hash.uppercased()) *Pullse-1.0.0.zip", for: "Pullse-1.0.0.zip") == hash)
    #expect(UpdateChecker.checksum(in: hash, for: "Pullse-1.0.0.zip") == hash)
    let other = String(repeating: "cd", count: 32)
    #expect(UpdateChecker.checksum(in: "\(other)  a.zip\n\(hash)  Pullse-1.0.0.zip", for: "Pullse-1.0.0.zip") == hash)
}

@Test func rejectsBadChecksums() {
    #expect(UpdateChecker.checksum(in: "\(hash)  Other.zip", for: "Pullse-1.0.0.zip") == nil)
    #expect(UpdateChecker.checksum(in: "abc123  Pullse-1.0.0.zip", for: "Pullse-1.0.0.zip") == nil)
    #expect(UpdateChecker.checksum(in: String(repeating: "zz", count: 32), for: "x") == nil)
    #expect(UpdateChecker.checksum(in: "", for: "x") == nil)
}

@Test func repositoryNames() {
    #expect(UpdateChecker.isValidRepository("acme/pullse"))
    #expect(UpdateChecker.isValidRepository("my-org/app_v2.0"))
    for bad in ["acme", "acme/", "/pullse", "acme/pullse/extra", "../etc", "acme/..", "acme/pull se", "acme/p?x=1"] {
        #expect(!UpdateChecker.isValidRepository(bad), "\(bad)")
    }
}

// MARK: - Settings

@Test func updateSettingsDefaults() throws {
    let settings = PullseSettings()
    #expect(settings.checkForUpdates)
    #expect(!settings.autoUpdate)
    #expect(!settings.includePrereleases)
    #expect(settings.notifyAfterUpdate)

    let decoded = try JSONDecoder().decode(
        PullseSettings.self, from: Data(#"{ "autoUpdate": true }"#.utf8)
    )
    #expect(decoded.autoUpdate)
    #expect(decoded.checkForUpdates)
    #expect(decoded.notifyAfterUpdate)
}

@Test func theUpdatedNotificationCanBeTurnedOff() throws {
    let decoded = try JSONDecoder().decode(
        PullseSettings.self, from: Data(#"{ "notifyAfterUpdate": false }"#.utf8)
    )
    #expect(!decoded.notifyAfterUpdate)
    let saved = try JSONDecoder().decode(PullseSettings.self, from: JSONEncoder().encode(decoded))
    #expect(!saved.notifyAfterUpdate)
}

@Test func stateFilesFromBeforeVersionTrackingStillLoad() throws {
    let old = #"{ "seen": { "seen": {} }, "history": [] }"#
    let state = try JSONDecoder.github.decode(PersistedState.self, from: Data(old.utf8))
    #expect(state.lastRunVersion == nil)
}

@Test func onlyALocalBuildWithThePlaceholderIDCantInstallReleases() {
    #expect(!UpdateChecker.canInstallReleases(placeholderBundleID: true, localBuild: "dce94b2"))
    // A fork's CI release made without a bundle id: its releases share the placeholder.
    #expect(UpdateChecker.canInstallReleases(placeholderBundleID: true, localBuild: nil))
    #expect(UpdateChecker.canInstallReleases(placeholderBundleID: false, localBuild: "dce94b2"))
    #expect(UpdateChecker.canInstallReleases(placeholderBundleID: false, localBuild: nil))
}
