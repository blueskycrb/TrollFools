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
    @Published private(set) var localPlugins: [LocalPluginFile] = []

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
        reloadLocalPlugins()
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

    @discardableResult
    func addSource(name: String, urlString: String) throws -> RepoSource {
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
        let source = RepoSource(name: displayName, urlString: normalized)
        sources.append(source)
        persistSources()
        return source
    }

    func addSources(
        from rawText: String,
        completion: @escaping (_ added: Int, _ skipped: Int, _ messages: [String]) -> Void
    ) {
        let urls = Self.sourceURLStrings(from: rawText)
        guard !urls.isEmpty else {
            completion(0, 0, [RepoIndexError.invalidSourceURL.localizedDescription])
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            var resolved: [(URL, String)] = []
            var failures: [String] = []

            for rawURL in urls {
                guard let baseURL = RepoSource.normalizeBaseURL(rawURL) else {
                    failures.append("\(rawURL): \(RepoIndexError.invalidSourceURL.localizedDescription)")
                    continue
                }
                let title = self.fetchRepositoryTitle(baseURL: baseURL)
                    ?? baseURL.host
                    ?? baseURL.absoluteString
                resolved.append((baseURL, title))
            }

            DispatchQueue.main.async {
                var added = 0
                var skipped = failures.count
                var messages = failures
                var addedSources: [RepoSource] = []

                for (baseURL, title) in resolved {
                    do {
                        let source = try self.addSource(name: title, urlString: baseURL.absoluteString)
                        addedSources.append(source)
                        added += 1
                    } catch {
                        skipped += 1
                        messages.append("\(baseURL.absoluteString): \(error.localizedDescription)")
                    }
                }

                for source in addedSources {
                    self.refresh(source: source)
                }
                completion(added, skipped, messages)
            }
        }
    }
    func removeSources(at offsets: IndexSet) {
        let removedIDs = offsets.map { sources[$0].id }
        sources.remove(atOffsets: offsets)
        for id in removedIDs {
            packagesBySource[id] = nil
        }
        persistSources()
    }

    func removeSources(_ sourcesToRemove: [RepoSource]) {
        let removedIDs = Set(sourcesToRemove.map(\.id))
        guard !removedIDs.isEmpty else { return }
        sources.removeAll { removedIDs.contains($0.id) }
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
                let directory = try Self.localPluginDirectoryURL()
                let destination = Self.uniqueDestinationURL(fileName: fileName, in: directory)
                try FileManager.default.copyItem(at: localURL, to: destination)
                DispatchQueue.main.async {
                    self.reloadLocalPlugins()
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

    func reloadLocalPlugins() {
        do {
            let directory = try Self.localPluginDirectoryURL()
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            localPlugins = urls.compactMap { url in
                guard Self.supportedPluginExtensions.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true
                else { return nil }
                return LocalPluginFile(
                    url: url,
                    fileSize: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate
                )
            }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        } catch {
            localPlugins = []
        }
    }

    func deleteLocalPlugin(_ plugin: LocalPluginFile) throws {
        try FileManager.default.removeItem(at: plugin.url)
        reloadLocalPlugins()
    }

    func deleteLocalPlugins(at offsets: IndexSet) throws {
        let items = offsets.compactMap { index in
            localPlugins.indices.contains(index) ? localPlugins[index] : nil
        }
        for item in items {
            try FileManager.default.removeItem(at: item.url)
        }
        reloadLocalPlugins()
    }

    func deleteAllLocalPlugins() throws {
        for plugin in localPlugins {
            try FileManager.default.removeItem(at: plugin.url)
        }
        reloadLocalPlugins()
    }

    private static func sourceURLStrings(from rawText: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",;，；"))
        var seen = Set<String>()
        return rawText.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { value in
                guard !value.isEmpty, RepoSource.normalizeBaseURL(value) != nil else { return false }
                let comparable = RepoSource.normalizeBaseURL(value)?.absoluteString.lowercased() ?? value.lowercased()
                return seen.insert(comparable).inserted
            }
    }

    private func fetchRepositoryTitle(baseURL: URL) -> String? {
        let releaseURLs = [
            baseURL.appendingPathComponent("Release"),
            baseURL.appendingPathComponent("dists/stable/Release"),
            baseURL.appendingPathComponent("dists/main/Release"),
        ]
        for url in releaseURLs {
            if let data = try? downloadData(from: url),
               let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                let fields = Self.parseControlFields(text)
                for key in ["label", "origin", "suite", "codename"] {
                    if let value = fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                        return value
                    }
                }
            }
        }
        return fetchRepositoryTitleFromHTML(baseURL: baseURL)
    }

    private func fetchRepositoryTitleFromHTML(baseURL: URL) -> String? {
        guard let data = try? downloadData(from: baseURL),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        let patterns = [
            #"<meta[^>]+(?:property|name)=[\"']og:site_name[\"'][^>]+content=[\"']([^\"']+)[\"']"#,
            #"<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+(?:property|name)=[\"']og:site_name[\"']"#,
            #"<title[^>]*>(.*?)</title>"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            let title = String(html[range])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return nil
    }

    private static func localPluginDirectoryURL() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("DownloadedPlugins", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func uniqueDestinationURL(fileName: String, in directory: URL) -> URL {
        let sanitized = fileName.replacingOccurrences(of: "/", with: "-")
        var destination = directory.appendingPathComponent(sanitized)
        guard FileManager.default.fileExists(atPath: destination.path) else { return destination }
        let stem = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var suffix = 2
        repeat {
            let candidateName = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            destination = directory.appendingPathComponent(candidateName)
            suffix += 1
        } while FileManager.default.fileExists(atPath: destination.path)
        return destination
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
