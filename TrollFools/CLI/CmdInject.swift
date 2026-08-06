//
//  CmdInject.swift
//  TrollFools
//
//  Created by Rachel on 10/3/2025.
//

import ArgumentParser
import Foundation

struct CmdInject: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "inject",
        abstract: "Inject a persistent payload to a target application"
    )

    @Argument(help: "The bundle identifier of the application.")
    var bundleIdentifier: String

    @Option(name: [.customLong("path"), .customShort("p")], parsing: .upToNextOption, help: "The path of the plugin.")
    var pluginPaths: [String]

    @Flag(name: [.customLong("fast")], help: "Use fast injection strategy.")
    var fastInjection: Bool = false

    @Flag(name: [.customLong("weak")], help: "Use weak reference.")
    var weakReference: Bool = false

    @Flag(name: [.customLong("prefer-main")], help: "Prefer the main executable as the injection target.")
    var preferMainExecutable: Bool = false

    @Flag(name: [.customLong("no-framework-fallback")], help: "Disable framework enumeration fallback.")
    var disableFrameworkFallback: Bool = false

    @Option(name: [.customLong("strategy")], help: "Injection strategy: lexicographic, fast, preorder, or postorder.")
    var strategy: String = InjectorV3.Strategy.lexicographic.rawValue

    func run() throws {
        guard let app = LSApplicationProxy(forIdentifier: bundleIdentifier),
              let appID = app.applicationIdentifier(),
              let bundleURL = app.bundleURL()
        else {
            throw ArgumentParser.ValidationError("The specified application does not exist.")
        }
        try pluginPaths.forEach {
            guard FileManager.default.fileExists(atPath: $0) else {
                throw ArgumentParser.ValidationError("This plugin does not exist: \($0)")
            }
        }
        let pluginURLs = pluginPaths.compactMap { URL(fileURLWithPath: $0) }
        guard let selectedStrategy = InjectorV3.Strategy(rawValue: strategy) else {
            throw ArgumentParser.ValidationError("Unsupported injection strategy: \(strategy)")
        }
        let injector = try InjectorV3(bundleURL, loggerType: .os)
        if injector.appID.isEmpty {
            injector.appID = appID
        }
        if injector.teamID.isEmpty {
            if let teamID = app.teamID() {
                injector.teamID = teamID
            } else {
                injector.teamID = "0000000000"
            }
        }
        injector.useWeakReference = weakReference
        injector.preferMainExecutable = preferMainExecutable
        injector.useFrameworkEnumerationFallback = !disableFrameworkFallback
        injector.injectStrategy = fastInjection ? .fast : selectedStrategy
        let preparedURLs = try injector.inject(pluginURLs, shouldPersist: true)
        AutoInjectionStore.shared.recordInjection(
            bundleIdentifier: appID,
            bundleURL: bundleURL,
            shortVersion: app.shortVersionString(),
            preparedURLs: preparedURLs,
            useWeakReference: weakReference,
            preferMainExecutable: preferMainExecutable,
            useFrameworkEnumerationFallback: !disableFrameworkFallback,
            injectStrategy: injector.injectStrategy
        )
    }
}

struct CmdPlugins: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "plugins",
        abstract: "Print injected and persisted plugins as JSON."
    )

    @Argument(help: "The bundle identifier of the application.")
    var bundleIdentifier: String

    private struct Plugin: Codable {
        let name: String
        let path: String
        let enabled: Bool
    }

    func run() throws {
        guard let app = LSApplicationProxy(forIdentifier: bundleIdentifier),
              let bundleURL = app.bundleURL()
        else {
            throw ArgumentParser.ValidationError("The specified application does not exist.")
        }

        let injector = try InjectorV3(bundleURL, loggerType: .os)
        let injected = injector.injectedAssetURLsInBundle(bundleURL)
        let enabledNames = Set(injected.map(\.lastPathComponent))
        var plugins = injected.map {
            Plugin(name: $0.lastPathComponent, path: $0.path, enabled: true)
        }
        plugins += injector.persistedAssetURLs(bid: bundleIdentifier)
            .filter { !enabledNames.contains($0.lastPathComponent) }
            .map { Plugin(name: $0.lastPathComponent, path: $0.path, enabled: false) }
        plugins.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(plugins)
        print(String(decoding: data, as: UTF8.self))
    }
}

struct CmdReconcile: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "reconcile",
        abstract: "Restore persisted plugins after application updates."
    )

    func run() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var failures = [String]()
        AutoReinjectManager.shared.reconcileNow { result in
            failures = result
            semaphore.signal()
        }
        semaphore.wait()

        guard failures.isEmpty else {
            throw ArgumentParser.ValidationError(
                "Automatic reinjection failed:\n\(failures.joined(separator: "\n"))"
            )
        }
    }
}
