//
//  WebViewModel.swift
//  samplewebview
//
//  Owns the WKWebView and exposes its loading state to SwiftUI.
//

import Combine
import Foundation
import WebKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WebViewModel: NSObject, ObservableObject {

    @Published private(set) var isLoading = true
    @Published private(set) var progress: Double = 0
    @Published private(set) var errorMessage: String?

    /// Raised when the page needs location but the user has already denied it,
    /// so the system will not prompt again.
    @Published var isShowingLocationSettingsPrompt = false

    let webView: WKWebView
    private let homeURL: URL
    private let geolocation = GeolocationBridge()
    private var progressObservation: NSKeyValueObservation?

    init(url: URL) {
        self.homeURL = url

        let configuration = WKWebViewConfiguration()
        // Persistent data store keeps SSO cookies/session across app launches.
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if canImport(UIKit)
        configuration.allowsInlineMediaPlayback = true
        #endif

        self.webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        geolocation.onPermissionDenied = { [weak self] in
            self?.isShowingLocationSettingsPrompt = true
        }
        geolocation.install(on: webView)

        observeProgress()
        load()
    }

    deinit {
        progressObservation?.invalidate()
    }

    // MARK: - Actions

    func load() {
        errorMessage = nil
        isLoading = true
        webView.load(URLRequest(url: homeURL))
    }

    func reload() {
        errorMessage = nil
        if webView.url == nil {
            load()
        } else {
            webView.reload()
        }
    }

    /// Deep links into the per-app privacy settings so a denied permission can
    /// be re-enabled.
    func openSystemLocationSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        ) else { return }
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: - Private

    private func observeProgress() {
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { webView, _ in
            let value = webView.estimatedProgress
            Task { @MainActor [weak self] in
                self?.progress = value
            }
        }
    }

    /// Filters out errors that are expected during normal navigation
    /// (user-cancelled loads, redirects handled by policy decisions).
    private func isIgnorable(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        // WebKitErrorFrameLoadInterruptedByPolicyChange
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            return true
        }
        return false
    }

    private func openExternally(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - WKNavigationDelegate

extension WebViewModel: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "blob" || scheme == "data" {
            decisionHandler(.allow)
            return
        }

        // tel:, mailto:, upi:, whatsapp: and other app links go to the system handler.
        decisionHandler(.cancel)
        openExternally(url)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        progress = 1
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The content process was jetsammed; recover by reloading.
        reload()
    }

    private func handleFailure(_ error: Error) {
        isLoading = false
        guard !isIgnorable(error) else { return }
        errorMessage = error.localizedDescription
    }
}

// MARK: - WKUIDelegate

extension WebViewModel: WKUIDelegate {

    /// target="_blank" links have no window to open into, so load them inline.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
