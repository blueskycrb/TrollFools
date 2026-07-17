//
//  OptionView.swift
//  TrollFools
//
//  Created by Lessica on 2024/7/19.
//

import Foundation
import SwiftUI
import UIKit

struct OptionView: View {
    let app: App

    @Environment(\.verticalSizeClass) var verticalSizeClass

    @State var isImporterPresented = false
    @State var isImporterSelected = false

    @State var isWarningPresented = false
    @State var temporaryResult: Result<[URL], any Error>?

    @State var isSettingsPresented = false
    @State var importerResult: Result<[URL], any Error>?

    @State var isDownloadSheetPresented = false

    @State var numberOfPlugIns: Int = 0

    @AppStorage("isWarningHidden")
    var isWarningHidden: Bool = false

    init(_ app: App) {
        self.app = app
    }

    var body: some View {
        if #available(iOS 15, *) {
            wrappedContent
                .alert(
                    NSLocalizedString("Notice", comment: ""),
                    isPresented: $isWarningPresented,
                    presenting: temporaryResult
                ) { result in
                    Button {
                        importerResult = result
                        isImporterSelected = true
                    } label: {
                        Text(NSLocalizedString("Continue", comment: ""))
                    }
                    Button(role: .destructive) {
                        importerResult = result
                        isImporterSelected = true
                        isWarningHidden = true
                    } label: {
                        Text(NSLocalizedString("Continue and Don’t Show Again", comment: ""))
                    }
                    Button(role: .cancel) {
                        temporaryResult = nil
                        isWarningPresented = false
                    } label: {
                        Text(NSLocalizedString("Cancel", comment: ""))
                    }
                } message: {
                    if case let .success(urls) = $0 {
                        Text(Self.warningMessage(urls))
                    }
                }
        } else {
            wrappedContent
        }
    }

    var wrappedContent: some View {
        content.toolbar { toolbarContent }
    }

    var content: some View {
        VStack(spacing: 80) {
            HStack {
                Spacer()

                Button {
                    isImporterPresented = true
                } label: {
                    OptionCell(option: .attach, detachCount: 0)
                }
                .accessibilityLabel(NSLocalizedString("Inject", comment: ""))

                Spacer()

                NavigationLink {
                    EjectListView(app)
                } label: {
                    OptionCell(option: .detach, detachCount: numberOfPlugIns)
                }
                .accessibilityLabel(
                    numberOfPlugIns == 0
                        ? NSLocalizedString("Manage", comment: "")
                        : String(format: NSLocalizedString("Manage %d Plug-Ins", comment: ""), numberOfPlugIns)
                )

                Spacer()
            }

            Button {
                isDownloadSheetPresented = true
            } label: {
                Label(
                    NSLocalizedString("Download and Inject", comment: ""),
                    systemImage: "link.badge.plus"
                )
            }

            if verticalSizeClass == .regular {
                Button {
                    isSettingsPresented = true
                } label: {
                    Label(NSLocalizedString("Advanced Settings", comment: ""),
                          systemImage: "gear")
                }
            }
        }
        .padding()
        .navigationTitle(app.name)
        .background(Group {
            NavigationLink(isActive: $isImporterSelected) {
                if let result = importerResult {
                    switch result {
                    case let .success(urls):
                        InjectView(app, urlList: urls
                            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }))
                    case let .failure(error):
                        FailureView(
                            title: NSLocalizedString("Error", comment: ""),
                            error: error
                        )
                    }
                }
            } label: { }
        })
        .onAppear {
            recalculatePlugInCount()
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [
                .init(filenameExtension: "dylib")!,
                .init(filenameExtension: "deb")!,
                .bundle,
                .framework,
                .package,
                .zip,
            ],
            allowsMultipleSelection: true
        ) {
            result in
            switch result {
            case let .success(theSuccess):
                if #available(iOS 15, *) {
                    if !isWarningHidden && theSuccess.contains(where: { $0.pathExtension.lowercased() == "deb" }) {
                        temporaryResult = result
                        isWarningPresented = true
                        return
                    }
                }
                fallthrough
            case .failure:
                importerResult = result
                isImporterSelected = true
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            if #available(iOS 16, *) {
                SettingsView(app)
                    .presentationDetents([.medium, .large])
            } else {
                SettingsView(app)
            }
        }
        .sheet(isPresented: $isDownloadSheetPresented) {
            PluginDownloadSheet { result in
                handleImportResult(result)
            }
        }
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if verticalSizeClass == .compact {
                Button {
                    isSettingsPresented = true
                } label: {
                    Label(NSLocalizedString("Advanced Settings", comment: ""),
                          systemImage: "gear")
                }
            }
        }
    }

    static func warningMessage(_ urls: [URL]) -> String {
        guard let firstDylibName = urls.first(where: { $0.pathExtension.lowercased() == "deb" })?.lastPathComponent else {
            fatalError("No debian package found.")
        }
        return String(format: NSLocalizedString("You’ve selected at least one Debian Package “%@”. We’re here to remind you that it will not work as it was in a jailbroken environment. Please make sure you know what you’re doing.", comment: ""), firstDylibName)
    }

    private func recalculatePlugInCount() {
        var urls = [URL]()
        urls += InjectorV3.main.injectedAssetURLsInBundle(app.url)
        let enabledNames = urls.map { $0.lastPathComponent }
        urls += InjectorV3.main.persistedAssetURLs(bid: app.bid)
            .filter { !enabledNames.contains($0.lastPathComponent) }
        numberOfPlugIns = urls.count
    }

    private func handleImportResult(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            if #available(iOS 15, *), !isWarningHidden,
               urls.contains(where: { $0.pathExtension.lowercased() == "deb" }) {
                temporaryResult = result
                isWarningPresented = true
                return
            }
            importerResult = result
            isImporterSelected = true
        case .failure:
            importerResult = result
            isImporterSelected = true
        }
    }
}

private struct PluginDownloadSheet: View {
    @Environment(\.presentationMode) private var presentationMode

    @State private var urlText: String
    @State private var isDownloading = false
    @State private var errorMessage: String?

    let completion: (Result<[URL], any Error>) -> Void

    init(completion: @escaping (Result<[URL], any Error>) -> Void) {
        self.completion = completion
        _urlText = State(initialValue: UIPasteboard.general.string ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField(
                        NSLocalizedString("Plugin URL", comment: ""),
                        text: $urlText
                    )
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                } footer: {
                    Text(NSLocalizedString(
                        "Paste a direct link to a .dylib, .deb, .zip, .framework, or .bundle file.",
                        comment: ""
                    ))
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("Download and Inject", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(NSLocalizedString("Cancel", comment: "")) {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(isDownloading)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        download()
                    } label: {
                        if isDownloading {
                            ProgressView()
                        } else {
                            Text(NSLocalizedString("Download", comment: ""))
                        }
                    }
                    .disabled(isDownloading || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func download() {
        errorMessage = nil
        let trimmedURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            errorMessage = PluginDownloadError.invalidURL.localizedDescription
            return
        }

        isDownloading = true
        URLSession.shared.downloadTask(with: url) { localURL, response, error in
            let result: Result<[URL], any Error>
            do {
                if let error {
                    throw error
                }
                guard let localURL else {
                    throw PluginDownloadError.emptyResponse
                }
                if let httpResponse = response as? HTTPURLResponse,
                   !(200 ... 299).contains(httpResponse.statusCode) {
                    throw PluginDownloadError.httpStatus(httpResponse.statusCode)
                }

                let fileName = try Self.fileName(
                    response: response,
                    fallbackURL: url,
                    localURL: localURL
                )
                let downloadDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TrollFools-Downloads", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: downloadDirectory,
                    withIntermediateDirectories: true
                )
                let destination = downloadDirectory
                    .appendingPathComponent("Downloaded-\(UUID().uuidString)-\(fileName)")
                try FileManager.default.copyItem(at: localURL, to: destination)
                result = .success([destination])
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                isDownloading = false
                switch result {
                case .success:
                    presentationMode.wrappedValue.dismiss()
                    DispatchQueue.main.async {
                        completion(result)
                    }
                case let .failure(error):
                    errorMessage = error.localizedDescription
                }
            }
        }.resume()
    }

    private static func fileName(
        response: URLResponse?,
        fallbackURL: URL,
        localURL: URL
    ) throws -> String {
        let supportedExtensions: Set<String> = ["dylib", "deb", "zip", "framework", "bundle"]
        let candidates = [
            response?.suggestedFilename,
            response?.url?.lastPathComponent,
            fallbackURL.lastPathComponent,
        ].compactMap { $0 }

        if let candidate = candidates.first(where: {
            supportedExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
        }) {
            return URL(fileURLWithPath: candidate).lastPathComponent
        }

        let mimeType = response?.mimeType?.lowercased()
        let mimeExtension: String?
        switch mimeType {
        case "application/zip", "application/x-zip-compressed":
            mimeExtension = "zip"
        case "application/vnd.debian.binary-package", "application/x-debian-package":
            mimeExtension = "deb"
        default:
            mimeExtension = nil
        }

        if let candidate = candidates.first, let mimeExtension {
            return "\(URL(fileURLWithPath: candidate).deletingPathExtension().lastPathComponent).\(mimeExtension)"
        }

        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }
        let magic = [UInt8](fileHandle.readData(ofLength: 8))
        let machOMagics: [[UInt8]] = [
            [0xFE, 0xED, 0xFA, 0xCE],
            [0xCE, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCF],
            [0xCF, 0xFA, 0xED, 0xFE],
            [0xCA, 0xFE, 0xBA, 0xBE],
        ]
        let detectedExtension: String?
        if magic.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            detectedExtension = "zip"
        } else if magic.starts(with: Array("!<arch>\n".utf8)) {
            detectedExtension = "deb"
        } else if machOMagics.contains(where: { magic.starts(with: $0) }) {
            detectedExtension = "dylib"
        } else {
            detectedExtension = nil
        }

        if let candidate = candidates.first, let detectedExtension {
            let baseName = URL(fileURLWithPath: candidate)
                .deletingPathExtension()
                .lastPathComponent
            return "\(baseName).\(detectedExtension)"
        }

        throw PluginDownloadError.unsupportedFileType
    }
}

private enum PluginDownloadError: LocalizedError {
    case invalidURL
    case emptyResponse
    case httpStatus(Int)
    case unsupportedFileType

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            NSLocalizedString("Please enter a valid HTTP or HTTPS URL.", comment: "")
        case .emptyResponse:
            NSLocalizedString("The download returned no file.", comment: "")
        case let .httpStatus(status):
            String(format: NSLocalizedString("Download failed with HTTP status %d.", comment: ""), status)
        case .unsupportedFileType:
            NSLocalizedString("The downloaded file is not a supported plug-in format.", comment: "")
        }
    }
}
