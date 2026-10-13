//
//  AutoInjectionProfile.swift
//  TrollFools
//
//  Created by Codex on 2026/7/10.
//

import Foundation

struct AutoInjectionProfile: Codable {
    /// Bump when the on-disk format changes in a way that needs migration.
    static let currentSchemaVersion = 1

    var schemaVersion: Int = AutoInjectionProfile.currentSchemaVersion
    var bundleIdentifier: String
    var autoReinjectEnabled: Bool = true
    var plugins: [AutoInjectionPluginState] = []

    var useWeakReference: Bool = true
    var preferMainExecutable: Bool = false
    var useFrameworkEnumerationFallback: Bool = true
    var injectStrategy: String = InjectorV3.Strategy.lexicographic.rawValue

    var lastBundlePath: String?
    var lastShortVersion: String?
    var lastBuildVersion: String?
    var lastSuccessfulInjection: Date?
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case bundleIdentifier
        case autoReinjectEnabled
        case plugins
        case useWeakReference
        case preferMainExecutable
        case useFrameworkEnumerationFallback
        case injectStrategy
        case lastBundlePath
        case lastShortVersion
        case lastBuildVersion
        case lastSuccessfulInjection
        case lastError
    }
}

// Declared in an extension so the memberwise initializer stays available.
//
// The synthesized decoder ignores property defaults and fails with `keyNotFound` when a
// field is missing, which would make every profile written by an older version unreadable
// as soon as a field is added. Decode every field leniently and fall back to its default.
extension AutoInjectionProfile {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AutoInjectionProfile(
            bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier)
        )
        self = defaults

        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        autoReinjectEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoReinjectEnabled)
            ?? defaults.autoReinjectEnabled
        plugins = try container.decodeIfPresent([AutoInjectionPluginState].self, forKey: .plugins)
            ?? defaults.plugins

        useWeakReference = try container.decodeIfPresent(Bool.self, forKey: .useWeakReference)
            ?? defaults.useWeakReference
        preferMainExecutable = try container.decodeIfPresent(Bool.self, forKey: .preferMainExecutable)
            ?? defaults.preferMainExecutable
        useFrameworkEnumerationFallback = try container.decodeIfPresent(
            Bool.self,
            forKey: .useFrameworkEnumerationFallback
        ) ?? defaults.useFrameworkEnumerationFallback
        injectStrategy = try container.decodeIfPresent(String.self, forKey: .injectStrategy)
            ?? defaults.injectStrategy

        lastBundlePath = try container.decodeIfPresent(String.self, forKey: .lastBundlePath)
        lastShortVersion = try container.decodeIfPresent(String.self, forKey: .lastShortVersion)
        lastBuildVersion = try container.decodeIfPresent(String.self, forKey: .lastBuildVersion)
        lastSuccessfulInjection = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulInjection)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

struct AutoInjectionPluginState: Codable, Equatable {
    var fileName: String
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case fileName
        case enabled
    }
}

extension AutoInjectionPluginState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try container.decode(String.self, forKey: .fileName)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
