//
//  RepoIndexManager.swift
//  TrollFools
//

import Combine
import Foundation
import SWCompression

enum RepoIndexError: LocalizedError {
    case invalidSourceURL
    case duplicateSource
    case emptyResponse
    case httpStatus(Int)
    case packagesNotFound
    case invalidPackagesIndex
    case unsupportedPlugin

    var errorDescription: String? {
        switch self {
        case .invalidSourceURL:
            return NSLocalizedString("Please enter a valid HTTP or HTTPS source URL.", comment: "")
        case .duplicateSource:
            return NSLocalizedString("This source has already been added.", comment: "")
        case .emptyResponse:
            return NSLocalizedString("The download returned no file.", comment: "")
        case .httpStatus(let code):
            return String(format: NSLocalizedString("Download failed with HTTP status %d.", comment: ""), code)
        case .packagesNotFound:
            return NSLocalizedString("Unable to find a Packages index for this source.", comment: "")
        case .invalidPackagesIndex:
            return NSLocalizedString("The Packages index could not be parsed.", comment: "")
        case .unsupportedPlugin:
            return NSLocalizedString("The downloaded file is not a supported plug-in format.", comment: "")
        }
    }
}

final class RepoIndexManager: ObservableObject {
    static let shared = RepoIndexManager()

    private static let sourcesKey = "RepoSources.v1"
    private static let supportedPluginExtensions: Set<String> = [
        "deb", "dylib", "zip", "framework", "bundle"
    ]

    @Published private(set) var sources: [RepoSource] = []
    @Published private(set) var packagesBySource: [UUID: [RepoPackage]] = [:]
    @Published private(set) var isRefreshingAll = false
    @Published var refreshingSourceIDs: Set<UUID> = []

    private let session: URLSession
    private let queue = DispatchQueue(label: "wiki.qaq.trollfools.repos", qos: .userInitiated)

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpAdditionalHeaders = [
            "User-Agent": "TrollFools/\(Constants.gAppVersion) (APT-like; +https://github.com/blueskycrb/TrollFools)"
        ]
        session = URLSession(configuration: config)
        sources = Self.loadSources()
    }

    var allPackages: [RepoPackage] {
        sources
            .filter { $0.isEnabled }
            .flatMap { packagesBySource[$0.id] ?? [] }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    func packages(for sourceID: UUID) -> [RepoPackage] {
        packagesBySource[sourceID] ?? []
    }

    func addSource(name: String, urlString: String) throws {
        guard let baseURL = RepoSource.normalizeBaseURL(urlString) else {
            throw RepoIndexError.invalidSourceURL
        }
        let normalized = baseURL.absoluteString
        let normalizedComparable = normalized
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        if sources.contains(where: {
            ($0.normalizedBaseURL?.absoluteString
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased() ?? $0.urlString.lowercased()) == normalizedComparable
        }) {
            throw RepoIndexError.duplicateSource
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? (baseURL.host ?? normalized) : trimmedName
        sources.append(RepoSource(name: displayName, urlString: normalized))
        persistSources()
    }

    func removeSources(at offsets: IndexSet) {
        let removedIDs = offsets.map { sources[$0].id }
        sources.remove(atOffsets: offsets)
        for id in removedIDs {
            packagesBySource[id] = nil
        }
        persistSources()
    }

    func removeSource(_ source: RepoSource) {
        sources.removeAll { $0.id == source.id }
        packagesBySource[source.id] = nil
        persistSources()
    }

    func toggleSource(_ source: RepoSource) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index].isEnabled.toggle()
        persistSources()
    }

    func refreshAll(completion: ((Bool) -> Void)? = nil) {
        let enabled = sources.filter { $0.isEnabled }
        guard !enabled.isEmpty else {
            completion?(true)
            return
        }
        isRefreshingAll = true
        let group = DispatchGroup()
        var overallSuccess = true
        for source in enabled {
            group.enter()
            refresh(source: source) { success in
                if !success { overallSuccess = false }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.isRefreshingAll = false
            completion?(overallSuccess)
        }
    }

    func refresh(source: RepoSource, completion: ((Bool) -> Void)? = nil) {
        guard let baseURL = source.normalizedBaseURL else {
            updateSource(source.id) { item in
                item.lastError = RepoIndexError.invalidSourceURL.localizedDescription
            }
            completion?(false)
            return
        }

        DispatchQueue.main.async {
            self.refreshingSourceIDs.insert(source.id)
        }

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let packages = try self.fetchPackages(for: source, baseURL: baseURL)
                DispatchQueue.main.async {
                    self.packagesBySource[source.id] = packages
                    self.updateSource(source.id) { item in
                        item.lastRefreshedAt = Date()
                        item.lastError = nil
                        item.packageCount = packages.count
                    }
                    self.refreshingSourceIDs.remove(source.id)
                    completion?(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateSource(source.id) { item in
                        item.lastError = error.localizedDescription
                    }
                    self.refreshingSourceIDs.remove(source.id)
                    completion?(false)
                }
            }
        }
    }

    func downloadPackage(_ package: RepoPackage, completion: @escaping (Result<URL, Error>) -> Void) {
        let task = session.downloadTask(with: package.downloadURL) { localURL, response, error in
            do {
                if let error { throw error }
                guard let localURL else { throw RepoIndexError.emptyResponse }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw RepoIndexError.httpStatus(http.statusCode)
                }

                let fileName = Self.preferredFileName(
                    package: package,
                    response: response,
                    localURL: localURL
                )
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TrollFools-RepoDownloads", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(UUID().uuidString + "-" + fileName)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: localURL, to: destination)
                DispatchQueue.main.async {
                    completion(.success(destination))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
        task.resume()
    }

    private func updateSource(_ id: UUID, mutate: (inout RepoSource) -> Void) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        var item = sources[index]
        mutate(&item)
        sources[index] = item
        persistSources()
    }

    private func persistSources() {
        Self.saveSources(sources)
    }

    private static func loadSources() -> [RepoSource] {
        guard let data = UserDefaults.standard.data(forKey: sourcesKey),
              let decoded = try? JSONDecoder().decode([RepoSource].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private static func saveSources(_ sources: [RepoSource]) {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: sourcesKey)
    }

    private func fetchPackages(for source: RepoSource, baseURL: URL) throws -> [RepoPackage] {
        let candidatePaths = Self.packagesCandidatePaths(baseURL: baseURL)
        var lastError: Error = RepoIndexError.packagesNotFound

        for pathURL in candidatePaths {
            do {
                let raw = try downloadData(from: pathURL)
                let textData = try Self.decodePackagesData(raw, suggestedURL: pathURL)
                guard let text = String(data: textData, encoding: .utf8)
                        ?? String(data: textData, encoding: .isoLatin1)
                else {
                    throw RepoIndexError.invalidPackagesIndex
                }
                let packages = Self.parsePackages(
                    text: text,
                    source: source,
                    baseURL: baseURL
                )
                if !packages.isEmpty || text.contains("Package:") {
                    return packages
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func downloadData(from url: URL) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?
        var statusCode: Int?

        let task = session.dataTask(with: url) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                resultError = error
                return
            }
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                if !(200...299).contains(http.statusCode) {
                    resultError = RepoIndexError.httpStatus(http.statusCode)
                    return
                }
            }
            resultData = data
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 60)

        if let resultError { throw resultError }
        guard let resultData, !resultData.isEmpty else {
            if let statusCode {
                throw RepoIndexError.httpStatus(statusCode)
            }
            throw RepoIndexError.emptyResponse
        }
        return resultData
    }

    private static func packagesCandidatePaths(baseURL: URL) -> [URL] {
        let suffixes = [
            "Packages.bz2",
            "Packages.gz",
            "Packages.xz",
            "Packages.lzma",
            "Packages",
            "dists/stable/main/binary-iphoneos-arm/Packages.bz2",
            "dists/stable/main/binary-iphoneos-arm/Packages.gz",
            "dists/stable/main/binary-iphoneos-arm/Packages.xz",
            "dists/stable/main/binary-iphoneos-arm/Packages",
            "dists/main/main/binary-iphoneos-arm/Packages.bz2",
            "dists/main/main/binary-iphoneos-arm/Packages.gz",
            "dists/main/main/binary-iphoneos-arm/Packages",
        ]
        return suffixes.map { baseURL.appendingPathComponent($0) }
    }

    private static func decodePackagesData(_ data: Data, suggestedURL: URL) throws -> Data {
        let name = suggestedURL.lastPathComponent.lowercased()
        if name.hasSuffix(".bz2") {
            return try BZip2.decompress(data: data)
        }
        if name.hasSuffix(".gz") {
            return try GzipArchive.unarchive(archive: data)
        }
        if name.hasSuffix(".xz") {
            return try XZArchive.unarchive(archive: data)
        }
        if name.hasSuffix(".lzma") {
            return try LZMA.decompress(data: data)
        }

        if data.starts(with: [0x42, 0x5A, 0x68]) {
            return try BZip2.decompress(data: data)
        }
        if data.starts(with: [0x1F, 0x8B]) {
            return try GzipArchive.unarchive(archive: data)
        }
        if data.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            return try XZArchive.unarchive(archive: data)
        }
        return data
    }

    private static func parsePackages(text: String, source: RepoSource, baseURL: URL) -> [RepoPackage] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let stanzas = normalized.components(separatedBy: "\n\n")
        var packages: [RepoPackage] = []
        packages.reserveCapacity(stanzas.count)

        for stanza in stanzas {
            let trimmed = stanza.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let fields = parseControlFields(trimmed)
            guard let packageID = fields["package"], !packageID.isEmpty else { continue }
            guard let filename = fields["filename"], !filename.isEmpty else { continue }
            guard let downloadURL = resolveDownloadURL(filename: filename, baseURL: baseURL) else { continue }

            let version = fields["version"] ?? "0"
            let name = fields["name"] ?? packageID
            let sizeValue = fields["size"].flatMap { Int64($0) }

            let package = RepoPackage(
                sourceID: source.id,
                sourceName: source.name,
                package: packageID,
                name: name,
                version: version,
                section: fields["section"],
                description: fields["description"],
                author: fields["author"] ?? fields["maintainer"],
                architecture: fields["architecture"],
                filename: filename,
                size: sizeValue,
                downloadURL: downloadURL
            )
            packages.append(package)
        }

        var best: [String: RepoPackage] = [:]
        for package in packages {
            if let existing = best[package.package] {
                if package.version.compare(existing.version, options: .numeric) == .orderedDescending {
                    best[package.package] = package
                }
            } else {
                best[package.package] = package
            }
        }
        return Array(best.values).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func parseControlFields(_ stanza: String) -> [String: String] {
        var fields: [String: String] = [:]
        var currentKey: String?
        for rawLine in stanza.components(separatedBy: "\n") {
            if rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t") {
                guard let currentKey else { continue }
                let continued = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if let existing = fields[currentKey] {
                    fields[currentKey] = existing + "\n" + continued
                } else {
                    fields[currentKey] = continued
                }
                continue
            }
            guard let separator = rawLine.firstIndex(of: ":") else { continue }
            let key = rawLine[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valueStart = rawLine.index(after: separator)
            let value = rawLine[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            fields[key] = value
            currentKey = key
        }
        return fields
    }

    private static func resolveDownloadURL(filename: String, baseURL: URL) -> URL? {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if let absolute = URL(string: trimmed), absolute.scheme == "http" || absolute.scheme == "https" {
            return absolute
        }
        var relative = trimmed
        while relative.hasPrefix("./") {
            relative = String(relative.dropFirst(2))
        }
        if relative.hasPrefix("/") {
            relative = String(relative.dropFirst())
        }
        return URL(string: relative, relativeTo: baseURL)?.absoluteURL
    }

    private static func preferredFileName(
        package: RepoPackage,
        response: URLResponse?,
        localURL: URL
    ) -> String {
        let candidates = [
            response?.suggestedFilename,
            response?.url?.lastPathComponent,
            package.downloadURL.lastPathComponent,
            URL(fileURLWithPath: package.filename).lastPathComponent,
            package.package + ".deb",
        ].compactMap { $0 }

        if let match = candidates.first(where: {
            supportedPluginExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
        }) {
            return match
        }
        if let first = candidates.first, !first.isEmpty {
            if URL(fileURLWithPath: first).pathExtension.isEmpty {
                return first + ".deb"
            }
            return first
        }
        return localURL.lastPathComponent + ".deb"
    }
}
