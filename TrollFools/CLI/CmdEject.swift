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
