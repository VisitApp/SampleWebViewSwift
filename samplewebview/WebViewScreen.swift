//
//  WebViewScreen.swift
//  samplewebview
//

import SwiftUI

struct WebViewScreen: View {

    @StateObject private var model: WebViewModel
    private let url: URL

    init(url: URL) {
        self.url = url
        _model = StateObject(wrappedValue: WebViewModel(url: url))
    }

    var body: some View {
        ZStack(alignment: .top) {
            WebViewRepresentable(webView: model.webView)
                .opacity(model.errorMessage == nil ? 1 : 0)
                .accessibilityLabel("Web content")

            if model.isLoading, model.progress < 1 {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .accessibilityLabel("Loading web page")
            }

            if let errorMessage = model.errorMessage {
                errorView(message: errorMessage)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(url.host ?? "Web")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reload", systemImage: "arrow.clockwise") {
                    model.reload()
                }
            }
        }
        .alert(
            "Location Access Needed",
            isPresented: $model.isShowingLocationSettingsPrompt
        ) {
            Button("Open Settings") { model.openSystemLocationSettings() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("To use your current location, allow location access for this app in Settings.")
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Couldn't load the page")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                model.load()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if canImport(UIKit)
        .background(Color(.systemBackground))
        #else
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
    }
}

#Preview {
    WebViewScreen(url: AppLinks.sso)
}
