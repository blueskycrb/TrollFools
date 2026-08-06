//
//  CmdEject.swift
//  TrollFools
//
//  Created by Rachel on 10/3/2025.
//

import ArgumentParser
import Foundation

struct CmdEject: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "eject",
        abstract: "Eject plugins from the specified application."
    )

    @Argument(help: "The bundle identifier of the application.")
    var bundleIdentifier: String

    @Option(name: [.customLong("path"), .customShort("p")], help: "The path of the plugin.")
    var pluginPath: String?

    @Flag(name: [.customLong("all")], help: "Eject all plugins.")
    var ejectAll: Bool = false

    func validate() throws {
        if ejectAll && pluginPath != nil {
            throw ArgumentParser.ValidationError(
                "The --all flag and --path option cannot be used at the same time."
            )
        }
        if !ejectAll && pluginPath == nil {
            throw ArgumentParser.ValidationError(
                "Either --all flag or --path option must be specified."
            )
        }
    }

    func run() throws {
        guard let app = LSApplicationProxy(forIdentifier: bundleIdentifier),
              let bundleURL = app.bundleURL()
        else {
            throw ArgumentParser.ValidationError("The specified application does not exist.")
        }
        if let pluginPath {
            if FileManager.default.fileExists(atPath: pluginPath) {
                let pluginURL = URL(fileURLWithPath: pluginPath)
                try InjectorV3(bundleURL, loggerType: .os).eject([pluginURL], shouldDesist: true)
                AutoInjectionStore.shared.removePlugins(
                    bundleIdentifier: bundleIdentifier,
                    fileNames: [pluginURL.lastPathComponent]
                )
            } else {
                throw ArgumentParser.ValidationError("The specified plugin path is invalid.")
            }
        } else if ejectAll {
            let fileNames = try InjectorV3(bundleURL, loggerType: .os)
                .persistedAssetURLs(bid: bundleIdentifier)
                .map(\.lastPathComponent)
            try InjectorV3(bundleURL, loggerType: .os).ejectAll(shouldDesist: true)
            AutoInjectionStore.shared.removePlugins(
                bundleIdentifier: bundleIdentifier,
                fileNames: fileNames
            )
        } else {
            throw ArgumentParser.ValidationError("No plugin to eject.")
        }
    }
}

struct CmdPluginState: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "plugin-state",
        abstract: "Enable or pause a persisted plugin."
    )

    @Argument(help: "The bundle identifier of the application.")
    var bundleIdentifier: String

    @Option(name: [.customLong("path"), .customShort("p")], help: "The path of the plugin.")
    var pluginPath: String

    @Flag(name: [.customLong("enable")], help: "Inject and enable the persisted plugin.")
    var enable: Bool = false

    @Flag(name: [.customLong("disable")], help: "Eject but keep the persisted plugin.")
    var disable: Bool = false

    func validate() throws {
        guard enable != disable else {
            throw ArgumentParser.ValidationError(
                "Exactly one of --enable or --disable must be specified."
            )
        }
    }

    func run() throws {
        guard let app = LSApplicationProxy(forIdentifier: bundleIdentifier),
              let appID = app.applicationIdentifier(),
              let bundleURL = app.bundleURL()
        else {
            throw ArgumentParser.ValidationError("The specified application does not exist.")
        }

        let requestedURL = URL(fileURLWithPath: pluginPath)
        guard FileManager.default.fileExists(atPath: requestedURL.path) else {
            throw ArgumentParser.ValidationError("The specified plugin path is invalid.")
        }

        let injector = try InjectorV3(bundleURL, loggerType: .os)
        if injector.appID.isEmpty {
            injector.appID = appID
        }
        if injector.teamID.isEmpty {
            injector.teamID = app.teamID() ?? "0000000000"
        }

        if let profile = AutoInjectionStore.shared.profile(for: appID) {
            injector.useWeakReference = profile.useWeakReference
            injector.preferMainExecutable = profile.preferMainExecutable
            injector.useFrameworkEnumerationFallback = profile.useFrameworkEnumerationFallback
            injector.injectStrategy = InjectorV3.Strategy(rawValue: profile.injectStrategy) ?? .lexicographic
        }

        let fileName = requestedURL.lastPathComponent
        let injectedURL = injector.injectedAssetURLsInBundle(bundleURL)
            .first { $0.lastPathComponent == fileName }

        if enable {
            if injectedURL == nil {
                try injector.inject([requestedURL], shouldPersist: false)
            }
        } else if let injectedURL {
            try injector.eject([injectedURL], shouldDesist: false)
        }

        AutoInjectionStore.shared.setPluginEnabled(
            bundleIdentifier: appID,
            fileName: fileName,
            enabled: enable
        )
    }
}
