//
//  WebViewRepresentable.swift
//  samplewebview
//
//  Bridges a WKWebView instance into SwiftUI. The view is owned by
//  WebViewModel so navigation state survives SwiftUI body re-evaluations.
//

import SwiftUI
import WebKit

struct WebViewRepresentable {
    let webView: WKWebView
}

#if canImport(UIKit)

extension WebViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#elseif canImport(AppKit)

extension WebViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

#endif
