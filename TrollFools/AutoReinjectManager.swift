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
    private var pendingWorkItems = [DispatchWorkItem]()
    private var processingBundleIdentifiers = Set<String>()

    /// Incremented every time a new reconciliation cycle is scheduled. Retries that belong
    /// to an older cycle see a stale generation and stop, so only one retry chain is alive.
    private var generation = 0
    private var remainingProbes = 0
    private static let retryDelays: [TimeInterval] = [15, 30]

    private init() {}

    func schedule(after delay: TimeInterval = 0.5) {
        queue.async { [weak self] in
            guard let self else { return }

            self.cancelPendingWork()
            self.generation += 1
            let generation = self.generation

            // Give LaunchServices time to finish replacing an application bundle by probing
            // several times. Rescheduling cancels every probe and retry of the previous cycle.
            let delays = Array(Set([
                delay,
                max(delay, 1),
                max(delay, 3),
                max(delay, 8),
            ])).sorted()
            self.remainingProbes = delays.count
            for reinjectDelay in delays {
                self.enqueue(after: reinjectDelay) { [weak self] in
                    self?.runProbe(generation: generation)
                }
            }
        }
    }

    func reconcileNow(completion: @escaping ([String]) -> Void) {
        queue.async { [weak self] in
            completion(self?.reconcileAll() ?? [])
        }
    }

    private func enqueue(after delay: TimeInterval, _ block: @escaping () -> Void) {
        let workItem = DispatchWorkItem(block: block)
        pendingWorkItems.append(workItem)
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelPendingWork() {
        pendingWorkItems.forEach { $0.cancel() }
        pendingWorkItems.removeAll()
    }

    private func runProbe(generation: Int) {
        guard generation == self.generation else { return }
        pendingWorkItems.removeAll { $0.isCancelled }
        remainingProbes -= 1

        // A healthy result does not end the cycle: an early probe may still see the old
        // bundle before LaunchServices replaces it, so every probe runs.
        let failures = reconcileAll()
        guard !failures.isEmpty else { return }

        // Later probes act as retries while LaunchServices may still be replacing a bundle.
        // Start the slower retry chain only after the last probe has failed.
        if remainingProbes == 0 {
            scheduleRetry(generation: generation, attempt: 0)
        }
    }

    private func runRetry(generation: Int, attempt: Int) {
        guard generation == self.generation else { return }
        pendingWorkItems.removeAll { $0.isCancelled }

        if !reconcileAll().isEmpty {
            scheduleRetry(generation: generation, attempt: attempt + 1)
        }
    }

    private func scheduleRetry(generation: Int, attempt: Int) {
        guard attempt < Self.retryDelays.count else { return }
        enqueue(after: Self.retryDelays[attempt]) { [weak self] in
            self?.runRetry(generation: generation, attempt: attempt)
        }
    }

    @discardableResult
    private func reconcileAll() -> [String] {
        var failures = [String]()

        for profile in AutoInjectionStore.shared.allProfiles()
            where profile.autoReinjectEnabled && profile.plugins.contains(where: { $0.enabled })
        {
            autoreleasepool {
                do {
                    try reconcile(profile)
                } catch {
                    failures.append("\(profile.bundleIdentifier): \(error.localizedDescription)")
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

        return failures
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

        let injector = try InjectorV3(bundleURL)
        // Hold the operation lock across check, eject, inject and verify so that another
        // process (the TrollStore integration's CLI) cannot interleave with this rebuild.
        try injector.withOperationLock {
            try reconcileLocked(
                profile,
                injector: injector,
                proxy: proxy,
                bundleURL: bundleURL,
                desiredNames: desiredNames
            )
        }
    }

    private func reconcileLocked(
        _ profile: AutoInjectionProfile,
        injector: InjectorV3,
        proxy: LSApplicationProxy,
        bundleURL: URL,
        desiredNames: Set<String>
    ) throws {
        let bundleIdentifier = profile.bundleIdentifier
        if injector.isInjectionHealthy(in: bundleURL, expectedAssetNames: desiredNames) {
            AutoInjectionStore.shared.recordSuccessfulReinjection(
                bundleIdentifier: bundleIdentifier,
                bundleURL: bundleURL,
                shortVersion: proxy.shortVersionString()
            )
            return
        }

        DDLogWarn(
            "Injection integrity check failed for \(bundleIdentifier); rebuilding enabled plug-ins",
            ddlog: InjectorV3.main.logger
        )

        let persistedURLs = InjectorV3.main.persistedAssetURLs(bid: bundleIdentifier)
        let persistedByName = Dictionary(
            uniqueKeysWithValues: persistedURLs.map { ($0.lastPathComponent, $0) }
        )
        let persistedNames = Set(persistedByName.keys)
        let desiredURLs = desiredNames.compactMap { persistedByName[$0] }

        guard desiredURLs.count == desiredNames.count else {
            let unavailableNames = desiredNames
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

        let existingURLs = injector.injectedAssetURLsInBundle(bundleURL)
            .filter { persistedNames.contains($0.lastPathComponent) }
        if !existingURLs.isEmpty && injector.hasModifiedMachO(in: bundleURL) {
            try injector.eject(existingURLs, shouldDesist: false)
        }

        try injector.inject(desiredURLs, shouldPersist: false)

        guard injector.isInjectionHealthy(in: bundleURL, expectedAssetNames: desiredNames) else {
            throw NSError(
                domain: Constants.gErrorDomain,
                code: 1002,
                userInfo: [
                    NSLocalizedDescriptionKey: "Automatic reinjection verification failed.",
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
