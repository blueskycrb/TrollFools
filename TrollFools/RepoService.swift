//
//  RepoService.swift
//  TrollFools
//

import Combine
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

    private static let endpoints = [
        Endpoint(path: "Packages", compression: .none),
        Endpoint(path: "Packages.bz2", compression: .bzip2),
        Endpoint(path: "Packages.xz", compression: .xz),
        Endpoint(path: "Packages.gz", compression: .gzip),
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

        fetchEndpoint(at: 0, baseURL: baseURL, source: source, completion: completion)
    }

    private static func fetchEndpoint(
        at index: Int,
        baseURL: URL,
        source: RepoSource,
        completion: @escaping (Result<[RepoPackage], Error>) -> Void
    ) {
        guard index < endpoints.count else {
            DispatchQueue.main.async {
                completion(.failure(RepoServiceError.invalidPackages))
            }
            return
        }

        let endpoint = endpoints[index]
        guard let url = URL(string: endpoint.path, relativeTo: baseURL)?.absoluteURL else {
            fetchEndpoint(at: index + 1, baseURL: baseURL, source: source, completion: completion)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("TrollFools Repo Client", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  let data,
                  (200...299).contains(httpResponse.statusCode)
            else {
                fetchEndpoint(at: index + 1, baseURL: baseURL, source: source, completion: completion)
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
                fetchEndpoint(at: index + 1, baseURL: baseURL, source: source, completion: completion)
            }
        }.resume()
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
            let fields = parseFields(stanza)
            guard let identifier = fields["Package"],
                  let name = fields["Name"] ?? fields["Package"],
                  let version = fields["Version"],
                  let architecture = fields["Architecture"]?.lowercased(),
                  let filename = fields["Filename"],
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
                author: fields["Author"] ?? fields["Maintainer"],
                section: fields["Section"],
                description: fields["Description"],
                iconURL: fields["Icon"],
                depictionURL: fields["Sileodepiction"],
                size: fields["Size"].flatMap(Int.init),
                sourceURL: source.url
            )
        }

        let grouped = Dictionary(grouping: packages) {
            "\($0.identifier)|\($0.name)"
        }

        let latestPackages = grouped.values.compactMap { candidates in
            candidates.sorted { lhs, rhs in
                if lhs.version != rhs.version {
                    return lhs.version.localizedStandardCompare(rhs.version) == .orderedDescending
                }
                return architectureRank(lhs.architecture) > architectureRank(rhs.architecture)
            }.first
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
            let key = String(line[..<separator])
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

                let fileSize = (try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard fileSize <= self.maximumSize else {
                    throw RepoServiceError.packageTooLarge
                }

                let handle = try FileHandle(forReadingFrom: temporaryURL)
                let magic = handle.readData(ofLength: 8)
                handle.closeFile()
                guard magic == Data("!<arch>\n".utf8) else {
                    throw RepoServiceError.invalidDeb
                }

                let downloadsDirectory = FileManager.default.urls(
                    for: .cachesDirectory,
                    in: .userDomainMask
                )[0].appendingPathComponent("RepoDownloads", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: downloadsDirectory,
                    withIntermediateDirectories: true
                )

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
