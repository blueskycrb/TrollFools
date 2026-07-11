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
    private var pendingWorkItems = [DispatchWorkItem]()
    private var processingBundleIdentifiers = Set<String>()

    private let supportedInboxExtensions: Set<String> = [
        "bundle", "deb", "dylib", "framework", "zip",
    ]
    private let inboxStateFileName = ".trollfools-state.json"
    private let inboxResultFileName = "_LastResult.txt"
    private let inboxTargetFileName = "_TargetApp.txt"
    private let lastScanFileName = "_LastScan.txt"
    private let installedAppsFileName = "_InstalledApps.txt"

    private init() {
        prepareLocalAutoInjectDirectory()
    }

    func schedule(after delay: TimeInterval = 0.5) {
        queue.async { [weak self] in
            guard let self else { return }

            self.pendingWorkItems.forEach { $0.cancel() }
            self.pendingWorkItems.removeAll()

            // Files.app and third-party file providers may finish copying after TrollFools
            // becomes active. Scan in a short burst so a temporarily stale directory does
            // not require the user to background and reopen TrollFools again.
            let scanDelays = Array(Set([delay, max(delay, 3), max(delay, 8)])).sorted()
            for scanDelay in scanDelays {
                let workItem = DispatchWorkItem { [weak self] in
                    self?.reconcileAll(attempt: 0)
                }
                self.pendingWorkItems.append(workItem)
                self.queue.asyncAfter(deadline: .now() + scanDelay, execute: workItem)
            }
        }
    }

    @discardableResult
    func localAutoInjectDirectory(
        bundleIdentifier: String,
        displayName: String? = nil
    ) -> URL {
        let url = Self.localAutoInjectRootURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)

        if let displayName, !displayName.isEmpty {
            let targetDescription = """
            Target app: \(displayName)
            Bundle ID: \(bundleIdentifier)

            Put .dylib, .deb, .zip, .framework, or .bundle files here.
            Subfolders are supported. Open TrollFools and keep it in the foreground
            for about 8 seconds; injection will start automatically.
            """
            try? targetDescription.write(
                to: url.appendingPathComponent(inboxTargetFileName),
                atomically: true,
                encoding: .utf8
            )
        }
        return url
    }

    private func reconcileAll(attempt: Int) {
        prepareLocalAutoInjectDirectory()
        let importSummary = importLocalAutoInjectAssets()
        var shouldRetry = importSummary.shouldRetry
        writeLastScan(summary: importSummary)

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

            1. TrollFools automatically creates a folder for every supported installed app.
               The folder name is the target app Bundle ID, for example com.example.app.
            2. Put .dylib, .deb, .zip, .framework, or .bundle files into that folder.
               Subfolders are supported.
            3. Open or return to TrollFools and keep it in front for about 8 seconds.
               It scans several times and injects automatically.
            4. Unchanged files are not injected repeatedly. Replacing a file triggers reinjection.
            5. After an app update, enabled plug-ins are restored by automatic reinjection.

            iOS does not allow a normal app to run forever in the background. If TrollFools is
            fully closed, open it again to scan this folder and perform automatic injection.
            """
            try? instructions.write(to: readmeURL, atomically: true, encoding: .utf8)
        }

        prepareInstalledApplicationDirectories()

        for profile in AutoInjectionStore.shared.allProfiles() {
            _ = localAutoInjectDirectory(bundleIdentifier: profile.bundleIdentifier)
        }
    }

    private func prepareInstalledApplicationDirectories() {
        let ignoredPrefixes = ["com.apple.", "wiki.qaq.", "com.82flex.", "ch.xxtou."]
        var catalogEntries = [(name: String, bundleIdentifier: String)]()

        for proxy in LSApplicationWorkspace.default().allApplications() {
            guard let bundleIdentifier = proxy.applicationIdentifier(),
                  !bundleIdentifier.isEmpty,
                  !ignoredPrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }),
                  let bundleURL = proxy.bundleURL(),
                  bundleURL.pathExtension.lowercased() == "app"
            else {
                continue
            }

            let displayName = proxy.localizedName() ?? bundleIdentifier
            _ = localAutoInjectDirectory(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName
            )
            catalogEntries.append((displayName, bundleIdentifier))
        }

        let catalog = catalogEntries
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { "\($0.name)\n  \($0.bundleIdentifier)" }
            .joined(separator: "\n\n")
        let contents = """
        TrollFools detected these installed third-party applications.
        A Bundle ID folder is created automatically for every entry.

        \(catalog)
        """
        let catalogURL = Self.localAutoInjectRootURL.appendingPathComponent(installedAppsFileName)
        if (try? String(contentsOf: catalogURL, encoding: .utf8)) != contents {
            try? contents.write(to: catalogURL, atomically: true, encoding: .utf8)
        }
    }

    private struct LocalImportSummary {
        var shouldRetry = false
        var targetFolderCount = 0
        var sourceCount = 0
    }

    private func importLocalAutoInjectAssets() -> LocalImportSummary {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: Self.localAutoInjectRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return LocalImportSummary()
        }

        var summary = LocalImportSummary()
        for folderURL in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            summary.targetFolderCount += 1
            let bundleIdentifier = folderURL.lastPathComponent
            guard !bundleIdentifier.isEmpty else { continue }

            do {
                let sourceURLs = try supportedSourceURLs(in: folderURL)
                summary.sourceCount += sourceURLs.count
                try importLocalAutoInjectAssets(
                    bundleIdentifier: bundleIdentifier,
                    folderURL: folderURL,
                    sourceURLs: sourceURLs
                )
            } catch {
                summary.shouldRetry = true
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

        return summary
    }

    private func supportedSourceURLs(in folderURL: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sourceURLs = [URL]()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            let ext = url.pathExtension.lowercased()

            if values.isDirectory == true {
                if ext == "framework" || ext == "bundle" {
                    sourceURLs.append(url)
                    enumerator.skipDescendants()
                }
                continue
            }

            if supportedInboxExtensions.contains(ext), ext != "framework", ext != "bundle" {
                sourceURLs.append(url)
            }
        }

        return sourceURLs.sorted {
            relativePath(of: $0, in: folderURL)
                .localizedStandardCompare(relativePath(of: $1, in: folderURL)) == .orderedAscending
        }
    }

    private func importLocalAutoInjectAssets(
        bundleIdentifier: String,
        folderURL: URL,
        sourceURLs: [URL]
    ) throws {
        guard !processingBundleIdentifiers.contains(bundleIdentifier) else { return }
        guard !sourceURLs.isEmpty else { return }

        let fileManager = FileManager.default
        var state = loadInboxState(folderURL: folderURL)
        var changedURLs = [URL]()
        var changedFingerprints = [String: String]()
        for sourceURL in sourceURLs {
            let fingerprint = try fingerprint(of: sourceURL)
            let stateKey = relativePath(of: sourceURL, in: folderURL)
            if state.fingerprints[stateKey] != fingerprint {
                changedURLs.append(sourceURL)
                changedFingerprints[stateKey] = fingerprint
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

        for (stateKey, fingerprint) in changedFingerprints {
            state.fingerprints[stateKey] = fingerprint
        }
        try saveInboxState(state, folderURL: folderURL)

        let sourceNames = changedURLs.map { relativePath(of: $0, in: folderURL) }.joined(separator: ", ")
        let preparedNames = preparedURLs.map(\.lastPathComponent).joined(separator: ", ")
        writeInboxResult(
            folderURL: folderURL,
            message: "Automatic injection succeeded\n\(Date())\nSources: \(sourceNames)\nInjected: \(preparedNames)"
        )
        DispatchQueue.main.async {
            App.reload(bundleIdentifier: bundleIdentifier)
        }
    }

    private func relativePath(of url: URL, in folderURL: URL) -> String {
        let folderPath = folderURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private func writeLastScan(summary: LocalImportSummary) {
        let message = """
        Last automatic folder scan: \(Date())
        Target folders: \(summary.targetFolderCount)
        Supported plug-in items found: \(summary.sourceCount)
        Scan status: \(summary.shouldRetry ? "errors found; retry scheduled" : "completed")

        After copying files, keep TrollFools in the foreground for about 8 seconds.
        See _LastResult.txt inside the target Bundle ID folder for injection results.
        """
        try? message.write(
            to: Self.localAutoInjectRootURL.appendingPathComponent(lastScanFileName),
            atomically: true,
            encoding: .utf8
        )
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
