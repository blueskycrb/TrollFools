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
        case .downloadError(let message): return "error-" + message
        case .injectConfirm(let message): return "inject-" + message
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
            NavigationView { rootList }
                .navigationViewStyle(.stack)
        } else {
            rootList
        }
    }

    private var rootList: some View {
        listContent
            .navigationTitle(NSLocalizedString("Sources", comment: ""))
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .sheet(isPresented: $isAddSourcePresented) {
                AddSourceView()
            }
            .background(injectionNavigationLink)
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

    private var injectionNavigationLink: some View {
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
    }

    private var listContent: some View {
        List {
            librarySection
            sourcesSection
            packagesSection
        }
        .listStyle(.insetGrouped)
        .modifier(SourcesSearchModifier(searchText: $searchText))
        .onAppear {
            repoManager.reloadLocalPlugins()
            let needsRefresh = repoManager.sources.contains {
                $0.isEnabled && $0.lastRefreshedAt == nil && $0.packageCount == 0
            }
            if needsRefresh { repoManager.refreshAll() }
        }
    }

    private var librarySection: some View {
        Section {
            HStack(spacing: 14) {
                SourceIcon(systemName: "shippingbox.fill", color: .gray)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("All Packages", comment: ""))
                        .font(Font.body.weight(.semibold))
                    Text(NSLocalizedString("Browse packages from all added repositories", comment: ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(filteredPackages.count)")
                    .font(Font.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 3)

            NavigationLink {
                LocalPluginsView(fixedTargetApp: fixedTargetApp)
            } label: {
                HStack(spacing: 14) {
                    SourceIcon(systemName: "arrow.down.circle.fill", color: .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString("Downloaded Plugins", comment: ""))
                            .font(Font.body.weight(.semibold))
                        Text(NSLocalizedString("View, inject, or delete local plug-ins", comment: ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("\(repoManager.localPlugins.count)")
                        .font(Font.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var sourcesSection: some View {
        Section(header: Text(NSLocalizedString("Repositories", comment: ""))) {
            if repoManager.sources.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("No Sources", comment: ""))
                        .font(.headline)
                    Text(NSLocalizedString("Paste one or more Sileo/APT repository URLs. TrollFools will read each repository name automatically.", comment: ""))
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
                Label(NSLocalizedString("Add Sources", comment: ""), systemImage: "plus.circle.fill")
            }
        }
    }

    private func sourceRow(_ source: RepoSource) -> some View {
        HStack(spacing: 14) {
            SourceIcon(systemName: "shippingbox.fill", color: source.isEnabled ? .teal : .gray)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(Font.body.weight(.semibold))
                    .foregroundColor(source.isEnabled ? .primary : .secondary)
                Text(source.urlString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let error = source.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
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
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button { repoManager.refresh(source: source) } label: {
                Label(NSLocalizedString("Refresh", comment: ""), systemImage: "arrow.clockwise")
            }
            Button { repoManager.toggleSource(source) } label: {
                Label(
                    source.isEnabled ? NSLocalizedString("Disable", comment: "") : NSLocalizedString("Enable", comment: ""),
                    systemImage: source.isEnabled ? "pause.circle" : "play.circle"
                )
            }
            Button { repoManager.removeSource(source) } label: {
                Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
            }
        }
    }

    private var packagesSection: some View {
        Section(header: Text(packageSectionTitle)) {
            if repoManager.sources.isEmpty {
                EmptyView()
            } else if filteredPackages.isEmpty {
                Text(NSLocalizedString("No injectable packages yet. Refresh or add another source.", comment: ""))
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
                    Text("•").foregroundColor(.secondary)
                    Text(section).font(.caption2).foregroundColor(.secondary)
                }
                if let size = package.formattedSize {
                    Text("•").foregroundColor(.secondary)
                    Text(size).font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            EditButton()
                .disabled(repoManager.sources.isEmpty)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 12) {
                if isDownloading || repoManager.isRefreshingAll { ProgressView() }
                Button { repoManager.refreshAll() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(repoManager.sources.isEmpty || repoManager.isRefreshingAll || isDownloading)
                Button { isAddSourcePresented = true } label: {
                    Image(systemName: "plus")
                }
            }
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
}

private struct SourceIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(color)
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: 46, height: 46)
    }
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
    @ObservedObject private var repoManager = RepoIndexManager.shared

    @State private var urlText = ""
    @State private var isAdding = false
    @State private var resultMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text(NSLocalizedString("Repository URLs", comment: "")),
                    footer: Text(NSLocalizedString("Paste multiple links separated by new lines, spaces, commas, or semicolons. Repository names are read automatically.", comment: ""))
                ) {
                    ZStack(alignment: .topLeading) {
                        if urlText.isEmpty {
                            Text("https://repo.example.com/\nhttps://example.github.io/repo/")
                                .foregroundColor(Color.secondary.opacity(0.7))
                                .padding(.top, 8)
                                .padding(.leading, 5)
                        }
                        TextEditor(text: $urlText)
                            .frame(minHeight: 150)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }

                if isAdding {
                    Section {
                        HStack {
                            ProgressView()
                            Text(NSLocalizedString("Reading repository names and indexes…", comment: ""))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let resultMessage {
                    Section {
                        Text(resultMessage)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("Add Sources", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(NSLocalizedString("Cancel", comment: "")) {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(isAdding)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("Add", comment: "")) { addSources() }
                        .disabled(isAdding || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if urlText.isEmpty,
                   let paste = UIPasteboard.general.string,
                   paste.contains("://") || paste.contains("apt:") {
                    urlText = paste.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func addSources() {
        isAdding = true
        resultMessage = nil
        repoManager.addSources(from: urlText) { added, skipped, messages in
            isAdding = false
            if skipped == 0, added > 0 {
                presentationMode.wrappedValue.dismiss()
                return
            }
            var result = String(format: NSLocalizedString("Added %d source(s), skipped %d.", comment: ""), added, skipped)
            if !messages.isEmpty {
                result += "\n\n" + messages.prefix(5).joined(separator: "\n")
            }
            resultMessage = result
            if added > 0 { urlText = "" }
        }
    }
}

struct LocalPluginsView: View {
    var fixedTargetApp: App? = nil

    @ObservedObject private var repoManager = RepoIndexManager.shared
    @State private var selectedForInjection: URLIdentifiable?
    @State private var injectURLs: [URL] = []
    @State private var injectNavigationActive = false
    @State private var errorMessage: String?
    @State private var confirmDeleteAll = false

    var body: some View {
        List {
            if repoManager.localPlugins.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("No Downloaded Plugins", comment: ""))
                        .font(.headline)
                    Text(NSLocalizedString("Plug-ins downloaded from repositories will be kept here for later injection or deletion.", comment: ""))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(repoManager.localPlugins) { plugin in
                    Button { inject(plugin.url) } label: {
                        HStack(spacing: 12) {
                            SourceIcon(systemName: "puzzlepiece.extension.fill", color: .indigo)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(plugin.displayName)
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    Text(plugin.formattedSize)
                                    if let date = plugin.modifiedAt {
                                        Text("•")
                                        Text(Self.dateFormatter.string(from: date))
                                    }
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(Color.secondary.opacity(0.6))
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .contextMenu {
                        Button { inject(plugin.url) } label: {
                            Label(NSLocalizedString("Inject", comment: ""), systemImage: "syringe")
                        }
                        Button { delete(plugin) } label: {
                            Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
                        }
                    }
                }
                .onDelete(perform: delete)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(NSLocalizedString("Downloaded Plugins", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !repoManager.localPlugins.isEmpty {
                    Button(NSLocalizedString("Delete All", comment: "")) {
                        confirmDeleteAll = true
                    }
                    .foregroundColor(.red)
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
        .sheet(item: $selectedForInjection) { wrapper in
            AppListView()
                .environmentObject(AppListModel(selectorURL: wrapper.url))
        }
        .alert(isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Alert(
                title: Text(NSLocalizedString("Error", comment: "")),
                message: Text(errorMessage ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
        .actionSheet(isPresented: $confirmDeleteAll) {
            ActionSheet(
                title: Text(NSLocalizedString("Delete All Downloaded Plugins?", comment: "")),
                message: Text(NSLocalizedString("This cannot be undone.", comment: "")),
                buttons: [
                    .destructive(Text(NSLocalizedString("Delete All", comment: ""))) {
                        do { try repoManager.deleteAllLocalPlugins() }
                        catch { errorMessage = error.localizedDescription }
                    },
                    .cancel(),
                ]
            )
        }
        .onAppear { repoManager.reloadLocalPlugins() }
    }

    private func inject(_ url: URL) {
        if fixedTargetApp != nil {
            injectURLs = [url]
            injectNavigationActive = true
        } else {
            selectedForInjection = URLIdentifiable(url: url)
        }
    }

    private func delete(_ plugin: LocalPluginFile) {
        do { try repoManager.deleteLocalPlugin(plugin) }
        catch { errorMessage = error.localizedDescription }
    }

    private func delete(at offsets: IndexSet) {
        do { try repoManager.deleteLocalPlugins(at: offsets) }
        catch { errorMessage = error.localizedDescription }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
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
                if let section = package.section { PackageInfoRow(title: NSLocalizedString("Section", comment: ""), value: section) }
                if let author = package.author { PackageInfoRow(title: NSLocalizedString("Author", comment: ""), value: author) }
                if let arch = package.architecture { PackageInfoRow(title: NSLocalizedString("Architecture", comment: ""), value: arch) }
                if let size = package.formattedSize { PackageInfoRow(title: NSLocalizedString("Size", comment: ""), value: size) }
                PackageInfoRow(title: NSLocalizedString("Source", comment: ""), value: package.sourceName)
            }

            if let description = package.description, !description.isEmpty {
                Section(header: Text(NSLocalizedString("Description", comment: ""))) {
                    Text(description)
                }
            }

            Section(footer: Text(NSLocalizedString("After download, you can inject the plug-in into an app or cancel.", comment: ""))) {
                Button { onDownload() } label: {
                    HStack {
                        Spacer()
                        if isDownloading { ProgressView() }
                        else { Text(NSLocalizedString("Download", comment: "")).fontWeight(.semibold) }
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
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.body).foregroundColor(.primary)
        }
        .padding(.vertical, 2)
    }
}
