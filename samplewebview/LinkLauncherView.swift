//
//  LinkLauncherView.swift
//  samplewebview
//
//  Entry screen: paste or type any link and open it in the WebView. Links are
//  remembered between launches, so a refreshed SSO token never requires a rebuild.
//

import SwiftUI

struct LinkLauncherView: View {

    @StateObject private var store = LinkStore()
    @State private var linkText = ""
    @State private var destination: URL?

    private var parsedLink: URL? { AppLinks.parse(linkText) }

    private var isInvalid: Bool {
        !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedLink == nil
    }

    var body: some View {
        NavigationStack {
            List {
                linkEntrySection
                recentsSection
                shortcutSection
            }
            .navigationTitle("Open Link")
            .navigationDestination(item: $destination) { url in
                WebViewScreen(url: url)
            }
        }
    }

    // MARK: - Sections

    private var linkEntrySection: some View {
        Section {
            TextField("https://example.com/...", text: $linkText, axis: .vertical)
                .lineLimit(1...6)
                .font(.callout)
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if canImport(UIKit)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit(open)
                .accessibilityLabel("Web link")

            HStack {
                PasteButton(payloadType: String.self) { items in
                    guard let pasted = items.first else { return }
                    linkText = pasted
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)

                Spacer()

                if !linkText.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") {
                        linkText = ""
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the link field")
                }
            }

            Button(action: open) {
                Text("Open in WebView")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(parsedLink == nil)
        } header: {
            Text("Web Link")
        } footer: {
            if isInvalid {
                Text("Enter a valid http or https link.")
                    .foregroundStyle(.red)
            } else {
                Text("Paste a full link. Line breaks from copied tokens are removed automatically.")
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        if !store.recents.isEmpty {
            Section {
                ForEach(store.recents, id: \.self) { url in
                    Button {
                        open(url)
                    } label: {
                        LinkRow(url: url)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: store.remove(atOffsets:))
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    Button("Clear All") { store.clear() }
                        .font(.caption)
                        .textCase(nil)
                }
            } footer: {
                Text("Swipe a link to delete it.")
            }
        }
    }

    private var shortcutSection: some View {
        Section("Bundled Link") {
            Button {
                linkText = AppLinks.ssoURLString
            } label: {
                LinkRow(url: AppLinks.sso, title: "Visit Health SSO (NIVA_BUPA)")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func open() {
        guard let url = parsedLink else { return }
        open(url)
    }

    private func open(_ url: URL) {
        store.remember(url)
        destination = url
    }
}

/// Compact two-line summary of a long link.
private struct LinkRow: View {
    let url: URL
    var title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title ?? (url.host ?? url.absoluteString))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var detail: String {
        let path = url.path.isEmpty ? "/" : url.path
        guard let query = url.query, !query.isEmpty else { return path }
        return "\(path)?\(query)"
    }
}

#Preview {
    LinkLauncherView()
}
