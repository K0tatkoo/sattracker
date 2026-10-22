import OrbitCore
import SwiftUI

/// Every satellite of every category (on or off), searchable by name or
/// catalogue number, and Celestrak's own search for anything else. Picking
/// one flies the globe to it.
struct SearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var search = SearchModel()

    var body: some View {
        NavigationStack {
            List {
                if search.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    suggestions
                } else {
                    results
                }
            }
            .navigationTitle("Find a satellite")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Name or NORAD number")
            .onSubmit(of: .search) { Task { await search.searchOnline(model.tle) } }
            .onChange(of: search.query) { search.clearOnline() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { model.sheet = nil }
                }
            }
            .overlay {
                if search.index.isEmpty && search.loading { ProgressView("Gathering the catalogue…") }
            }
        }
        .presentationDetents([.large])
        .task { await search.loadIndex(model.tle, pinned: model.pinned) }
    }

    @ViewBuilder private var suggestions: some View {
        let recent = model.recent.compactMap { n in search.index.first { $0.norad == n } }
        if !recent.isEmpty {
            Section("Recent") { ForEach(recent) { row($0) } }
        }
        let popular = SearchModel.popular.compactMap { n in search.index.first { $0.norad == n } }
            .filter { item in !recent.contains { $0.norad == item.norad } }
        if !popular.isEmpty {
            Section("Popular") { ForEach(popular) { row($0) } }
        }
    }

    @ViewBuilder private var results: some View {
        let groups = search.matches()
        if groups.isEmpty && search.online == nil && !search.loading {
            Section {
                Text("Nothing in Orbit's categories.").foregroundStyle(.secondary)
            }
        }
        ForEach(groups, id: \.0.id) { category, items in
            Section(category.label) { ForEach(items) { row($0) } }
        }
        Section {
            if let online = search.online {
                if online.isEmpty {
                    Text("Celestrak has nothing more by that name.").foregroundStyle(.secondary)
                } else {
                    ForEach(online) { row($0) }
                }
            } else if search.searchingOnline {
                HStack { ProgressView(); Text("Asking Celestrak…").foregroundStyle(.secondary) }
            } else {
                Button {
                    Task { await search.searchOnline(model.tle) }
                } label: {
                    Label("Search Celestrak for “\(search.query.trimmingCharacters(in: .whitespaces))”",
                          systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            if search.onlineFailed {
                Text("Couldn't reach Celestrak.").foregroundStyle(.secondary)
            }
        } header: {
            Text("All satellites")
        } footer: {
            Text("Found there, a satellite is pinned to the globe until you unpin it.")
        }
    }

    private func row(_ item: SearchModel.Item) -> some View {
        let category = item.categoryId.flatMap(Catalog.category(id:))
        return Button {
            model.choose(item.entry, categoryId: item.categoryId)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.category(item.categoryId ?? "pinned", dark: scheme == .dark))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.entry.name).foregroundStyle(.primary)
                    Text("NORAD \(String(item.norad)) · \(category?.label ?? "Celestrak")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "scope").foregroundStyle(.tint).accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

@MainActor
@Observable
final class SearchModel {
    struct Item: Identifiable, Hashable {
        let entry: TleEntry
        let norad: Int
        let categoryId: String?
        var id: String { "\(categoryId ?? "celestrak")-\(norad)" }
    }

    /// The ISS, China's station and Hubble.
    static let popular = [25544, 48274, 20580]

    var query = ""
    private(set) var index: [Item] = []
    private(set) var loading = false
    private(set) var online: [Item]?
    private(set) var searchingOnline = false
    private(set) var onlineFailed = false

    /// Every category's satellites (from the cache when it is fresh), so a
    /// search finds the ones that are switched off too.
    func loadIndex(_ tle: TleRepository, pinned: [TleEntry]) async {
        guard index.isEmpty, !loading else { return }
        loading = true
        var items: [Item] = []
        await withTaskGroup(of: (SatCategory, String).self) { group in
            for c in Catalog.categories {
                group.addTask { (c, await tle.tle(for: c.group).text) }
            }
            var byCategory: [String: [Item]] = [:]
            for await (c, text) in group {
                byCategory[c.id] = TLE.parse(text).compactMap { e in e.norad.map { Item(entry: e, norad: $0, categoryId: c.id) } }
            }
            for c in Catalog.categories { items += byCategory[c.id] ?? [] }
        }
        items += pinned.compactMap { e in e.norad.map { Item(entry: e, norad: $0, categoryId: Catalog.pinned.id) } }
        index = items
        loading = false
    }

    /// Matches by category, best first: the exact number, then names that
    /// start with the query, then names that contain it.
    func matches() -> [(SatCategory, [Item])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let number = Int(q)
        func rank(_ item: Item) -> Int? {
            if let number {
                if item.norad == number { return 0 }
                if String(item.norad).hasPrefix(q) { return 1 }
            }
            let name = item.entry.name
            if name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { return 2 }
            if name.localizedStandardContains(q) { return 3 }
            return nil
        }
        var out: [(SatCategory, [Item])] = []
        for c in Catalog.categories + [Catalog.pinned] {
            let hits = index.filter { $0.categoryId == c.id }
                .compactMap { item in rank(item).map { (item, $0) } }
                .sorted { $0.1 < $1.1 }
                .prefix(40)
                .map(\.0)
            if !hits.isEmpty { out.append((c, hits)) }
        }
        return out
    }

    func clearOnline() {
        online = nil
        onlineFailed = false
    }

    /// Celestrak's search, less what the categories already have.
    func searchOnline(_ tle: TleRepository) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !searchingOnline else { return }
        searchingOnline = true
        onlineFailed = false
        let found = await tle.search(q)
        searchingOnline = false
        guard q == query.trimmingCharacters(in: .whitespaces) else { return }
        guard let found else {
            onlineFailed = true
            return
        }
        let known = Set(index.map(\.norad))
        online = found.compactMap { e in
            guard let n = e.norad, !known.contains(n) else { return nil }
            return Item(entry: e, norad: n, categoryId: nil)
        }
    }
}
