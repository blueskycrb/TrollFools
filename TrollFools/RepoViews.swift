//
//  RepoViews.swift
//  TrollFools
//

import SwiftUI

struct RepoBrowserView: View {
    @ObservedObject private var store = RepoStore.shared
    @Environment(\.presentationMode) private var presentationMode

    let onPackageReady: (URL) -> Void

    @State private var searchText = ""

    private var filteredPackages: [RepoPackage] {
        guard !searchText.isEmpty else { return store.allPackages }
        return store.allPackages.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.identifier.localizedCaseInsensitiveContains(searchText)
                || $0.packageDescription.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    NavigationLink {
                        RepoSourcesView()
                    } label: {
                        Label(NSLocalizedString("Manage Sources", comment: ""), systemImage: "square.stack.3d.up")
                    }
                }

                Section(header: Text(NSLocalizedString("Plug-Ins", comment: ""))) {
                    if !store.sources.isEmpty
                        && store.loadingSourceIDs.count == store.sources.count
                        && store.allPackages.isEmpty
                    {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if filteredPackages.isEmpty {
                        Text(NSLocalizedString("No Packages", comment: ""))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredPackages) { package in
                            NavigationLink {
                                RepoPackageView(package: package, onPackageReady: packageReady)
                            } label: {
                                RepoPackageRow(package: package)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(NSLocalizedString("Sources", comment: ""))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(NSLocalizedString("Done", comment: "")) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        store.refreshAll()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(NSLocalizedString("Refresh Sources", comment: ""))
                    .disabled(!store.loadingSourceIDs.isEmpty)
                }
            }
            .onAppear {
                if store.allPackages.isEmpty {
                    store.refreshAll()
                }
            }
            .repoSearchable(text: $searchText)
            .repoErrorAlert(store: store)
        }
        .navigationViewStyle(.stack)
    }

    private func packageReady(_ url: URL) {
        presentationMode.wrappedValue.dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            onPackageReady(url)
        }
    }
}

private struct RepoPackageRow: View {
    let package: RepoPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(package.name)
                .font(.headline)
            HStack(spacing: 6) {
                if !package.version.isEmpty {
                    Text(package.version)
                }
                if !package.architecture.isEmpty {
                    Text(package.architecture)
                }
                if !package.section.isEmpty {
                    Text(package.section)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

private struct RepoPackageView: View {
    @ObservedObject private var store = RepoStore.shared

    let package: RepoPackage
    let onPackageReady: (URL) -> Void

    var body: some View {
        Form {
            Section {
                detailRow(NSLocalizedString("Version", comment: ""), package.version)
                detailRow(NSLocalizedString("Architecture", comment: ""), package.architecture)
                detailRow(NSLocalizedString("Author", comment: ""), package.author)
                detailRow(NSLocalizedString("Identifier", comment: ""), package.identifier)
                if let size = package.size {
                    detailRow(
                        NSLocalizedString("Download Size", comment: ""),
                        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                    )
                }
            }

            if !package.packageDescription.isEmpty {
                Section(header: Text(NSLocalizedString("Description", comment: ""))) {
                    Text(package.packageDescription)
                }
            }

            Section {
                Button {
                    store.download(package) { url in
                        guard let url else { return }
                        onPackageReady(url)
                    }
                } label: {
                    HStack {
                        Label(NSLocalizedString("Download and Inject", comment: ""), systemImage: "arrow.down.circle")
                        Spacer()
                        if store.downloadingPackageID == package.id {
                            ProgressView()
                        }
                    }
                }
                .disabled(store.downloadingPackageID != nil)
            } footer: {
                Text(NSLocalizedString("After downloading, select the app that should receive this plug-in.", comment: ""))
            }
        }
        .navigationTitle(package.name)
        .navigationBarTitleDisplayMode(.inline)
        .repoErrorAlert(store: store)
    }

    @ViewBuilder
    private func detailRow(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

private struct RepoSourcesView: View {
    @ObservedObject private var store = RepoStore.shared
    @State private var isAddingSource = false

    var body: some View {
        List {
            ForEach(store.sources) { source in
                Button {
                    store.refresh(source)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.name)
                                .foregroundColor(.primary)
                            Text(source.urlString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if store.loadingSourceIDs.contains(source.id) {
                            ProgressView()
                        } else {
                            Text("\(store.packagesBySource[source.id]?.count ?? 0)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .onDelete(perform: store.removeSources)
        }
        .listStyle(.insetGrouped)
        .navigationTitle(NSLocalizedString("Sources", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isAddingSource = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(NSLocalizedString("Add Source", comment: ""))
            }
        }
        .sheet(isPresented: $isAddingSource) {
            AddRepoSourceView()
        }
        .repoErrorAlert(store: store)
    }
}

private struct AddRepoSourceView: View {
    @ObservedObject private var store = RepoStore.shared
    @Environment(\.presentationMode) private var presentationMode

    @State private var name = ""
    @State private var urlString = "https://"

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField(NSLocalizedString("Source Name", comment: ""), text: $name)
                    TextField(NSLocalizedString("Repository URL", comment: ""), text: $urlString)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } footer: {
                    Text(NSLocalizedString("Enter the root URL of a Sileo or Cydia repository that provides a Packages index.", comment: ""))
                }
            }
            .navigationTitle(NSLocalizedString("Add Source", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(NSLocalizedString("Cancel", comment: "")) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("Add", comment: "")) {
                        do {
                            try store.addSource(name: name, urlString: urlString)
                            presentationMode.wrappedValue.dismiss()
                        } catch {
                            store.errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
        .repoErrorAlert(store: store)
    }
}

private extension View {
    @ViewBuilder
    func repoSearchable(text: Binding<String>) -> some View {
        if #available(iOS 15, *) {
            searchable(text: text, prompt: NSLocalizedString("Search Packages", comment: ""))
        } else {
            self
        }
    }

    func repoErrorAlert(store: RepoStore) -> some View {
        alert(isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Alert(
                    title: Text(NSLocalizedString("Error", comment: "")),
                    message: Text(store.errorMessage ?? ""),
                    dismissButton: .cancel(Text(NSLocalizedString("OK", comment: "")), action: {
                        store.errorMessage = nil
                    })
                )
            }
    }
}
