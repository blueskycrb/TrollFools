//
//  RootTabView.swift
//  TrollFools
//

import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var appList: AppListModel

    var body: some View {
        TabView {
            AppListView()
                .environmentObject(appList)
                .tabItem {
                    Label(NSLocalizedString("Apps", comment: ""), systemImage: "square.grid.2x2.fill")
                }

            SourcesView()
                .environmentObject(appList)
                .tabItem {
                    Label(NSLocalizedString("Sources", comment: ""), systemImage: "shippingbox.fill")
                }
        }
    }
}
