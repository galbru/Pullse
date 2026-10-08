import Foundation

/// A SemVer 2.0 version: `1.2.3`, `v1.2.3`, `1.2.3-beta.1`. Build metadata (`+…`) is
/// accepted and ignored, as SemVer says it must be for precedence.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot-separated prerelease identifiers; empty for a release.
    public let prerelease: [String]

    public init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.hasPrefix("v") { core.removeFirst() }
        if let plus = core.firstIndex(of: "+") { core = String(core[..<plus]) }

        var pre: [String] = []
        if let dash = core.firstIndex(of: "-") {
            pre = core[core.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty && $0.allSatisfy(Self.isIdentifierChar) })
            else { return nil }
            core = String(core[..<dash])
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = pre
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // A release outranks any of its prereleases.
        if a.prerelease.isEmpty || b.prerelease.isEmpty {
            return !a.prerelease.isEmpty && b.prerelease.isEmpty
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true    // numeric identifiers sort first
            case (nil, .some): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    private static func isIdentifierChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-")
    }
}

/// A GitHub release, as the REST API returns it.
public struct Release: Decodable, Sendable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let htmlUrl: String
    public let publishedAt: Date?
    public let assets: [ReleaseAsset]
}

public struct ReleaseAsset: Decodable, Sendable, Equatable {
    public let id: Int
    public let name: String
    /// The API URL. Downloading it with `Accept: application/octet-stream` works for
    /// private repositories too, unlike `browserDownloadUrl`.
    public let url: String
    public let size: Int

    public init(id: Int, name: String, url: String, size: Int) {
        self.id = id
        self.name = name
        self.url = url
        self.size = size
    }
}

public struct AvailableUpdate: Sendable, Equatable {
    public let version: SemanticVersion
    public let archive: ReleaseAsset
    public let checksum: ReleaseAsset
    public let notes: String
    public let pageURL: String

    public init(
        version: SemanticVersion, archive: ReleaseAsset, checksum: ReleaseAsset,
        notes: String, pageURL: String
    ) {
        self.version = version
        self.archive = archive
        self.checksum = checksum
        self.notes = notes
        self.pageURL = pageURL
    }
}

public enum UpdateChecker {
    /// Whether a build's bundle id lets it install a release in place. A local build
    /// made without a bundle id has a placeholder no release has, and the install refuses
    /// an update whose bundle id differs, so it can only download. A CI build with the
    /// placeholder (a fork that never set one) still can: its releases all share it.
    public static func canInstallReleases(placeholderBundleID: Bool, localBuild: String?) -> Bool {
        !(placeholderBundleID && localBuild != nil)
    }

    /// The zip `scripts/package.sh` produces for a version; its checksum is this plus
    /// ".sha256".
    public static func archiveName(for version: SemanticVersion) -> String {
        "Pullse-\(version).zip"
    }

    /// The newest usable release above `current`, or nil. Drafts are skipped, and so are
    /// prereleases unless asked for. A release counts only if it carries both the zip and
    /// its checksum, so a release still uploading its assets is simply not offered yet.
    public static func latest(
        from releases: [Release], current: SemanticVersion, includePrereleases: Bool
    ) -> AvailableUpdate? {
        releases.compactMap { release -> AvailableUpdate? in
            guard !release.draft, let version = SemanticVersion(release.tagName), version > current,
                  includePrereleases || (!release.prerelease && !version.isPrerelease)
            else { return nil }
            let name = archiveName(for: version)
            guard let archive = release.assets.first(where: { $0.name == name }),
                  let checksum = release.assets.first(where: { $0.name == name + ".sha256" })
            else { return nil }
            return AvailableUpdate(
                version: version, archive: archive, checksum: checksum,
                notes: release.body ?? "", pageURL: release.htmlUrl
            )
        }
        .max { $0.version < $1.version }
    }

    /// The SHA-256 for `fileName` from `shasum -a 256` output ("<hex>  <name>"), lowercased.
    /// A single bare hash is accepted too.
    public static func checksum(in text: String, for fileName: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let hash = fields.first, hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            if fields.count == 1 { return hash.lowercased() }
            // shasum marks binary mode with a leading "*" on the name.
            let name = fields[1].hasPrefix("*") ? fields[1].dropFirst() : fields[1]
            if name == fileName { return hash.lowercased() }
        }
        return nil
    }

    /// "owner/name", the only shape accepted for the update repository, so nothing else
    /// can end up in the API path.
    public static func isValidRepository(_ repository: String) -> Bool {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }
    }
}

extension JSONDecoder {
    /// GitHub's REST API uses snake_case keys.
    static let githubREST: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
