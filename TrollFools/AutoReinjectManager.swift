//
//  AutoReinjectManager.swift
//  TrollFools
//
//  Created by Codex on 2026/7/10.
//

import CocoaLumberjackSwift
import Foundation

final class AutoReinjectManager {
    static let shared = AutoReinjectManager()

    static let localAutoInjectRootURL: URL = {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsURL.appendingPathComponent("AutoInject", isDirectory: true)
    }()

    private struct LocalInboxState: Codable {
        var fingerprints: [String: String] = [:]
    }

    private let queue = DispatchQueue(
        label: "wiki.qaq.TrollFools.AutoReinject",
        qos: .utility
    )
    private var pendingWorkItem: DispatchWorkItem?
    private var processingBundleIdentifiers = Set<String>()

    private let supportedInboxExtensions: Set<String> = [
        "bundle", "deb", "dylib", "framework", "zip",
    ]
    private let inboxStateFileName = ".trollfools-state.json"
    private let inboxResultFileName = "_LastResult.txt"

    private init() {
        prepareLocalAutoInjectDirectory()
    }

    func schedule(after delay: TimeInterval = 8) {
        queue.async { [weak self] in
            guard let self else { return }

            self.pendingWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.reconcileAll(attempt: 0)
            }
            self.pendingWorkItem = workItem
            self.queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    @discardableResult
    func localAutoInjectDirectory(bundleIdentifier: String) -> URL {
        let url = Self.localAutoInjectRootURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func reconcileAll(attempt: Int) {
        prepareLocalAutoInjectDirectory()
        var shouldRetry = importLocalAutoInjectAssets()

        for profile in AutoInjectionStore.shared.allProfiles()
            where profile.autoReinjectEnabled && profile.plugins.contains(where: { $0.enabled })
        {
            autoreleasepool {
                do {
                    try reconcile(profile)
                } catch {
                    shouldRetry = true
                    AutoInjectionStore.shared.recordError(
                        bundleIdentifier: profile.bundleIdentifier,
                        error: error
                    )
                    DDLogError(
                        "Auto reinject \(profile.bundleIdentifier) failed: \(error)",
                        ddlog: InjectorV3.main.logger
                    )
                }
            }
        }

        guard shouldRetry, attempt < 2 else { return }
        let retryDelay: TimeInterval = attempt == 0 ? 15 : 30
        queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            self?.reconcileAll(attempt: attempt + 1)
        }
    }

    private func prepareLocalAutoInjectDirectory() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: Self.localAutoInjectRootURL,
            withIntermediateDirectories: true
        )

        let readmeURL = Self.localAutoInjectRootURL.appendingPathComponent("README.txt")
        if !fileManager.fileExists(atPath: readmeURL.path) {
            let instructions = """
            TrollFools Local Auto-Inject Folder

            1. Under AutoInject, create a folder named with the target app Bundle ID.
               Example: AutoInject/com.example.app/
            2. Put .dylib, .deb, .zip, .framework, or .bundle files into that folder.
            3. Open or return to TrollFools. It will detect the target app and inject automatically.
            4. Unchanged files are not injected repeatedly. Replacing a file triggers reinjection.
            5. After an app update, enabled plug-ins are restored by automatic reinjection.

            iOS does not allow a normal app to run forever in the background. If TrollFools is
            fully closed, open it again to scan this folder and perform automatic injection.
            """
            try? instructions.write(to: readmeURL, atomically: true, encoding: .utf8)
        }

        for profile in AutoInjectionStore.shared.allProfiles() {
            _ = localAutoInjectDirectory(bundleIdentifier: profile.bundleIdentifier)
        }
    }

    private func importLocalAutoInjectAssets() -> Bool {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: Self.localAutoInjectRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        var shouldRetry = false
        for folderURL in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            let bundleIdentifier = folderURL.lastPathComponent
            guard !bundleIdentifier.isEmpty else { continue }

            do {
                try importLocalAutoInjectAssets(
                    bundleIdentifier: bundleIdentifier,
                    folderURL: folderURL
                )
            } catch {
                shouldRetry = true
                AutoInjectionStore.shared.recordError(
                    bundleIdentifier: bundleIdentifier,
                    error: error
                )
                writeInboxResult(
                    folderURL: folderURL,
                    message: "Automatic injection failed\n\(Date())\n\(error.localizedDescription)"
                )
                DDLogError(
                    "Local auto inject \(bundleIdentifier) failed: \(error)",
                    ddlog: InjectorV3.main.logger
                )
            }
        }

        return shouldRetry
    }

    private func importLocalAutoInjectAssets(
        bundleIdentifier: String,
        folderURL: URL
    ) throws {
        guard !processingBundleIdentifiers.contains(bundleIdentifier) else { return }

        let fileManager = FileManager.default
        let allURLs = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let sourceURLs = allURLs
            .filter { supportedInboxExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !sourceURLs.isEmpty else { return }

        var state = loadInboxState(folderURL: folderURL)
        var changedURLs = [URL]()
        var changedFingerprints = [String: String]()
        for sourceURL in sourceURLs {
            let fingerprint = try fingerprint(of: sourceURL)
            let name = sourceURL.lastPathComponent
            if state.fingerprints[name] != fingerprint {
                changedURLs.append(sourceURL)
                changedFingerprints[name] = fingerprint
            }
        }
        guard !changedURLs.isEmpty else { return }

        processingBundleIdentifiers.insert(bundleIdentifier)
        defer { processingBundleIdentifiers.remove(bundleIdentifier) }

        guard let proxy = LSApplicationProxy(forIdentifier: bundleIdentifier),
              let bundleURL = proxy.bundleURL(),
              fileManager.fileExists(atPath: bundleURL.path)
        else {
            throw NSError(
                domain: Constants.gErrorDomain,
                code: 1101,
                userInfo: [
                    NSLocalizedDescriptionKey: "No installed app was found for Bundle ID \(bundleIdentifier).",
                ]
            )
        }

        let profile = AutoInjectionStore.shared.profile(for: bundleIdentifier)
        let defaults = UserDefaults.standard
        let injector = try InjectorV3(bundleURL)
        if injector.appID.isEmpty {
            injector.appID = bundleIdentifier
        }
        if injector.teamID.isEmpty {
            injector.teamID = proxy.teamID() ?? ""
        }

        injector.useWeakReference = profile?.useWeakReference
            ?? (defaults.object(forKey: "UseWeakReference-\(bundleIdentifier)") as? Bool)
            ?? true
        injector.preferMainExecutable = profile?.preferMainExecutable
            ?? (defaults.object(forKey: "PreferMainExecutable-\(bundleIdentifier)") as? Bool)
            ?? false
        injector.useFrameworkEnumerationFallback = profile?.useFrameworkEnumerationFallback
            ?? (defaults.object(forKey: "UseFrameworkEnumerationFallback-\(bundleIdentifier)") as? Bool)
            ?? true
        let strategyValue = profile?.injectStrategy
            ?? defaults.string(forKey: "InjectStrategy-\(bundleIdentifier)")
        injector.injectStrategy = strategyValue.flatMap(InjectorV3.Strategy.init(rawValue:))
            ?? .lexicographic

        let preparedURLs = try injector.inject(changedURLs, shouldPersist: true)
        AutoInjectionStore.shared.recordInjection(
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL,
            shortVersion: proxy.shortVersionString(),
            preparedURLs: preparedURLs,
            useWeakReference: injector.useWeakReference,
            preferMainExecutable: injector.preferMainExecutable,
            useFrameworkEnumerationFallback: injector.useFrameworkEnumerationFallback,
            injectStrategy: injector.injectStrategy
        )

        for (name, fingerprint) in changedFingerprints {
            state.fingerprints[name] = fingerprint
        }
        try saveInboxState(state, folderURL: folderURL)

        let sourceNames = changedURLs.map(\.lastPathComponent).joined(separator: ", ")
        let preparedNames = preparedURLs.map(\.lastPathComponent).joined(separator: ", ")
        writeInboxResult(
            folderURL: folderURL,
            message: "Automatic injection succeeded\n\(Date())\nSources: \(sourceNames)\nInjected: \(preparedNames)"
        )
        DispatchQueue.main.async {
            App.reload(bundleIdentifier: bundleIdentifier)
        }
    }

    private func loadInboxState(folderURL: URL) -> LocalInboxState {
        let stateURL = folderURL.appendingPathComponent(inboxStateFileName)
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(LocalInboxState.self, from: data)
        else {
            return LocalInboxState()
        }
        return state
    }

    private func saveInboxState(_ state: LocalInboxState, folderURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(
            to: folderURL.appendingPathComponent(inboxStateFileName),
            options: .atomic
        )
    }

    private func writeInboxResult(folderURL: URL, message: String) {
        try? message.write(
            to: folderURL.appendingPathComponent(inboxResultFileName),
            atomically: true,
            encoding: .utf8
        )
    }

    private func fingerprint(of sourceURL: URL) throws -> String {
        let fileManager = FileManager.default
        let basePath = sourceURL.path
        var records = [String]()

        func appendRecord(_ url: URL) throws {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
            let relativePath = url.path.hasPrefix(basePath)
                ? String(url.path.dropFirst(basePath.count))
                : url.lastPathComponent
            let timestamp = Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
            records.append("\(relativePath)|\(values.isDirectory == true ? "d" : "f")|\(values.fileSize ?? 0)|\(timestamp)")
        }

        try appendRecord(sourceURL)
        if (try sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           let enumerator = fileManager.enumerator(
               at: sourceURL,
               includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
               options: [.skipsHiddenFiles]
           )
        {
            let descendants = enumerator.compactMap { $0 as? URL }
                .sorted { $0.path < $1.path }
            for descendant in descendants {
                try appendRecord(descendant)
            }
        }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in records.joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private func reconcile(_ profile: AutoInjectionProfile) throws {
        let bundleIdentifier = profile.bundleIdentifier
        guard !processingBundleIdentifiers.contains(bundleIdentifier) else { return }

        processingBundleIdentifiers.insert(bundleIdentifier)
        defer { processingBundleIdentifiers.remove(bundleIdentifier) }

        guard let proxy = LSApplicationProxy(forIdentifier: bundleIdentifier),
              let bundleURL = proxy.bundleURL(),
              FileManager.default.fileExists(atPath: bundleURL.path)
        else {
            // Keep the profile when an app is temporarily unavailable or uninstalled.
            return
        }

        let desiredNames = Set(
            profile.plugins
                .filter { $0.enabled }
                .map(\.fileName)
        )
        guard !desiredNames.isEmpty else { return }

        let injectedNames = Set(
            InjectorV3.main
                .injectedAssetURLsInBundle(bundleURL)
                .map(\.lastPathComponent)
        )
        let missingNames = desiredNames.subtracting(injectedNames)

        guard !missingNames.isEmpty else {
            AutoInjectionStore.shared.recordSuccessfulReinjection(
                bundleIdentifier: bundleIdentifier,
                bundleURL: bundleURL,
                shortVersion: proxy.shortVersionString()
            )
            return
        }

        let persistedURLs = InjectorV3.main.persistedAssetURLs(bid: bundleIdentifier)
        let persistedByName = Dictionary(
            uniqueKeysWithValues: persistedURLs.map { ($0.lastPathComponent, $0) }
        )
        let missingURLs = missingNames.compactMap { persistedByName[$0] }

        guard missingURLs.count == missingNames.count else {
            let unavailableNames = missingNames
                .filter { persistedByName[$0] == nil }
                .sorted()
                .joined(separator: ", ")
            throw NSError(
                domain: Constants.gErrorDomain,
                code: 1001,
                userInfo: [
                    NSLocalizedDescriptionKey: "Persistent plug-ins are missing: \(unavailableNames)",
                ]
            )
        }

        let injector = try InjectorV3(bundleURL)
        if injector.appID.isEmpty {
            injector.appID = bundleIdentifier
        }
        if injector.teamID.isEmpty {
            injector.teamID = proxy.teamID() ?? ""
        }

        injector.useWeakReference = profile.useWeakReference
        injector.preferMainExecutable = profile.preferMainExecutable
        injector.useFrameworkEnumerationFallback = profile.useFrameworkEnumerationFallback
        injector.injectStrategy = InjectorV3.Strategy(rawValue: profile.injectStrategy) ?? .lexicographic

        try injector.inject(missingURLs, shouldPersist: false)

        let reinjectedNames = Set(
            InjectorV3.main
                .injectedAssetURLsInBundle(bundleURL)
                .map(\.lastPathComponent)
        )
        let remainingNames = desiredNames.subtracting(reinjectedNames)
        guard remainingNames.isEmpty else {
            throw NSError(
                domain: Constants.gErrorDomain,
                code: 1002,
                userInfo: [
                    NSLocalizedDescriptionKey: "Automatic reinjection verification failed: \(remainingNames.sorted().joined(separator: ", "))",
                ]
            )
        }

        AutoInjectionStore.shared.recordSuccessfulReinjection(
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL,
            shortVersion: proxy.shortVersionString()
        )
    }
}
