//
//  InjectView.swift
//  TrollFools
//
//  Created by Lessica on 2024/7/19.
//

import CocoaLumberjackSwift
import SwiftUI

struct InjectView: View {
    struct SuccessPayload {
        let logFileURL: URL?
        let didUseFallback: Bool
    }

    @EnvironmentObject var appList: AppListModel

    let app: App
    let urlList: [URL]

    @State var injectResult: Result<SuccessPayload, Error>?
    @State private var isInjecting = true
    @StateObject fileprivate var viewControllerHost = ViewControllerHost()

    @AppStorage var useWeakReference: Bool
    @AppStorage var preferMainExecutable: Bool
    @AppStorage var useFrameworkEnumerationFallback: Bool
    @AppStorage var injectStrategy: InjectorV3.Strategy

    init(_ app: App, urlList: [URL]) {
        self.app = app
        self.urlList = urlList
        _useWeakReference = AppStorage(wrappedValue: true, "UseWeakReference-\(app.bid)")
        _preferMainExecutable = AppStorage(wrappedValue: false, "PreferMainExecutable-\(app.bid)")
        _useFrameworkEnumerationFallback = AppStorage(wrappedValue: true, "UseFrameworkEnumerationFallback-\(app.bid)")
        _injectStrategy = AppStorage(wrappedValue: .lexicographic, "InjectStrategy-\(app.bid)")
    }

    var body: some View {
        bodyContent
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !isInjecting {
                        Button(NSLocalizedString("Done", comment: "")) {
                            finishAndLeave()
                        }
                    }
                }
            }
            .navigationBarBackButtonHidden(isInjecting)
    }

    var bodyContent: some View {
        VStack {
            if let injectResult = injectResult {
                switch injectResult {
                case let .success(payload):
                    SuccessView(
                        title: NSLocalizedString("Completed", comment: ""),
                        subtitle: payload.didUseFallback
                            ? NSLocalizedString("Completed with compatibility mode. The plug-in may start working after opening some app features.", comment: "")
                            : nil,
                        logFileURL: payload.logFileURL,
                        onDone: { finishAndLeave() }
                    )
                    .onAppear {
                        unlockInteraction()
                        app.reload()
                    }
                case let .failure(error):
                    FailureView(
                        title: NSLocalizedString("Failed", comment: ""),
                        error: error,
                        onDone: { finishAndLeave() }
                    )
                    .onAppear {
                        unlockInteraction()
                        app.reload()
                    }
                }
            } else {
                if #available(iOS 16, *) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(.all, 20)
                        .controlSize(.large)
                } else {
                    // Fallback on earlier versions
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(.all, 20)
                        .scaleEffect(2.0)
                }

                Text(NSLocalizedString("Injecting", comment: ""))
                    .font(.headline)
            }
        }
        .padding()
        .animation(.easeOut, value: injectResult == nil)
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .onViewWillAppear { viewController in
            viewControllerHost.viewController = viewController
            if isInjecting {
                setInteractionEnabled(false)
            } else {
                setInteractionEnabled(true)
            }
        }
        .onAppear {
            guard isInjecting, injectResult == nil else {
                unlockInteraction()
                return
            }

            // Wait one run-loop turn so the UIKit host is attached, then capture
            // the navigation view strongly. The previous weak host reference could
            // become nil after SuccessView replaces ProgressView, leaving the UI
            // permanently non-interactive on the Completed screen.
            DispatchQueue.main.async {
                guard isInjecting, injectResult == nil else {
                    unlockInteraction()
                    return
                }

                let navigationView = viewControllerHost.viewController?
                    .navigationController?.view
                navigationView?.isUserInteractionEnabled = false

                DispatchQueue.global(qos: .userInitiated).async {
                    let result = inject()

                    DispatchQueue.main.async {
                        injectResult = result
                        isInjecting = false
                        app.reload()
                        navigationView?.isUserInteractionEnabled = true
                        unlockInteraction()
                    }
                }
            }
        }
        .onDisappear {
            unlockInteraction()
        }
    }

    private func unlockInteraction() {
        setInteractionEnabled(true)
    }

    private func setInteractionEnabled(_ enabled: Bool) {
        if let navigationView = viewControllerHost.viewController?.navigationController?.view {
            navigationView.isUserInteractionEnabled = enabled
        }
        if let view = viewControllerHost.viewController?.view {
            view.isUserInteractionEnabled = enabled
        }
    }

    private func finishAndLeave() {
        unlockInteraction()

        guard let viewController = viewControllerHost.viewController else { return }

        if appList.isSelectorMode {
            if let navigationController = viewController.navigationController {
                navigationController.dismiss(animated: true)
            } else {
                viewController.dismiss(animated: true)
            }
            return
        }

        if let navigationController = viewController.navigationController {
            navigationController.popViewController(animated: true)
        } else {
            viewController.dismiss(animated: true)
        }
    }

    private func inject() -> Result<SuccessPayload, Error> {
        var logFileURL: URL?

        do {
            let injector = try InjectorV3(app.url)
            logFileURL = injector.latestLogFileURL

            if injector.appID.isEmpty {
                injector.appID = app.bid
            }

            if injector.teamID.isEmpty {
                injector.teamID = app.teamID
            }

            injector.useWeakReference = useWeakReference
            injector.preferMainExecutable = preferMainExecutable
            injector.useFrameworkEnumerationFallback = useFrameworkEnumerationFallback
            injector.injectStrategy = injectStrategy

            let preparedURLs = try injector.inject(urlList, shouldPersist: true)
            AutoInjectionStore.shared.recordInjection(
                bundleIdentifier: app.bid,
                bundleURL: app.url,
                shortVersion: app.version,
                preparedURLs: preparedURLs,
                useWeakReference: useWeakReference,
                preferMainExecutable: preferMainExecutable,
                useFrameworkEnumerationFallback: useFrameworkEnumerationFallback,
                injectStrategy: injectStrategy
            )
            return .success(SuccessPayload(
                logFileURL: injector.latestLogFileURL,
                didUseFallback: injector.didUseMachOEnumerationFallback
            ))

        } catch {
            DDLogError("\(error)", ddlog: InjectorV3.main.logger)

            var userInfo: [String: Any] = [
                NSLocalizedDescriptionKey: error.localizedDescription,
            ]

            if let logFileURL = logFileURL {
                userInfo[NSURLErrorKey] = logFileURL
            }

            let nsErr = NSError(domain: Constants.gErrorDomain, code: 0, userInfo: userInfo)

            return .failure(nsErr)
        }
    }
}
