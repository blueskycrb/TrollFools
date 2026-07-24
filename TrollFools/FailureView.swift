//
//  FailureView.swift
//  TrollFools
//
//  Created by Lessica on 2024/7/19.
//

import SwiftUI

struct FailureView: View {

    let title: String
    let error: Error?
    let onDone: (() -> Void)?

    var logFileURL: URL? {
        (error as? NSError)?.userInfo[NSURLErrorKey] as? URL
    }

    @State private var isLogsPresented = false

    init(title: String, error: Error?, onDone: (() -> Void)? = nil) {
        self.title = title
        self.error = error
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.red)

            Text(title)
                .font(.title)
                .bold()

            if let error = error {
                Text(error.localizedDescription)
                    .font(.title3)
            }

            if logFileURL != nil {
                Button {
                    isLogsPresented = true
                } label: {
                    Label(NSLocalizedString("View Logs", comment: ""),
                          systemImage: "note.text")
                }
            }

            if let onDone = onDone {
                doneButton(onDone)
            }
        }
        .padding()
        .multilineTextAlignment(.center)
        .sheet(isPresented: $isLogsPresented) {
            if let logFileURL = logFileURL {
                LogsView(url: logFileURL)
            }
        }
    }

    @ViewBuilder
    private func doneButton(_ action: @escaping () -> Void) -> some View {
        if #available(iOS 15, *) {
            Button(action: action) {
                Text(NSLocalizedString("Done", comment: ""))
                    .font(.headline)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        } else {
            Button(action: action) {
                Text(NSLocalizedString("Done", comment: ""))
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.top, 8)
        }
    }
}
