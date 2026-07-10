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

    private let queue = DispatchQueue(
        label: "wiki.qaq.TrollFools.AutoReinject",
        qos: .utility
    )
    private var pendingWorkItem: DispatchWorkItem?
    private var processingBundleIdentifiers = Set<String>()

    private init() {}

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

    private func reconcileAll(attempt: Int) {
        var shouldRetry = false

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
