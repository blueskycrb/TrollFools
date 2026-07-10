//
//  SettingsView.swift
//  TrollFools
//
//  Created by Lessica on 2024/7/28.
//

import SwiftUI

struct SettingsView: View {
    let app: App

    init(_ app: App) {
        self.app = app
        _useWeakReference = AppStorage(wrappedValue: true, "UseWeakReference-\(app.bid)")
        _preferMainExecutable = AppStorage(wrappedValue: false, "PreferMainExecutable-\(app.bid)")
        _useFrameworkEnumerationFallback = AppStorage(wrappedValue: true, "UseFrameworkEnumerationFallback-\(app.bid)")
        _injectStrategy = AppStorage(wrappedValue: .lexicographic, "InjectStrategy-\(app.bid)")
        _autoReinjectEnabled = State(
            initialValue: AutoInjectionStore.shared.isAutoReinjectEnabled(bundleIdentifier: app.bid)
        )
    }

    @AppStorage var useWeakReference: Bool
    @AppStorage var preferMainExecutable: Bool
    @AppStorage var useFrameworkEnumerationFallback: Bool
    @AppStorage var injectStrategy: InjectorV3.Strategy

    @State private var autoReinjectEnabled: Bool
    @StateObject var viewControllerHost = ViewControllerHost()

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle(
                        NSLocalizedString("Automatically Reinject After App Updates", comment: ""),
                        isOn: $autoReinjectEnabled
                    )
                } footer: {
                    paddedHeaderFooterText(NSLocalizedString("When the app is replaced by an update, TrollFools restores only the plug-ins that were enabled before the update. If TrollFools was not running, restoration occurs the next time it is opened.", comment: ""))
                }

                Section {
                    Picker(NSLocalizedString("Injection Strategy", comment: ""), selection: $injectStrategy) {
                        ForEach(InjectorV3.Strategy.allCases, id: \.self) { strategy in
                            Text(strategy.localizedDescription).tag(strategy)
                        }
                    }
                } footer: {
                    paddedHeaderFooterText(NSLocalizedString("Choose how TrollFools tries possible targets. If the plug-in does not work as expected, try another option.", comment: ""))
                }

                Section {
                    Toggle(NSLocalizedString("Enable Compatibility Fallback", comment: ""), isOn: $useFrameworkEnumerationFallback)
                } footer: {
                    paddedHeaderFooterText(NSLocalizedString("If needed, TrollFools will use a compatibility mode to improve success rate. Keeping this on is recommended.", comment: ""))
                }

                Section {
                    Toggle(NSLocalizedString("Prefer Main Executable", comment: ""), isOn: $preferMainExecutable)
                } footer: {
                    paddedHeaderFooterText(NSLocalizedString("Try the app’s main file first. Turn this on when the plug-in does not seem active.", comment: ""))
                }

                Section {
                    Toggle(NSLocalizedString("Use Weak Reference", comment: ""), isOn: $useWeakReference)
                } footer: {
                    paddedHeaderFooterText(NSLocalizedString("Controls whether the app crashes when the plug-in cannot be found. Keeping this on can reduce unexpected crashes in some scenarios, but the plug-in will not work in those cases.", comment: ""))
                }
            }
            .navigationTitle(NSLocalizedString("Advanced Settings", comment: ""))
            .onChange(of: autoReinjectEnabled) { enabled in
                AutoInjectionStore.shared.setAutoReinjectEnabled(
                    bundleIdentifier: app.bid,
                    enabled: enabled
                )
                persistInjectionOptions()
            }
            .onChange(of: useWeakReference) { _ in persistInjectionOptions() }
            .onChange(of: preferMainExecutable) { _ in persistInjectionOptions() }
            .onChange(of: useFrameworkEnumerationFallback) { _ in persistInjectionOptions() }
            .onChange(of: injectStrategy) { _ in persistInjectionOptions() }
            .navigationBarTitleDisplayMode(.inline)
            .onViewWillAppear {
                viewControllerHost.viewController = $0
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        viewControllerHost.viewController?.dismiss(animated: true)
                    } label: {
                        Text(NSLocalizedString("Done", comment: ""))
                    }
                }
            }
        }
    }

    private func persistInjectionOptions() {
        AutoInjectionStore.shared.updateInjectionOptions(
            bundleIdentifier: app.bid,
            useWeakReference: useWeakReference,
            preferMainExecutable: preferMainExecutable,
            useFrameworkEnumerationFallback: useFrameworkEnumerationFallback,
            injectStrategy: injectStrategy
        )
    }

    @ViewBuilder
    private func paddedHeaderFooterText(_ content: String) -> some View {
        if #available(iOS 15, *) {
            Text(content)
                .font(.footnote)
        } else {
            Text(content)
                .font(.footnote)
                .padding(.horizontal, 16)
        }
    }
}
