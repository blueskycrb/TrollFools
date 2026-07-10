//
//  AutoInjectionProfile.swift
//  TrollFools
//
//  Created by Codex on 2026/7/10.
//

import Foundation

struct AutoInjectionProfile: Codable {
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
}

struct AutoInjectionPluginState: Codable, Equatable {
    var fileName: String
    var enabled: Bool
}
