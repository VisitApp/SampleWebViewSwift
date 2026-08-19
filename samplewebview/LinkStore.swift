//
//  LinkStore.swift
//  samplewebview
//
//  Persists recently opened links so a new token can be reused across launches
//  without touching the source.
//

import Combine
import Foundation

@MainActor
final class LinkStore: ObservableObject {

    @Published private(set) var recents: [URL] = []

    private let defaults: UserDefaults
    private let storageKey = "recentLinks"
    private let limit = 20

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: storageKey) ?? []
        recents = stored.compactMap(URL.init(string:))
    }

    /// Most recent first, with any earlier copy of the same link removed.
    func remember(_ url: URL) {
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        if recents.count > limit {
            recents.removeLast(recents.count - limit)
        }
        persist()
    }

    func remove(atOffsets offsets: IndexSet) {
        // Descending order so earlier removals don't shift later indices.
        for index in offsets.sorted(by: >) where recents.indices.contains(index) {
            recents.remove(at: index)
        }
        persist()
    }

    func clear() {
        recents.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(recents.map(\.absoluteString), forKey: storageKey)
    }
}
