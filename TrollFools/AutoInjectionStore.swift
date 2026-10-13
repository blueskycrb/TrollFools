//
//  AutoInjectionStore.swift
//  TrollFools
//
//  Created by Codex on 2026/7/10.
//

import CocoaLumberjackSwift
import Foundation

final class AutoInjectionStore {
    static let shared = AutoInjectionStore()

    static let profilesRootURL: URL = {
        let url = URL(fileURLWithPath: "/var/mobile/Library/TrollFools/Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private let lock = NSRecursiveLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {}

    func allProfiles() -> [AutoInjectionProfile] {
        withLock {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: Self.profilesRootURL,
                includingPropertiesForKeys: nil
            ) else {
                return []
            }

            return urls
                .filter { $0.pathExtension.lowercased() == "json" }
                .compactMap { try? loadUnlocked(at: $0) }
                .sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        }
    }

    func profile(for bundleIdentifier: String) -> AutoInjectionProfile? {
        withLock {
            try? loadUnlocked(at: profileURL(bundleIdentifier: bundleIdentifier))
        }
    }

    func isAutoReinjectEnabled(bundleIdentifier: String) -> Bool {
        profile(for: bundleIdentifier)?.autoReinjectEnabled ?? true
    }

    func bootstrapProfile(
        bundleIdentifier: String,
        bundleURL: URL,
        shortVersion: String?,
        injectedURLs: [URL],
        persistedURLs: [URL]
    ) {
        withLock {
            let existingProfile: AutoInjectionProfile?
            do {
                existingProfile = try loadUnlocked(at: profileURL(bundleIdentifier: bundleIdentifier))
            } catch {
                DDLogError("Unable to read profile for \(bundleIdentifier), skipping bootstrap: \(error)")
                return
            }
            var profile = existingProfile ?? AutoInjectionProfile(bundleIdentifier: bundleIdentifier)
            let defaults = UserDefaults.standard
            if let value = defaults.object(forKey: "UseWeakReference-\(bundleIdentifier)") as? Bool {
                profile.useWeakReference = value
            }
            if let value = defaults.object(forKey: "PreferMainExecutable-\(bundleIdentifier)") as? Bool {
                profile.preferMainExecutable = value
            }
            if let value = defaults.object(forKey: "UseFrameworkEnumerationFallback-\(bundleIdentifier)") as? Bool {
                profile.useFrameworkEnumerationFallback = value
            }
            if let value = defaults.string(forKey: "InjectStrategy-\(bundleIdentifier)"),
               InjectorV3.Strategy(rawValue: value) != nil
            {
                profile.injectStrategy = value
            }

            let injectedNames = Set(injectedURLs.map(\.lastPathComponent))
            let persistedNames = Set(persistedURLs.map(\.lastPathComponent))
            let availableNames = injectedNames.union(persistedNames)
            let shouldRestoreLegacyPersistedPlugins = existingProfile == nil
                && injectedNames.isEmpty
                && !persistedNames.isEmpty

            // Existing state wins when an update has replaced the app bundle. Assets currently
            // present in the app are always considered enabled. When migrating from a version
            // without profiles, a fully replaced app has no injected assets but still has its
            // persisted copies, so restore those copies on the first reconciliation.
            profile.plugins.removeAll { !availableNames.contains($0.fileName) }

            for name in availableNames.sorted() {
                if let index = profile.plugins.firstIndex(where: { $0.fileName == name }) {
                    if injectedNames.contains(name) {
                        profile.plugins[index].enabled = true
                    }
                } else {
                    profile.plugins.append(AutoInjectionPluginState(
                        fileName: name,
                        enabled: injectedNames.contains(name) || shouldRestoreLegacyPersistedPlugins
                    ))
                }
            }

            profile.lastBundlePath = profile.lastBundlePath ?? bundleURL.path
            profile.lastShortVersion = profile.lastShortVersion ?? shortVersion
            profile.lastBuildVersion = profile.lastBuildVersion ?? Self.buildVersion(bundleURL: bundleURL)

            try? saveProfileUnlocked(profile)
        }
    }

    func recordInjection(
        bundleIdentifier: String,
        bundleURL: URL,
        shortVersion: String?,
        preparedURLs: [URL],
        useWeakReference: Bool,
        preferMainExecutable: Bool,
        useFrameworkEnumerationFallback: Bool,
        injectStrategy: InjectorV3.Strategy
    ) {
        update(bundleIdentifier: bundleIdentifier) { profile in
            for url in preparedURLs {
                let fileName = url.lastPathComponent
                if let index = profile.plugins.firstIndex(where: { $0.fileName == fileName }) {
                    profile.plugins[index].enabled = true
                } else {
                    profile.plugins.append(AutoInjectionPluginState(fileName: fileName, enabled: true))
                }
            }

            profile.useWeakReference = useWeakReference
            profile.preferMainExecutable = preferMainExecutable
            profile.useFrameworkEnumerationFallback = useFrameworkEnumerationFallback
            profile.injectStrategy = injectStrategy.rawValue
            profile.lastBundlePath = bundleURL.path
            profile.lastShortVersion = shortVersion
            profile.lastBuildVersion = Self.buildVersion(bundleURL: bundleURL)
            profile.lastSuccessfulInjection = Date()
            profile.lastError = nil
        }
    }

    func setAutoReinjectEnabled(bundleIdentifier: String, enabled: Bool) {
        update(bundleIdentifier: bundleIdentifier) { profile in
            profile.autoReinjectEnabled = enabled
        }
    }

    func updateInjectionOptions(
        bundleIdentifier: String,
        useWeakReference: Bool,
        preferMainExecutable: Bool,
        useFrameworkEnumerationFallback: Bool,
        injectStrategy: InjectorV3.Strategy
    ) {
        update(bundleIdentifier: bundleIdentifier) { profile in
            profile.useWeakReference = useWeakReference
            profile.preferMainExecutable = preferMainExecutable
            profile.useFrameworkEnumerationFallback = useFrameworkEnumerationFallback
            profile.injectStrategy = injectStrategy.rawValue
        }
    }

    func setPluginEnabled(bundleIdentifier: String, fileName: String, enabled: Bool) {
        setPluginsEnabled(bundleIdentifier: bundleIdentifier, fileNames: [fileName], enabled: enabled)
    }

    func setPluginsEnabled(bundleIdentifier: String, fileNames: [String], enabled: Bool) {
        let names = Set(fileNames)
        guard !names.isEmpty else { return }

        update(bundleIdentifier: bundleIdentifier) { profile in
            for name in names {
                if let index = profile.plugins.firstIndex(where: { $0.fileName == name }) {
                    profile.plugins[index].enabled = enabled
                } else {
                    profile.plugins.append(AutoInjectionPluginState(fileName: name, enabled: enabled))
                }
            }
        }
    }

    func removePlugins(bundleIdentifier: String, fileNames: [String]) {
        let names = Set(fileNames)
        guard !names.isEmpty else { return }

        update(bundleIdentifier: bundleIdentifier) { profile in
            profile.plugins.removeAll { names.contains($0.fileName) }
        }
    }

    func recordSuccessfulReinjection(
        bundleIdentifier: String,
        bundleURL: URL,
        shortVersion: String?
    ) {
        update(bundleIdentifier: bundleIdentifier) { profile in
            profile.lastBundlePath = bundleURL.path
            profile.lastShortVersion = shortVersion
            profile.lastBuildVersion = Self.buildVersion(bundleURL: bundleURL)
            profile.lastSuccessfulInjection = Date()
            profile.lastError = nil
        }
    }

    func recordError(bundleIdentifier: String, error: Error) {
        update(bundleIdentifier: bundleIdentifier) { profile in
            profile.lastError = error.localizedDescription
        }
    }

    private func update(
        bundleIdentifier: String,
        mutation: (inout AutoInjectionProfile) -> Void
    ) {
        withLock {
            var profile: AutoInjectionProfile
            do {
                profile = try loadUnlocked(at: profileURL(bundleIdentifier: bundleIdentifier))
                    ?? AutoInjectionProfile(bundleIdentifier: bundleIdentifier)
            } catch {
                DDLogError("Unable to read profile for \(bundleIdentifier), not updating it: \(error)")
                return
            }
            mutation(&profile)
            try? saveProfileUnlocked(profile)
        }
    }

    private func profileURL(bundleIdentifier: String) -> URL {
        Self.profilesRootURL
            .appendingPathComponent(bundleIdentifier)
            .appendingPathExtension("json")
    }

    /// Returns the stored profile, or nil when none exists.
    ///
    /// A profile that exists but cannot be decoded is moved aside instead of being silently
    /// replaced by an empty one on the next write, so the user's plug-in list can still be
    /// recovered by hand. A file that cannot be read at all (for example a permission
    /// problem) is left untouched and the error is thrown, so callers do not overwrite it.
    private func loadUnlocked(at url: URL) throws -> AutoInjectionProfile? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        do {
            return try decoder.decode(AutoInjectionProfile.self, from: data)
        } catch {
            let timestamp = Int(Date().timeIntervalSince1970)
            let quarantineURL = url.appendingPathExtension("corrupt-\(timestamp)")
            do {
                try FileManager.default.moveItem(at: url, to: quarantineURL)
                DDLogError("Moved undecodable profile \(url.lastPathComponent) aside: \(error)")
            } catch let moveError {
                DDLogError("Unable to quarantine profile \(url.lastPathComponent): \(moveError)")
                throw moveError
            }
            return nil
        }
    }

    private func saveProfileUnlocked(_ profile: AutoInjectionProfile) throws {
        var profile = profile
        profile.schemaVersion = AutoInjectionProfile.currentSchemaVersion

        try FileManager.default.createDirectory(
            at: Self.profilesRootURL,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(profile)
        try data.write(
            to: profileURL(bundleIdentifier: profile.bundleIdentifier),
            options: .atomic
        )
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func buildVersion(bundleURL: URL) -> String? {
        Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}
