//
//  RepoService.swift
//  TrollFools
//

import Combine
import CryptoKit
import Foundation
import SWCompression

struct RepoSource: Codable, Hashable, Identifiable {
    let url: String
    var name: String
    var iconURL: String?

    var id: String { url }

    var baseURL: URL? {
        URL(string: url)
    }

    /// Plain HTTP sources can be tampered with in transit, and their packages end up
    /// injected into other apps, so downloads from them must carry a verifiable hash.
    var isInsecure: Bool {
        baseURL?.scheme?.lowercased() == "http"
    }

    static let trollStoreX = RepoSource(
        url: "https://trollstorex.github.io/repo/",
        name: "TrollStoreX",
        iconURL: "https://trollstorex.github.io/repo/CydiaIcon@3x.png"
    )
}

struct RepoPackage: Hashable, Identifiable {
    let identifier: String
    let name: String
    let version: String
    let architecture: String
    let filename: String
    let author: String?
    let section: String?
    let description: String?
    let iconURL: String?
    let depictionURL: String?
    let size: Int?
    let sha256: String?
    let sourceURL: String

    var id: String {
        "\(sourceURL)|\(identifier)|\(version)|\(architecture)"
    }

    var downloadURL: URL? {
        guard let baseURL = URL(string: sourceURL) else {
            return nil
        }
        return URL(string: filename, relativeTo: baseURL)?.absoluteURL
    }
}

enum RepoServiceError: LocalizedError {
    case invalidSource
    case invalidResponse
    case httpError(Int)
    case invalidPackages
    case noPackages
    case packageTooLarge
    case invalidDeb
    case duplicateSource
    case checksumMismatch
    case sizeMismatch
    case insecureSourceWithoutChecksum

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return NSLocalizedString("The source URL is invalid.", comment: "")
        case .invalidResponse:
            return NSLocalizedString("The source returned an invalid response.", comment: "")
        case let .httpError(statusCode):
            return String(
                format: NSLocalizedString("The source returned HTTP status %ld.", comment: ""),
                statusCode
            )
        case .invalidPackages:
            return NSLocalizedString("The source package index could not be parsed.", comment: "")
        case .noPackages:
            return NSLocalizedString("No compatible packages were found in this source.", comment: "")
        case .packageTooLarge:
            return NSLocalizedString("The package exceeds the 100 MB download limit.", comment: "")
        case .invalidDeb:
            return NSLocalizedString("The downloaded file is not a valid Debian package.", comment: "")
        case .duplicateSource:
            return NSLocalizedString("This source has already been added.", comment: "")
        case .checksumMismatch:
            return NSLocalizedString("The downloaded package does not match the checksum published by the source.", comment: "")
        case .sizeMismatch:
            return NSLocalizedString("The downloaded package does not match the size published by the source.", comment: "")
        case .insecureSourceWithoutChecksum:
            return NSLocalizedString("This source uses insecure HTTP and does not publish a SHA256 checksum for the package, so it cannot be verified.", comment: "")
        }
    }
}

final class RepoSourceStore: ObservableObject {
    static let shared = RepoSourceStore()

    private let storageKey = "TrollFools.RepoSources.v1"
    private let userDefaults: UserDefaults

    @Published private(set) var sources: [RepoSource]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let savedSources = userDefaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([RepoSource].self, from: $0) } ?? []
        sources = [.trollStoreX] + savedSources.filter { $0.url != RepoSource.trollStoreX.url }
    }

    func add(urlString: String) throws {
        let sourceURL = try Self.normalizeURL(urlString)
        guard !sources.contains(where: { $0.url == sourceURL.absoluteString }) else {
            throw RepoServiceError.duplicateSource
        }

        let host = sourceURL.host ?? sourceURL.absoluteString
        let iconURL = sourceURL.appendingPathComponent("CydiaIcon@3x.png").absoluteString
        sources.append(RepoSource(url: sourceURL.absoluteString, name: host, iconURL: iconURL))
        save()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            guard sources[index].url != RepoSource.trollStoreX.url else {
                continue
            }
            sources.remove(at: index)
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sources) else {
            return
        }
        userDefaults.set(data, forKey: storageKey)
    }

    private static func normalizeURL(_ string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw RepoServiceError.invalidSource
        }

        components.scheme = scheme
        components.path = components.path.hasSuffix("/") ? components.path : components.path + "/"
        guard let url = components.url else {
            throw RepoServiceError.invalidSource
        }
        return url
    }
}

final class RepoSourceService {
    private struct Endpoint {
        let path: String
        let compression: Compression

        enum Compression {
            case none
            case bzip2
            case xz
            case gzip
        }
    }

    // Smallest representations first; the uncompressed index is usually the largest.
    private static let endpoints = [
        Endpoint(path: "Packages.xz", compression: .xz),
        Endpoint(path: "Packages.bz2", compression: .bzip2),
        Endpoint(path: "Packages.gz", compression: .gzip),
        Endpoint(path: "Packages", compression: .none),
    ]

    static func fetchPackages(
        from source: RepoSource,
        completion: @escaping (Result<[RepoPackage], Error>) -> Void
    ) {
        guard let baseURL = source.baseURL else {
            DispatchQueue.main.async {
                completion(.failure(RepoServiceError.invalidSource))
            }
            return
        }

        fetchEndpoint(at: 0, baseURL: baseURL, source: source, lastError: nil, completion: completion)
    }

    /// Tries each index representation in turn. When all fail, the most informative error
    /// is reported: a parse or "no packages" error from an index that was actually served
    /// wins over a plain HTTP or network failure of a representation the source lacks.
    private static func fetchEndpoint(
        at index: Int,
        baseURL: URL,
        source: RepoSource,
        lastError: Error?,
        completion: @escaping (Result<[RepoPackage], Error>) -> Void
    ) {
        guard index < endpoints.count else {
            DispatchQueue.main.async {
                completion(.failure(lastError ?? RepoServiceError.invalidPackages))
            }
            return
        }

        let next: (Error) -> Void = { error in
            fetchEndpoint(at: index + 1, baseURL: baseURL, source: source, lastError: error, completion: completion)
        }
        let nextKeepingParseError: (Error) -> Void = { error in
            if let lastError, !(lastError is URLError), !Self.isHTTPError(lastError) {
                next(lastError)
            } else {
                next(error)
            }
        }

        let endpoint = endpoints[index]
        guard let url = URL(string: endpoint.path, relativeTo: baseURL)?.absoluteURL else {
            nextKeepingParseError(RepoServiceError.invalidSource)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("TrollFools Repo Client", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                nextKeepingParseError(error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, let data else {
                nextKeepingParseError(RepoServiceError.invalidResponse)
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                nextKeepingParseError(RepoServiceError.httpError(httpResponse.statusCode))
                return
            }

            do {
                let packageData: Data
                switch endpoint.compression {
                case .none:
                    packageData = data
                case .bzip2:
                    packageData = try BZip2.decompress(data: data)
                case .xz:
                    packageData = try XZArchive.unarchive(archive: data)
                case .gzip:
                    packageData = try GzipArchive.unarchive(archive: data)
                }

                let packages = try RepoPackagesParser.parse(data: packageData, source: source)
                guard !packages.isEmpty else {
                    throw RepoServiceError.noPackages
                }

                DispatchQueue.main.async {
                    completion(.success(packages))
                }
            } catch {
                next(error)
            }
        }.resume()
    }

    private static func isHTTPError(_ error: Error) -> Bool {
        guard let repoError = error as? RepoServiceError else {
            return false
        }
        switch repoError {
        case .httpError, .invalidResponse:
            return true
        default:
            return false
        }
    }
}

private enum RepoPackagesParser {
    static func parse(data: Data, source: RepoSource) throws -> [RepoPackage] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RepoServiceError.invalidPackages
        }

        let stanzas = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")

        let packages = stanzas.compactMap { stanza -> RepoPackage? in
            // Field names are case-insensitive in Debian control files, so they are stored
            // lowercased (e.g. both "SileoDepiction" and "Sileodepiction" are accepted).
            let fields = parseFields(stanza)
            guard let identifier = fields["package"],
                  let name = fields["name"] ?? fields["package"],
                  let version = fields["version"],
                  let architecture = fields["architecture"]?.lowercased(),
                  let filename = fields["filename"],
                  !identifier.isEmpty,
                  !version.isEmpty,
                  !filename.isEmpty,
                  architecture == "iphoneos-arm64e"
                    || architecture == "iphoneos-arm64"
                    || architecture == "all"
            else {
                return nil
            }

            return RepoPackage(
                identifier: identifier,
                name: name,
                version: version,
                architecture: architecture,
                filename: filename,
                author: fields["author"] ?? fields["maintainer"],
                section: fields["section"],
                description: fields["description"],
                iconURL: fields["icon"],
                depictionURL: fields["sileodepiction"],
                size: fields["size"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
                sha256: fields["sha256"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                sourceURL: source.url
            )
        }

        // One entry per package identifier: the highest Debian version, then the most
        // specific architecture. Grouping by display name as well produced duplicates
        // whenever a package was renamed between versions.
        let grouped = Dictionary(grouping: packages, by: \.identifier)

        let latestPackages = grouped.values.compactMap { candidates in
            candidates.max { lhs, rhs in
                let order = DebianVersion.compare(lhs.version, rhs.version)
                if order != 0 {
                    return order < 0
                }
                return architectureRank(lhs.architecture) < architectureRank(rhs.architecture)
            }
        }

        return latestPackages.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func parseFields(_ stanza: String) -> [String: String] {
        var fields = [String: String]()
        var currentKey: String?

        for rawLine in stanza.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix(" "), let currentKey {
                let continuation = String(line.dropFirst())
                fields[currentKey, default: ""] += "\n" + continuation
                continue
            }

            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<separator]).lowercased()
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            fields[key] = value
            currentKey = key
        }

        return fields
    }

    private static func architectureRank(_ architecture: String) -> Int {
        switch architecture {
        case "iphoneos-arm64e":
            return 3
        case "iphoneos-arm64":
            return 2
        default:
            return 1
        }
    }
}

final class RepoPackageDownloader {
    static let shared = RepoPackageDownloader()

    private let maximumSize = 100 * 1024 * 1024

    private init() {}

    func download(
        _ package: RepoPackage,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let url = package.downloadURL else {
            DispatchQueue.main.async {
                completion(.failure(RepoServiceError.invalidSource))
            }
            return
        }

        // Refuse early instead of downloading up to the limit and discarding the file.
        if let size = package.size, size > maximumSize {
            DispatchQueue.main.async {
                completion(.failure(RepoServiceError.packageTooLarge))
            }
            return
        }

        // Without TLS, only a published checksum can prove the package was not replaced.
        let isInsecure = url.scheme?.lowercased() == "http"
            || URL(string: package.sourceURL)?.scheme?.lowercased() == "http"
        if isInsecure && (package.sha256?.isEmpty ?? true) {
            DispatchQueue.main.async {
                completion(.failure(RepoServiceError.insecureSourceWithoutChecksum))
            }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("TrollFools Repo Client", forHTTPHeaderField: "User-Agent")

        URLSession.shared.downloadTask(with: request) { temporaryURL, response, error in
            do {
                if let error {
                    throw error
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode)
                else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    throw RepoServiceError.httpError(statusCode)
                }

                guard let temporaryURL else {
                    throw RepoServiceError.invalidResponse
                }

                let fileSize = try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard (fileSize ?? 0) <= self.maximumSize else {
                    throw RepoServiceError.packageTooLarge
                }
                if let expectedSize = package.size, let fileSize, expectedSize != fileSize {
                    throw RepoServiceError.sizeMismatch
                }

                if let expectedHash = package.sha256, !expectedHash.isEmpty {
                    guard try Self.sha256Hex(of: temporaryURL) == expectedHash else {
                        throw RepoServiceError.checksumMismatch
                    }
                }

                let handle = try FileHandle(forReadingFrom: temporaryURL)
                let magic = handle.readData(ofLength: 8)
                handle.closeFile()
                guard magic == Data("!<arch>\n".utf8) else {
                    throw RepoServiceError.invalidDeb
                }

                let downloadsDirectory = Self.downloadsDirectory
                try FileManager.default.createDirectory(
                    at: downloadsDirectory,
                    withIntermediateDirectories: true
                )
                Self.purgeStaleDownloads()

                let filename = Self.safeFilename(for: package)
                let destinationURL = downloadsDirectory.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: destinationURL)
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)

                DispatchQueue.main.async {
                    completion(.success(destinationURL))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    static var downloadsDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RepoDownloads", isDirectory: true)
    }

    /// Removes a package once the user is done with it. Injected plug-ins are copied into
    /// the app bundle and the persistent store, so the downloaded archive is not needed.
    static func removeDownload(at url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL.path
            == downloadsDirectory.standardizedFileURL.path
        else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes downloads older than a day, in case a previous session ended before they
    /// could be removed.
    private static func purgeStaleDownloads() {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in urls {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func safeFilename(for package: RepoPackage) -> String {
        let sourceName = package.filename
            .components(separatedBy: "/")
            .last?
            .removingPercentEncoding
            ?? ""
        let filename = sourceName.isEmpty ? "\(package.identifier).deb" : sourceName
        let safeName = filename.replacingOccurrences(
            of: "[^A-Za-z0-9._+-]",
            with: "_",
            options: .regularExpression
        )
        return safeName.lowercased().hasSuffix(".deb") ? safeName : "\(safeName).deb"
    }
}

/// Debian version comparison, following dpkg's `verrevcmp` so that epochs (`1:2.0`),
/// revisions (`1.0-2`) and tilde pre-releases (`1.0~beta1` sorts before `1.0`) are
/// ordered the same way package managers order them.
enum DebianVersion {
    /// Returns a negative value when `lhs < rhs`, zero when equal, positive when `lhs > rhs`.
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = split(lhs)
        let right = split(rhs)
        if left.epoch != right.epoch {
            return left.epoch < right.epoch ? -1 : 1
        }
        let upstream = verrevcmp(left.upstream, right.upstream)
        if upstream != 0 {
            return upstream
        }
        return verrevcmp(left.revision, right.revision)
    }

    private static func split(_ version: String) -> (epoch: Int, upstream: [UInt8], revision: [UInt8]) {
        var remainder = Substring(version.trimmingCharacters(in: .whitespaces))
        var epoch = 0
        if let colon = remainder.firstIndex(of: ":"),
           let value = Int(remainder[..<colon])
        {
            epoch = value
            remainder = remainder[remainder.index(after: colon)...]
        }

        var revision = Substring("")
        if let hyphen = remainder.lastIndex(of: "-") {
            revision = remainder[remainder.index(after: hyphen)...]
            remainder = remainder[..<hyphen]
        }

        return (epoch, Array(remainder.utf8), Array(revision.utf8))
    }

    private static func isDigit(_ c: UInt8) -> Bool {
        c >= 0x30 && c <= 0x39
    }

    private static func isAlpha(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func order(_ c: UInt8?) -> Int {
        guard let c else { return 0 }
        if isDigit(c) { return 0 }
        if isAlpha(c) { return Int(c) }
        if c == UInt8(ascii: "~") { return -1 }
        return Int(c) + 256
    }

    private static func verrevcmp(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var i = 0
        var j = 0
        func at(_ s: [UInt8], _ k: Int) -> UInt8? { k < s.count ? s[k] : nil }

        while i < a.count || j < b.count {
            var firstDiff = 0

            while (at(a, i).map { !isDigit($0) } ?? false) || (at(b, j).map { !isDigit($0) } ?? false) {
                let ac = order(at(a, i))
                let bc = order(at(b, j))
                if ac != bc {
                    return ac - bc
                }
                i += 1
                j += 1
            }

            while at(a, i) == UInt8(ascii: "0") { i += 1 }
            while at(b, j) == UInt8(ascii: "0") { j += 1 }

            while let ca = at(a, i), let cb = at(b, j), isDigit(ca), isDigit(cb) {
                if firstDiff == 0 {
                    firstDiff = Int(ca) - Int(cb)
                }
                i += 1
                j += 1
            }

            if let ca = at(a, i), isDigit(ca) { return 1 }
            if let cb = at(b, j), isDigit(cb) { return -1 }
            if firstDiff != 0 { return firstDiff }
        }
        return 0
    }
}
