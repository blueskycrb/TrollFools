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

    // Keep the inbox in iCloud Drive instead of TrollFools' app container.
    // TrollFools must run without a sandbox/container so CoreTrust helper tools can
    // execute correctly under TrollStore. iCloud Drive is still directly visible in
    // Files.app and survives reinstalling/updating TrollFools.
    static let localAutoInjectRootURL: URL = {
        let cloudDocsURL = URL(
            fileURLWithPath: "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs",
            isDirectory: true
        )
        return cloudDocsURL
            .appendingPathComponent("TrollFools", isDirectory: true)
            .appendingPathComponent("AutoInject", isDirectory: true)
            .standardizedFileURL
    }()

    static var localAutoInjectRootURLs: [URL] {
        [localAutoInjectRootURL]
    }

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
    private let inboxBundleIdentifierFileName = "_BundleIdentifier.txt"
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
            let scanDelays = Array(Set([
                delay,
                max(delay, 1),
                max(delay, 3),
                max(delay, 8),
                max(delay, 15),
                max(delay, 30),
            ])).sorted()
            for scanDelay in scanDelays {
                let workItem = DispatchWorkItem { [weak self] in
                    self?.reconcileAll(attempt: 0)
                }
                self.pendingWorkItems.append(workItem)
                self.queue.asyncAfter(deadline: .now() + scanDelay, execute: workItem)
            }
        }
    }

    func createAllInstalledApplicationDirectories(completion: @escaping (Int) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }

            let ignoredPrefixes = ["com.apple.", "wiki.qaq.", "com.82flex.", "ch.xxtou."]
            var processedBundleIdentifiers = Set<String>()

            for proxy in LSApplicationWorkspace.default().allApplications() {
                autoreleasepool {
                    guard let bundleIdentifier = proxy.applicationIdentifier(),
                          !bundleIdentifier.isEmpty,
                          !ignoredPrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }),
                          !processedBundleIdentifiers.contains(bundleIdentifier),
                          let bundleURL = proxy.bundleURL(),
                          bundleURL.pathExtension.lowercased() == "app"
                    else {
                        return
                    }

                    processedBundleIdentifiers.insert(bundleIdentifier)
                    _ = self.localAutoInjectDirectory(
                        bundleIdentifier: bundleIdentifier,
                        displayName: proxy.localizedName()
                    )
                }
            }

            DispatchQueue.main.async {
                completion(processedBundleIdentifiers.count)
            }
        }
    }

    @discardableResult
    func localAutoInjectDirectory(
        bundleIdentifier: String,
        displayName: String? = nil
    ) -> URL {
        let rootURLs = Self.localAutoInjectRootURLs
        let fileManager = FileManager.default
        let resolvedDisplayName = displayName
            ?? LSApplicationProxy(forIdentifier: bundleIdentifier)?.localizedName()
            ?? bundleIdentifier

        // Reuse the folder that already carries this target marker. App display names
        // and LaunchServices collision results can change between refreshes; deriving
        // the name again used to create duplicate folders for the same application.
        if let existingURL = existingTargetDirectory(
            bundleIdentifier: bundleIdentifier,
            rootURL: Self.localAutoInjectRootURL
        ) {
            updateTargetMarkerFiles(
                folderURL: existingURL,
                bundleIdentifier: bundleIdentifier,
                displayName: resolvedDisplayName
            )
            return existingURL
        }

        let folderName = friendlyFolderName(
            displayName: resolvedDisplayName,
            bundleIdentifier: bundleIdentifier
        )
        for rootURL in rootURLs {
            let legacyURL = rootURL.appendingPathComponent(bundleIdentifier, isDirectory: true)
            let url = rootURL.appendingPathComponent(folderName, isDirectory: true)

            // Earlier builds used a raw Bundle ID as the folder name. Rename it when
            // possible so existing plug-ins remain available under the friendly name.
            if legacyURL.standardizedFileURL.path != url.standardizedFileURL.path,
               fileManager.fileExists(atPath: legacyURL.path),
               !fileManager.fileExists(atPath: url.path)
            {
                try? fileManager.moveItem(at: legacyURL, to: url)
            }

            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            updateTargetMarkerFiles(
                folderURL: url,
                bundleIdentifier: bundleIdentifier,
                displayName: resolvedDisplayName
            )
        }

        return rootURLs[0].appendingPathComponent(folderName, isDirectory: true)
    }

    private func existingTargetDirectory(bundleIdentifier: String, rootURL: URL) -> URL? {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return folders
            .filter { folderURL in
                guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    return false
                }
                let markerURL = folderURL.appendingPathComponent(inboxBundleIdentifierFileName)
                let marker = try? String(contentsOf: markerURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return marker == bundleIdentifier
            }
            .sorted { lhs, rhs in
                let lhsHasPlugins = ((try? supportedSourceURLs(in: lhs).isEmpty) == false)
                let rhsHasPlugins = ((try? supportedSourceURLs(in: rhs).isEmpty) == false)
                if lhsHasPlugins != rhsHasPlugins {
                    return lhsHasPlugins
                }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .first
    }

    private func updateTargetMarkerFiles(
        folderURL: URL,
        bundleIdentifier: String,
        displayName: String
    ) {
        let targetDescription = """
        Target app: \(displayName)
        Bundle ID: \(bundleIdentifier)

        Put .dylib, .deb, .zip, .framework, or .bundle files here.
        Subfolders are supported. Return to TrollFools and keep it in the foreground
        for about 8 seconds; injection will start automatically.
        Check _LastResult.txt in this folder for the latest result.
        """
        try? targetDescription.write(
            to: folderURL.appendingPathComponent(inboxTargetFileName),
            atomically: true,
            encoding: .utf8
        )
        try? bundleIdentifier.write(
            to: folderURL.appendingPathComponent(inboxBundleIdentifierFileName),
            atomically: true,
            encoding: .utf8
        )
    }

    private func friendlyFolderName(displayName: String, bundleIdentifier: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
        let sanitizedName = displayName
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = sanitizedName.isEmpty ? bundleIdentifier : sanitizedName

        let hasNameCollision = LSApplicationWorkspace.default().allApplications().contains { proxy in
            guard let otherBundleIdentifier = proxy.applicationIdentifier(),
                  otherBundleIdentifier != bundleIdentifier,
                  let otherName = proxy.localizedName()
            else {
                return false
            }
            return otherName.localizedCaseInsensitiveCompare(displayName) == .orderedSame
        }
        return hasNameCollision ? "\(name) [\(bundleIdentifier)]" : name
    }

    private func targetBundleIdentifier(for folderURL: URL) -> String {
        let markerURL = folderURL.appendingPathComponent(inboxBundleIdentifierFileName)
        if let value = try? String(contentsOf: markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty
        {
            return value
        }

        let folderName = folderURL.lastPathComponent
        if let openingBracket = folderName.lastIndex(of: "["), folderName.hasSuffix("]") {
            let candidate = String(folderName[folderName.index(after: openingBracket)..<folderName.index(before: folderName.endIndex)])
            if candidate.contains(".") {
                return candidate
            }
        }
        return folderName
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
        let rootURLs = Self.localAutoInjectRootURLs

        for rootURL in rootURLs {
            try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

            let readmeURL = rootURL.appendingPathComponent("README.txt")
            if !fileManager.fileExists(atPath: readmeURL.path) {
                let instructions = """
                TrollFools Local Auto-Inject Folder

                1. Open an app's advanced settings in TrollFools and create its local folder.
                   Folders use the app name, for example WeChat, instead of a raw Bundle ID.
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

            let diagnostics = """
            TrollFools auto-inject path diagnostics
            Generated: \(Date())
            App version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"))
            This folder: \(rootURL.path)

            All paths checked by TrollFools:
            \(rootURLs.map(\.path).joined(separator: "\n"))
            """
            try? diagnostics.write(
                to: rootURL.appendingPathComponent("_PathDiagnostics.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        prepareInstalledApplicationDirectories()
        removeEmptyLegacyBundleIdentifierDirectories()

    }

    private func removeEmptyLegacyBundleIdentifierDirectories() {
        let fileManager = FileManager.default

        for rootURL in Self.localAutoInjectRootURLs {
            guard let folders = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for folderURL in folders {
                guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    continue
                }

                let folderName = folderURL.lastPathComponent
                let targetMarkerURL = folderURL.appendingPathComponent(inboxBundleIdentifierFileName)

                // A newly-created target folder can legitimately use the Bundle ID
                // when LaunchServices has no localized app name. It already contains
                // our marker but no plug-in yet. Do not mistake it for an obsolete
                // empty legacy folder and delete it immediately after the button tap.
                guard !fileManager.fileExists(atPath: targetMarkerURL.path),
                      LSApplicationProxy(forIdentifier: folderName) != nil,
                      (try? supportedSourceURLs(in: folderURL).isEmpty) == true
                else {
                    continue
                }

                try? fileManager.removeItem(at: folderURL)
            }
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
        Open an app's advanced settings to create a friendly local auto-inject folder.

        \(catalog)
        """
        for rootURL in Self.localAutoInjectRootURLs {
            let catalogURL = rootURL.appendingPathComponent(installedAppsFileName)
            if (try? String(contentsOf: catalogURL, encoding: .utf8)) != contents {
                try? contents.write(to: catalogURL, atomically: true, encoding: .utf8)
            }
        }
    }

    private struct LocalImportSummary {
        var shouldRetry = false
        var targetFolderCount = 0
        var sourceCount = 0
    }

    private func importLocalAutoInjectAssets() -> LocalImportSummary {
        var combinedSummary = LocalImportSummary()

        for rootURL in Self.localAutoInjectRootURLs {
            let summary = importLocalAutoInjectAssets(from: rootURL)
            combinedSummary.shouldRetry = combinedSummary.shouldRetry || summary.shouldRetry
            combinedSummary.targetFolderCount += summary.targetFolderCount
            combinedSummary.sourceCount += summary.sourceCount
        }

        return combinedSummary
    }

    private func importLocalAutoInjectAssets(from rootURL: URL) -> LocalImportSummary {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: rootURL,
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
            let bundleIdentifier = targetBundleIdentifier(for: folderURL)
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

        let sourceNames = changedURLs
            .map { relativePath(of: $0, in: folderURL) }
            .joined(separator: ", ")
        writeInboxResult(
            folderURL: folderURL,
            message: "Plug-in detected; automatic injection is running\n\(Date())\nSources: \(sourceNames)"
        )

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
        for rootURL in Self.localAutoInjectRootURLs {
            try? message.write(
                to: rootURL.appendingPathComponent(lastScanFileName),
                atomically: true,
                encoding: .utf8
            )
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
