
//
//  RepoService.swift
//  TrollFools
//

import Combine
import CryptoKit
import Foundation
import SWCompression

struct RepoSource: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var urlString: String

    init(id: UUID = UUID(), name: String, urlString: String) {
        self.id = id
        self.name = name
        self.urlString = urlString
    }

    var baseURL: URL? {
        guard var components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              components.host != nil
        else {
            return nil
        }
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct RepoPackage: Hashable, Identifiable {
    let sourceID: UUID
    let identifier: String
    let name: String
    let version: String
    let architecture: String
    let section: String
    let author: String
    let packageDescription: String
    let filename: String
    let size: Int64?
    let sha256: String?
    let iconURL: URL?
    let downloadURL: URL

    var id: String {
        [sourceID.uuidString, identifier, version, architecture, filename]
            .joined(separator: "|")
    }
}

enum RepoServiceError: LocalizedError {
    case invalidSource
    case invalidResponse
    case unsupportedPackage
    case checksumMismatch
    case emptyRepository

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return NSLocalizedString("Enter a valid HTTPS repository URL.", comment: "")
        case .invalidResponse:
            return NSLocalizedString("The repository returned an invalid response.", comment: "")
        case .unsupportedPackage:
            return NSLocalizedString("Only .deb, .dylib, and .zip downloads can be injected.", comment: "")
        case .checksumMismatch:
            return NSLocalizedString("The downloaded file failed SHA-256 verification.", comment: "")
        case .emptyRepository:
            return NSLocalizedString("No injectable packages were found in this repository.", comment: "")
        }
    }
}

final class RepoService {
    static let shared = RepoService()

    static let downloadsRootURL: URL = {
        let url = URL(fileURLWithPath: "/var/mobile/Library/TrollFools/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func fetchPackages(
        from source: RepoSource,
        completion: @escaping (Result<[RepoPackage], Error>) -> Void
    ) {
        guard source.baseURL != nil else {
            completion(.failure(RepoServiceError.invalidSource))
            return
        }

        fetchPackageIndex(from: source, candidates: ["Packages", "Packages.bz2", "Packages.gz"], completion: completion)
    }

    private func fetchPackageIndex(
        from source: RepoSource,
        candidates: [String],
        completion: @escaping (Result<[RepoPackage], Error>) -> Void
    ) {
        guard let candidate = candidates.first,
              let packagesURL = source.baseURL?.appendingPathComponent(candidate)
        else {
            completion(.failure(RepoServiceError.invalidResponse))
            return
        }

        var request = URLRequest(url: packagesURL)
        request.setValue("TrollFools/4.3", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let response = response as? HTTPURLResponse,
                  (200 ... 299).contains(response.statusCode),
                  let data
            else {
                let remainingCandidates = Array(candidates.dropFirst())
                if let self, !remainingCandidates.isEmpty {
                    self.fetchPackageIndex(
                        from: source,
                        candidates: remainingCandidates,
                        completion: completion
                    )
                } else {
                    completion(.failure(error ?? RepoServiceError.invalidResponse))
                }
                return
            }

            do {
                let decodedData: Data
                switch candidate.lowercased() {
                case let value where value.hasSuffix(".bz2"):
                    decodedData = try BZip2.decompress(data: data)
                case let value where value.hasSuffix(".gz"):
                    decodedData = try GzipArchive.unarchive(archive: data)
                default:
                    decodedData = data
                }
                guard let text = String(data: decodedData, encoding: .utf8)
                    ?? String(data: decodedData, encoding: .isoLatin1)
                else {
                    throw RepoServiceError.invalidResponse
                }

                let packages = Self.parsePackages(text, source: source)
                completion(packages.isEmpty
                    ? .failure(RepoServiceError.emptyRepository)
                    : .success(packages))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    func download(
        _ package: RepoPackage,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let allowedExtensions: Set<String> = ["deb", "dylib", "zip"]
        let pathExtension = package.downloadURL.pathExtension.lowercased()
        guard package.downloadURL.scheme?.lowercased() == "https",
              allowedExtensions.contains(pathExtension)
        else {
            completion(.failure(RepoServiceError.unsupportedPackage))
            return
        }

        var request = URLRequest(url: package.downloadURL)
        request.setValue("TrollFools/4.3", forHTTPHeaderField: "User-Agent")
        session.downloadTask(with: request) { temporaryURL, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse,
                  (200 ... 299).contains(response.statusCode),
                  let temporaryURL
            else {
                completion(.failure(RepoServiceError.invalidResponse))
                return
            }

            do {
                let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
                if let expectedHash = package.sha256?.lowercased(), !expectedHash.isEmpty {
                    let actualHash = SHA256.hash(data: data)
                        .map { String(format: "%02x", $0) }
                        .joined()
                    guard actualHash == expectedHash else {
                        throw RepoServiceError.checksumMismatch
                    }
                }

                try FileManager.default.createDirectory(
                    at: Self.downloadsRootURL,
                    withIntermediateDirectories: true
                )
                let suggestedName = response.suggestedFilename
                    ?? package.downloadURL.lastPathComponent
                let safeName = Self.safeFileName(suggestedName, fallbackExtension: pathExtension)
                let destinationURL = Self.downloadsRootURL.appendingPathComponent(safeName)
                try? FileManager.default.removeItem(at: destinationURL)
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
                completion(.success(destinationURL))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func parsePackages(_ text: String, source: RepoSource) -> [RepoPackage] {
        guard let baseURL = source.baseURL else { return [] }

        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        return normalizedText
            .components(separatedBy: "\n\n")
            .compactMap { stanza -> RepoPackage? in
                let fields = parseFields(stanza)
                guard let identifier = fields["Package"],
                      let filename = fields["Filename"],
                      let downloadURL = URL(string: filename, relativeTo: baseURL)?.absoluteURL
                else {
                    return nil
                }

                let pathExtension = downloadURL.pathExtension.lowercased()
                guard ["deb", "dylib", "zip"].contains(pathExtension) else { return nil }

                return RepoPackage(
                    sourceID: source.id,
                    identifier: identifier,
                    name: fields["Name"] ?? identifier,
                    version: fields["Version"] ?? "",
                    architecture: fields["Architecture"] ?? "",
                    section: fields["Section"] ?? "",
                    author: fields["Author"] ?? fields["Maintainer"] ?? "",
                    packageDescription: fields["Description"] ?? "",
                    filename: filename,
                    size: fields["Size"].flatMap { Int64($0) },
                    sha256: fields["SHA256"],
                    iconURL: fields["Icon"].flatMap(URL.init(string:)),
                    downloadURL: downloadURL
                )
            }
            .sorted {
                let nameComparison = $0.name.localizedStandardCompare($1.name)
                if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
                return $0.architecture.localizedStandardCompare($1.architecture) == .orderedAscending
            }
    }

    private static func parseFields(_ stanza: String) -> [String: String] {
        var fields = [String: String]()
        var currentKey: String?

        for rawLine in stanza.components(separatedBy: "\n") {
            if rawLine.first == " " || rawLine.first == "\t" {
                guard let currentKey else { continue }
                let continuation = rawLine.trimmingCharacters(in: .whitespaces)
                if continuation != "." && !continuation.isEmpty {
                    fields[currentKey, default: ""] += "\n" + continuation
                }
                continue
            }

            guard let colon = rawLine.firstIndex(of: ":") else { continue }
            let key = String(rawLine[..<colon])
            let value = String(rawLine[rawLine.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            fields[key] = value
            currentKey = key
        }
        return fields
    }

    private static func safeFileName(_ value: String, fallbackExtension: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let components = value.components(separatedBy: unsafe)
        var name = components.filter { !$0.isEmpty }.joined(separator: "_")
        if name.isEmpty {
            name = "package.\(fallbackExtension)"
        } else if URL(fileURLWithPath: name).pathExtension.isEmpty {
            name += ".\(fallbackExtension)"
        }
        return name
    }
}

final class RepoStore: ObservableObject {
    static let shared = RepoStore()

    @Published private(set) var sources: [RepoSource]
    @Published private(set) var packagesBySource = [UUID: [RepoPackage]]()
    @Published private(set) var loadingSourceIDs = Set<UUID>()
    @Published private(set) var downloadingPackageID: String?
    @Published var errorMessage: String?

    private static let storageKey = "PluginRepositorySources-v1"
    private static let defaultSource = RepoSource(
        name: "TrollStoreX",
        urlString: "https://trollstorex.github.io/repo/"
    )

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let savedSources = try? JSONDecoder().decode([RepoSource].self, from: data)
        {
            sources = savedSources
        } else {
            sources = [Self.defaultSource]
        }
    }

    var allPackages: [RepoPackage] {
        sources.flatMap { packagesBySource[$0.id] ?? [] }
    }

    func addSource(name: String, urlString: String) throws {
        let source = RepoSource(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            urlString: urlString
        )
        guard let normalizedURL = source.baseURL else {
            throw RepoServiceError.invalidSource
        }
        guard !sources.contains(where: { $0.baseURL == normalizedURL }) else { return }

        var normalizedSource = source
        normalizedSource.urlString = normalizedURL.absoluteString
        if normalizedSource.name.isEmpty {
            normalizedSource.name = normalizedURL.host ?? normalizedURL.absoluteString
        }
        sources.append(normalizedSource)
        saveSources()
        refresh(normalizedSource)
    }

    func removeSources(at offsets: IndexSet) {
        let removedIDs = offsets.map { sources[$0].id }
        for index in offsets.sorted(by: >) {
            sources.remove(at: index)
        }
        removedIDs.forEach { packagesBySource.removeValue(forKey: $0) }
        saveSources()
    }

    func refreshAll() {
        sources.forEach(refresh)
    }

    func refresh(_ source: RepoSource) {
        guard !loadingSourceIDs.contains(source.id) else { return }
        loadingSourceIDs.insert(source.id)

        RepoService.shared.fetchPackages(from: source) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingSourceIDs.remove(source.id)
                switch result {
                case let .success(packages):
                    self.packagesBySource[source.id] = packages
                case let .failure(error):
                    self.errorMessage = "\(source.name): \(error.localizedDescription)"
                }
            }
        }
    }

    func download(_ package: RepoPackage, completion: @escaping (URL?) -> Void) {
        guard downloadingPackageID == nil else { return }
        downloadingPackageID = package.id
        RepoService.shared.download(package) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloadingPackageID = nil
                switch result {
                case let .success(url):
                    completion(url)
                case let .failure(error):
                    self.errorMessage = error.localizedDescription
                    completion(nil)
                }
            }
        }
    }

    private func saveSources() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
