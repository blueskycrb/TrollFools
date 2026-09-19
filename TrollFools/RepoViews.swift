//
//  RepoViews.swift
//  TrollFools
//

import Combine
import SwiftUI
import UIKit

private final class RepoPackagesViewModel: ObservableObject {
    @Published var packages = [RepoPackage]()
    @Published var isLoading = false
    @Published var error: Error?

    let source: RepoSource
    private var hasLoaded = false

    init(source: RepoSource) {
        self.source = source
    }

    func load(force: Bool = false) {
        guard !isLoading, !hasLoaded || force else {
            return
        }

        isLoading = true
        error = nil
        RepoSourceService.fetchPackages(from: source) { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            self.hasLoaded = true
            switch result {
            case let .success(packages):
                self.packages = packages
            case let .failure(error):
                self.error = error
            }
        }
    }
}

struct RepoSourcesView: View {
    @ObservedObject private var store = RepoSourceStore.shared
    @State private var isAddSourcePresented = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(store.sources) { source in
                        NavigationLink {
                            RepoPackagesView(source: source)
                        } label: {
                            HStack(spacing: 12) {
                                RepoRemoteImage(urlString: source.iconURL)
                                    .frame(width: 42, height: 42)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.name)
                                        .font(.headline)
                                    Text(source.url)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete(perform: store.remove)
                } header: {
                    Text(NSLocalizedString("Plugin Sources", comment: ""))
                } footer: {
                    Text(NSLocalizedString("Sources use the standard Sileo/APT Packages format. Only packages compatible with TrollFools are shown.", comment: ""))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(NSLocalizedString("Plugin Sources", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Done", comment: "")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isAddSourcePresented = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(NSLocalizedString("Add Source", comment: ""))
                }
            }
            .sheet(isPresented: $isAddSourcePresented) {
                AddRepoSourceView()
            }
        }
    }

    @Environment(\.presentationMode) private var presentationMode

    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }
}

private struct AddRepoSourceView: View {
    @ObservedObject private var store = RepoSourceStore.shared
    @Environment(\.presentationMode) private var presentationMode

    @State private var sourceURL = ""
    @State private var error: Error?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField(
                        "https://example.com/repo/",
                        text: $sourceURL
                    )
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                } header: {
                    Text(NSLocalizedString("Source URL", comment: ""))
                } footer: {
                    Text(NSLocalizedString("Enter the root URL of a Sileo/APT source.", comment: ""))
                }
            }
            .navigationTitle(NSLocalizedString("Add Source", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Cancel", comment: "")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Add", comment: "")) {
                        addSource()
                    }
                    .disabled(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert(
                NSLocalizedString("Unable to Add Source", comment: ""),
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                ),
                presenting: error
            ) { _ in
                Button(NSLocalizedString("OK", comment: ""), role: .cancel) {}
            } message: {
                Text($0.localizedDescription)
            }
        }
    }

    private func addSource() {
        do {
            try store.add(urlString: sourceURL)
            dismiss()
        } catch {
            self.error = error
        }

    }

    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }
}

private struct RepoPackagesView: View {
    let source: RepoSource

    @StateObject private var viewModel: RepoPackagesViewModel
    @State private var searchText = ""
    @State private var selectedPackage: RepoPackage?

    init(source: RepoSource) {
        self.source = source
        _viewModel = StateObject(wrappedValue: RepoPackagesViewModel(source: source))
    }

    private var filteredPackages: [RepoPackage] {
        guard !searchText.isEmpty else {
            return viewModel.packages
        }
        return viewModel.packages.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.identifier.localizedCaseInsensitiveContains(searchText)
                || ($0.author?.localizedCaseInsensitiveContains(searchText) ?? false)
                || ($0.section?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        Group {
            if #available(iOS 15, *) {
                packageList
                    .searchable(text: $searchText, prompt: NSLocalizedString("Search Packages", comment: ""))
            } else {
                VStack(spacing: 0) {
                    TextField(NSLocalizedString("Search Packages", comment: ""), text: $searchText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()
                    packageList
                }
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    viewModel.load(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
                .accessibilityLabel(NSLocalizedString("Refresh", comment: ""))
            }
        }
        .onAppear {
            viewModel.load()
        }
    }

    private var packageList: some View {
        List {
            if viewModel.isLoading && viewModel.packages.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let error = viewModel.error, viewModel.packages.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(NSLocalizedString("Unable to Load Source", comment: ""))
                            .font(.headline)
                        Text(error.localizedDescription)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Button(NSLocalizedString("Try Again", comment: "")) {
                            viewModel.load(force: true)
                        }
                    }
                    .padding(.vertical, 8)
                }
            } else if filteredPackages.isEmpty {
                Text(NSLocalizedString("No Packages", comment: ""))
                    .foregroundColor(.secondary)
            } else {
                ForEach(sectionNames, id: \.self) { section in
                    Section {
                        ForEach(filteredPackages.filter { ($0.section ?? NSLocalizedString("Other", comment: "")) == section }) { package in
                            Button {
                                selectedPackage = package
                            } label: {
                                RepoPackageRow(package: package)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    } header: {
                        Text(section)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $selectedPackage) { package in
            RepoPackageDetailView(package: package)
        }
        .modifier(RepoRefreshModifier(action: {
            viewModel.load(force: true)
        }))
    }

    private var sectionNames: [String] {
        let other = NSLocalizedString("Other", comment: "")
        return Set(filteredPackages.map { $0.section ?? other })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

private struct RepoPackageRow: View {
    let package: RepoPackage

    var body: some View {
        HStack(spacing: 12) {
            RepoRemoteImage(urlString: package.iconURL)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(package.name)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(package.version)
                    Text(package.architecture)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                if let description = package.description?.split(separator: "\n").first, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct RepoPackageDetailView: View {
    let package: RepoPackage

    @Environment(\.presentationMode) private var presentationMode
    @State private var isDownloading = false
    @State private var error: Error?
    @State private var selectorURL: URLIdentifiable?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        RepoRemoteImage(urlString: package.iconURL)
                            .frame(width: 72, height: 72)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(package.name)
                                .font(.title3)
                                .fontWeight(.semibold)
                            Text(package.version)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text(package.architecture)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    metadata

                    if let description = package.description, !description.isEmpty {
                        Text(description)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        downloadAndSelectApp()
                    } label: {
                        HStack {
                            Spacer()
                            if isDownloading {
                                ProgressView()
                            } else {
                                Label(
                                    NSLocalizedString("Download and Select App", comment: ""),
                                    systemImage: "arrow.down.circle"
                                )
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .disabled(isDownloading)
                }
                .padding()
            }
            .navigationTitle(NSLocalizedString("Package Details", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Done", comment: "")) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .alert(
                NSLocalizedString("Download Failed", comment: ""),
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                ),
                presenting: error
            ) { _ in
                Button(NSLocalizedString("OK", comment: ""), role: .cancel) {}
            } message: {
                Text($0.localizedDescription)
            }
            .sheet(item: $selectorURL) { url in
                AppListView()
                    .environmentObject(AppListModel(selectorURL: url.url))
            }
        }
    }

    @ViewBuilder
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let author = package.author, !author.isEmpty {
                Label(author, systemImage: "person")
            }
            if let section = package.section, !section.isEmpty {
                Label(section, systemImage: "folder")
            }
            if let size = package.size {
                Label(Self.byteString(size), systemImage: "internaldrive")
            }
        }
        .font(.footnote)
        .foregroundColor(.secondary)
    }

    private func downloadAndSelectApp() {
        isDownloading = true
        error = nil
        RepoPackageDownloader.shared.download(package) { result in
            isDownloading = false
            switch result {
            case let .success(url):
                selectorURL = URLIdentifiable(url: url)
            case let .failure(error):
                self.error = error
            }
        }
    }

    private static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct RepoRemoteImage: View {
    let urlString: String?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "shippingbox")
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .foregroundColor(.secondary)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil, let urlString, let url = URL(string: urlString) else {
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = UIImage(data: data) else {
                return
            }
            DispatchQueue.main.async {
                self.image = image
            }
        }.resume()
    }
}

private struct RepoRefreshModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 15, *) {
            content.refreshable {
                action()
            }
        } else {
            content
        }
    }
}
