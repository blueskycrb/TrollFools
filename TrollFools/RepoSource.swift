//
//  RepoSource.swift
//  TrollFools
//

import Foundation

struct RepoSource: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var urlString: String
    var isEnabled: Bool
    var lastRefreshedAt: Date?
    var lastError: String?
    var packageCount: Int

    init(
        id: UUID = UUID(),
        name: String,
        urlString: String,
        isEnabled: Bool = true,
        lastRefreshedAt: Date? = nil,
        lastError: String? = nil,
        packageCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.isEnabled = isEnabled
        self.lastRefreshedAt = lastRefreshedAt
        self.lastError = lastError
        self.packageCount = packageCount
    }

    var normalizedBaseURL: URL? {
        Self.normalizeBaseURL(urlString)
    }

    var displayHost: String {
        normalizedBaseURL?.host ?? urlString
    }

    static func normalizeBaseURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("apt:") {
            trimmed = String(trimmed.dropFirst(4))
        }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil
        else {
            return nil
        }

        components.fragment = nil
        guard var url = components.url else { return nil }
        if !url.absoluteString.hasSuffix("/") {
            url = URL(string: url.absoluteString + "/") ?? url
        }
        return url
    }
}

struct RepoPackage: Identifiable, Hashable {
    var id: String {
        "\(sourceID.uuidString)|\(package)|\(version)|\(filename)"
    }

    let sourceID: UUID
    let sourceName: String
    let package: String
    let name: String
    let version: String
    let section: String?
    let description: String?
    let author: String?
    let architecture: String?
    let filename: String
    let size: Int64?
    let downloadURL: URL

    var displayName: String {
        name.isEmpty ? package : name
    }

    var isInjectableCandidate: Bool {
        let ext = downloadURL.pathExtension.lowercased()
        if ["deb", "dylib", "zip", "framework", "bundle"].contains(ext) {
            return true
        }
        return filename.lowercased().contains(".deb")
    }

    var formattedSize: String? {
        guard let size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct LocalPluginFile: Identifiable, Hashable {
    let url: URL
    let fileSize: Int64
    let modifiedAt: Date?

    var id: String { url.path }
    var displayName: String { url.lastPathComponent }
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}
