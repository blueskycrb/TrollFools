//
//  SourcesView.swift
//  TrollFools
//

import SwiftUI
import UIKit

private enum SourcesAlert: Identifiable {
    case downloadError(String)
    case injectConfirm(String)

    var id: String {
        switch self {
        case .downloadError(let message):
            return "error-" + message
        case .injectConfirm(let message):
            return "inject-" + message
        }
    }
}

struct SourcesView: View {
    var fixedTargetApp: App? = nil

    @ObservedObject private var repoManager = RepoIndexManager.shared

    @State private var isAddSourcePresented = false
    @State private var searchText = ""
    @State private var selectedPackage: RepoPackage?

    @State private var isDownloading = false
    @State private var downloadedFileURL: URL?
    @State private var selectorOpenedURL: URLIdentifiable?
    @State private var injectNavigationActive = false
    @State private var injectURLs: [URL] = []
    @State private var activeAlert: SourcesAlert?

    private var filteredPackages: [RepoPackage] {
        let base = repoManager.allPackages.filter { $0.isInjectableCandidate }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return base }
        return base.filter {
            $0.displayName.localizedCaseInsensitiveContains(keyword)
                || $0.package.localizedCaseInsensitiveContains(keyword)
                || ($0.description?.localizedCaseInsensitiveContains(keyword) ?? false)
                || $0.sourceName.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        navigationContainer
    }

    @ViewBuilder
    private var navigationContainer: some View {
        if fixedTargetApp == nil {
            NavigationView {
                rootList
            }
            .navigationViewStyle(.stack)
        } else {
            rootList
        }
    }

    private var rootList: some View {
        listContent
            .navigationTitle(NSLocalizedString("Sources", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $isAddSourcePresented) {
                AddSourceView { name, url in
                    try repoManager.addSource(name: name, urlString: url)
                    if let added = repoManager.sources.last {
                        repoManager.refresh(source: added)
                    }
                }
            }
            .background(
                NavigationLink(
                    destination: Group {
                        if let app = fixedTargetApp, !injectURLs.isEmpty {
                            InjectView(app, urlList: injectURLs)
                        } else {
                            EmptyView()
                        }
                    },
                    isActive: $injectNavigationActive
                ) { EmptyView() }
                .hidden()
            )
            .sheet(item: $selectorOpenedURL) { wrapper in
                AppListView()
                    .environmentObject(AppListModel(selectorURL: wrapper.url))
            }
            .alert(item: $activeAlert) { alert -> Alert in
                switch alert {
                case let .downloadError(message):
                    return Alert(
                        title: Text(NSLocalizedString("Error", comment: "")),
                        message: Text(message),
                        dismissButton: .default(Text("OK"))
                    )
                case let .injectConfirm(message):
                    return Alert(
                        title: Text(NSLocalizedString("Download Completed", comment: "")),
                        message: Text(message),
                        primaryButton: .default(Text(NSLocalizedString("Inject", comment: ""))) {
                            handleInjectConfirmed()
                        },
                        secondaryButton: .cancel(Text(NSLocalizedString("Cancel", comment: ""))) {
                            downloadedFileURL = nil
                        }
                    )
                }
            }
            .sheet(item: $selectedPackage) { package in
                NavigationView {
                    PackageDetailView(
                        package: package,
                        isDownloading: $isDownloading,
                        onDownload: { download(package) }
                    )
                }
                .navigationViewStyle(.stack)
            }
    }

    private var injectConfirmMessage: String {
        let fileName = downloadedFileURL?.lastPathComponent ?? ""
        if let app = fixedTargetApp {
            return String(
                format: NSLocalizedString("Download finished: %@. Inject into %@ now?", comment: ""),
                fileName,
                app.name
            )
        }
        return String(
            format: NSLocalizedString("Download finished: %@. Choose an app to inject?", comment: ""),
            fileName
        )
    }

    private var listContent: some View {
        List {
            sourcesSection
            packagesSection
        }
        .listStyle(.insetGrouped)
        .modifier(SourcesSearchModifier(searchText: $searchText))
        .onAppear {
            let needsRefresh = repoManager.sources.contains {
                $0.isEnabled && $0.lastRefreshedAt == nil && $0.packageCount == 0
            }
            if needsRefresh {
                repoManager.refreshAll()
            }
        }
    }

    private var sourcesSection: some View {
        Section(header: Text(NSLocalizedString("Repositories", comment: ""))) {
            if repoManager.sources.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("No Sources", comment: ""))
                        .font(.headline)
                    Text(NSLocalizedString("Add a Sileo/APT source URL to browse downloadable plug-ins (.deb) and inject them into apps.", comment: ""))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(repoManager.sources) { source in
                    sourceRow(source)
                }
                .onDelete(perform: repoManager.removeSources)
            }

            Button {
                isAddSourcePresented = true
            } label: {
                Label(NSLocalizedString("Add Source", comment: ""), systemImage: "plus.circle.fill")
            }
        }
    }

    private func sourceRow(_ source: RepoSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(Font.body.weight(.semibold))
                        .foregroundColor(source.isEnabled ? .primary : .secondary)
                    Text(source.displayHost)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if repoManager.refreshingSourceIDs.contains(source.id) {
                    ProgressView()
                } else {
                    Text("\(source.packageCount)")
                        .font(Font.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            if let error = source.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            } else if let refreshed = source.lastRefreshedAt {
                Text(String(
                    format: NSLocalizedString("Updated %@", comment: ""),
                    Self.dateFormatter.string(from: refreshed)
                ))
                .font(.caption2)
                .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                repoManager.refresh(source: source)
            } label: {
                Label(NSLocalizedString("Refresh", comment: ""), systemImage: "arrow.clockwise")
            }
            Button {
                repoManager.toggleSource(source)
            } label: {
                Label(
                    source.isEnabled
                        ? NSLocalizedString("Disable", comment: "")
                        : NSLocalizedString("Enable", comment: ""),
                    systemImage: source.isEnabled ? "pause.circle" : "play.circle"
                )
            }
            Button {
                repoManager.removeSource(source)
            } label: {
                Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
            }
        }
    }

    private var packagesSection: some View {
        Section(header: Text(packageSectionTitle)) {
            if repoManager.sources.isEmpty {
                EmptyView()
            } else if filteredPackages.isEmpty {
                Text(NSLocalizedString("No injectable packages yet. Pull to refresh or add another source.", comment: ""))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(filteredPackages) { package in
                    Button {
                        selectedPackage = package
                    } label: {
                        packageRow(package)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    private var packageSectionTitle: String {
        String(format: NSLocalizedString("Packages (%d)", comment: ""), filteredPackages.count)
    }

    private func packageRow(_ package: RepoPackage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(package.displayName)
                    .font(Font.body.weight(.medium))
                    .foregroundColor(.primary)
                Spacer()
                Text(package.version)
                    .font(Font.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Text(package.package)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(package.sourceName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let section = package.section, !section.isEmpty {
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(section)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let size = package.formattedSize {
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(size)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 12) {
                if isDownloading || repoManager.isRefreshingAll {
                    ProgressView()
                }
                Button {
                    repoManager.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(repoManager.sources.isEmpty || repoManager.isRefreshingAll || isDownloading)

                Button {
                    isAddSourcePresented = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    private func download(_ package: RepoPackage) {
        guard !isDownloading else { return }
        isDownloading = true
        repoManager.downloadPackage(package) { result in
            isDownloading = false
            selectedPackage = nil
            switch result {
            case let .success(url):
                downloadedFileURL = url
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    activeAlert = .injectConfirm(injectConfirmMessage)
                }
            case let .failure(error):
                activeAlert = .downloadError(error.localizedDescription)
            }
        }
    }

    private func handleInjectConfirmed() {
        guard let url = downloadedFileURL else { return }
        if fixedTargetApp != nil {
            injectURLs = [url]
            injectNavigationActive = true
        } else {
            selectorOpenedURL = URLIdentifiable(url: url)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct SourcesSearchModifier: ViewModifier {
    @Binding var searchText: String

    func body(content: Content) -> some View {
        if #available(iOS 15, *) {
            content.searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(NSLocalizedString("Search Packages", comment: ""))
            )
        } else {
            content
        }
    }
}

struct AddSourceView: View {
    @Environment(\.presentationMode) private var presentationMode

    @State private var name: String = ""
    @State private var urlText: String = ""
    @State private var errorMessage: String?

    let onAdd: (String, String) throws -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text(NSLocalizedString("Source", comment: "")),
                    footer: Text(NSLocalizedString("Enter a Sileo/APT repository URL, for example https://repo.example.com/", comment: ""))
                ) {
                    TextField(NSLocalizedString("Name (Optional)", comment: ""), text: $name)
                    TextField(NSLocalizedString("Source URL", comment: ""), text: $urlText)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
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
                            try onAdd(name, urlText)
                            presentationMode.wrappedValue.dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if urlText.isEmpty, let paste = UIPasteboard.general.string, paste.contains("://") {
                    urlText = paste.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct PackageDetailView: View {
    let package: RepoPackage
    @Binding var isDownloading: Bool
    let onDownload: () -> Void

    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        List {
            Section {
                PackageInfoRow(title: NSLocalizedString("Name", comment: ""), value: package.displayName)
                PackageInfoRow(title: NSLocalizedString("Package", comment: ""), value: package.package)
                PackageInfoRow(title: NSLocalizedString("Version", comment: ""), value: package.version)
                if let section = package.section {
                    PackageInfoRow(title: NSLocalizedString("Section", comment: ""), value: section)
                }
                if let author = package.author {
                    PackageInfoRow(title: NSLocalizedString("Author", comment: ""), value: author)
                }
                if let arch = package.architecture {
                    PackageInfoRow(title: NSLocalizedString("Architecture", comment: ""), value: arch)
                }
                if let size = package.formattedSize {
                    PackageInfoRow(title: NSLocalizedString("Size", comment: ""), value: size)
                }
                PackageInfoRow(title: NSLocalizedString("Source", comment: ""), value: package.sourceName)
            }

            if let description = package.description, !description.isEmpty {
                Section(header: Text(NSLocalizedString("Description", comment: ""))) {
                    Text(description)
                }
            }

            Section(footer: Text(NSLocalizedString("After download, you can inject the plug-in into an app or cancel.", comment: ""))) {
                Button {
                    onDownload()
                } label: {
                    HStack {
                        Spacer()
                        if isDownloading {
                            ProgressView()
                        } else {
                            Text(NSLocalizedString("Download", comment: ""))
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(isDownloading)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(package.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(NSLocalizedString("Close", comment: "")) {
                    presentationMode.wrappedValue.dismiss()
                }
                .disabled(isDownloading)
            }
        }
    }
}

private struct PackageInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body)
                .foregroundColor(.primary)
        }
        .padding(.vertical, 2)
    }
}
