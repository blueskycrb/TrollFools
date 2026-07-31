//
//  TrollFoolsApp.swift
//  TrollFools
//
//  Created by Lessica on 2024/7/19.
//

import SwiftUI

@main
struct TrollFoolsApp: SwiftUI.App {

    @AppStorage("isDisclaimerHiddenV2")
    var isDisclaimerHidden: Bool = false

    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var appList: AppListModel

    init() {
        try? FileManager.default.removeItem(at: InjectorV3.temporaryRoot)
        _appList = StateObject(wrappedValue: AppListModel())
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if isDisclaimerHidden {
                    RootTabView()
                        .environmentObject(appList)
                        .transition(.opacity)
                        .onAppear {
                            AutoReinjectManager.shared.schedule(after: 1)
                        }
                } else {
                    DisclaimerView(isDisclaimerHidden: $isDisclaimerHidden)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut, value: isDisclaimerHidden)
            .onChange(of: scenePhase) { phase in
                guard phase == .active, isDisclaimerHidden else { return }
                AutoReinjectManager.shared.schedule(after: 0.5)
            }
        }
    }
}
