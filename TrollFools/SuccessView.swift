//
//  SuccessView.swift
//  TrollFools
//
//  Created by Lessica on 2024/7/19.
//

import SwiftUI

struct SuccessView: View {

    let title: String
    let subtitle: String?
    let logFileURL: URL?
    var onDone: (() -> Void)? = nil

    @State private var isLogsPresented = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text(title)
                .font(.title)
                .bold()

            if let subtitle {
                Text(subtitle)
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

            if let onDone {
                if #available(iOS 15, *) {
                    Button(action: onDone) {
                        Text(NSLocalizedString("Done", comment: ""))
                            .font(.headline)
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                } else {
                    Button(action: onDone) {
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
        .padding()
        .multilineTextAlignment(.center)
        .sheet(isPresented: $isLogsPresented) {
            if let logFileURL {
                LogsView(url: logFileURL)
            }
        }
    }
}

#Preview {
    SuccessView(
        title: "Hello, World!",
        subtitle: nil,
        logFileURL: nil,
        onDone: {}
    )
}
