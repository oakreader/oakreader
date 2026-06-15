import SwiftUI
import UniformTypeIdentifiers

/// Masonry / waterfall card view for the Library middle pane.
///
/// Layout follows GatherOS's "dumb columns": items are round-robined into N independent
/// vertical stacks (`column[i % N]`) and each card declares its intrinsic aspect ratio, so the
/// browser-style waterfall falls out of N columns of aspect-correct cards — no packing solver,
/// no per-card height measurement. Each column is a `LazyVStack`, so off-screen cards virtualize
/// (this is why we use round-robin columns rather than the `Layout` protocol, which would measure
/// every subview eagerly and defeat virtualization).
struct LibraryCardGridView: View {
    let appState: AppState
    @Binding var selection: Set<UUID>

    @State private var sweeper: LibraryCoverSweeper?

    private var store: LibraryStore { appState.libraryStore }
    private var isBinMode: Bool { store.isBinSelected }

    // Document cards carry a title/source label, so they need more breathing room than an
    // image-only moodboard (GatherOS uses a tight ~10pt gutter; text cards read better at ~16pt).
    private let columnSpacing: CGFloat = 16
    private let cardSpacing: CGFloat = 16
    private let outerPadding: CGFloat = 16

    // Column count is responsive, not user-set: we hold the *card size* roughly constant and let
    // the number of columns fall out of the window width, so resizing reflows the grid (Finder /
    // Photos behaviour) instead of rescaling every card. Cards land near `targetCardWidth`.
    private let targetCardWidth: CGFloat = 220
    private let minColumns = 2
    private let maxColumns = 8

    var body: some View {
        GeometryReader { geo in
            let items = store.filteredItems
            let columnCount = responsiveColumnCount(for: geo.size.width)
            let coverRevision = store.coverRevision
            // Distribute round-robin in a single O(items) pass (not O(columns × items)).
            let columns = Self.distribute(items, into: columnCount)

            ScrollView(.vertical) {
                if items.isEmpty {
                    emptyState
                } else {
                    HStack(alignment: .top, spacing: columnSpacing) {
                        ForEach(columns.indices, id: \.self) { column in
                            LazyVStack(spacing: cardSpacing) {
                                ForEach(columns[column]) { item in
                                    LibraryCardView(
                                        item: item,
                                        isSelected: selection.contains(item.id),
                                        coverRevision: coverRevision,
                                        onTap: { handleTap(item) },
                                        onOpen: { appState.openLibraryItem(item) }
                                    )
                                    .contextMenu { contextMenu(for: item) }
                                    .draggable(item.id.uuidString)
                                }
                            }
                        }
                    }
                    .padding(outerPadding)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .onDrop(of: [.pdf, .html, .plainText, .audio, .fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
                return true
            }
            // Backfill missing covers in the background (bounded, off the scroll path). Re-runs when
            // the item count changes; the sweeper skips already-attempted items so this stays cheap.
            .task(id: items.count) {
                let sweeper = sweeper ?? LibraryCoverSweeper(coverService: appState.coverService)
                if self.sweeper == nil { self.sweeper = sweeper }
                await sweeper.sweep(items: items, store: store)
            }
        }
    }

    /// How many columns of ~`targetCardWidth` fit the available width (gutters accounted for),
    /// clamped to `minColumns…maxColumns`. Pure function of width ⇒ window resizes reflow live.
    private func responsiveColumnCount(for width: CGFloat) -> Int {
        guard width > 0 else { return minColumns }
        let usable = width - outerPadding * 2
        let fit = Int(((usable + columnSpacing) / (targetCardWidth + columnSpacing)).rounded(.down))
        return max(minColumns, min(maxColumns, fit))
    }

    // MARK: - Column distribution (round-robin)

    /// Bucket items into `count` columns in one pass: item i → column i % count.
    private static func distribute(_ items: [LibraryItem], into count: Int) -> [[LibraryItem]] {
        guard count > 0 else { return [items] }
        var columns = Array(repeating: [LibraryItem](), count: count)
        for (index, item) in items.enumerated() {
            columns[index % count].append(item)
        }
        return columns
    }

    // MARK: - Selection

    private func handleTap(_ item: LibraryItem) {
        let toggle = NSEvent.modifierFlags.contains(.command)
        if toggle {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            selection = [item.id]
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for item: LibraryItem) -> some View {
        let targets = selection.contains(item.id) ? selectedItems() : [item]

        Button { appState.openLibraryItem(item) } label: { Label("Open", systemImage: "arrow.up.forward.square") }
        Button { appState.openAgentOnItem(item) } label: { Label("Open in Agent", systemImage: "sparkles") }
        Divider()
        if isBinMode {
            Button { store.restoreItems(targets) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) {
                for target in targets { store.removeItem(target) }
            } label: { Label("Delete Permanently", systemImage: "trash") }
        } else {
            Button(role: .destructive) {
                store.trashItems(targets)
            } label: { Label("Move to Bin", systemImage: "trash") }
        }
    }

    private func selectedItems() -> [LibraryItem] {
        store.filteredItems.filter { selection.contains($0.id) }
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let url = data as? URL else { return }
                Task {
                    let item = await appState.importService.importFileAsync(from: url)
                    guard let item else { return }
                    await MainActor.run {
                        if let collection = store.selectedCollection, !collection.isSmart {
                            store.addItem(item, to: collection)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 28))
                .foregroundStyle(Color.primary.opacity(0.2))
            Text("No items")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

// MARK: - Card

/// A single type-agnostic library card: a top-cropped cover with depth + type badge, a neutral
/// frosted placeholder when no preview exists, and a two-line title + metadata block. Covers are
/// cropped to their *top* (the title/figure region a reader recognizes) rather than squished
/// whole-page, and the aspect ratio is clamped so a tall paper page never becomes a noisy strip.
private struct LibraryCardView: View {
    let item: LibraryItem
    let isSelected: Bool
    /// Bumped by the background sweep when it writes new cover files; re-reads this card's cover.
    let coverRevision: Int
    let onTap: () -> Void
    let onOpen: () -> Void

    @State private var cover: NSImage?

    private let cornerRadius: CGFloat = 10

    /// Display aspect ratio (w/h). Real covers use their own ratio, clamped to a pleasant band so
    /// extreme portrait pages crop to their title region instead of rendering as a tall text wall.
    private var aspectRatio: CGFloat {
        guard let cover, cover.size.height > 0 else { return fallbackRatio }
        return min(max(cover.size.width / cover.size.height, 0.72), 1.55)
    }

    /// Cover-less fallback ratio: portrait for documents, landscape for web/link/audio.
    private var fallbackRatio: CGFloat {
        switch item.contentType {
        case .pdf, .markdown: return 0.78
        default: return 1.55
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            thumbnail
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 2)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onTap)
        .task(id: "\(item.id.uuidString):\(coverRevision)") { await loadCover() }
    }

    private var thumbnail: some View {
        GeometryReader { geo in
            Group {
                if let cover {
                    Image(nsImage: cover)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                } else {
                    placeholderCover
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(alignment: .bottomLeading) { typeBadge }
        }
    }

    /// Neutral frosted placeholder for items with no real preview. A calm material/grey panel
    /// (approximating Liquid Glass — the real `glassEffect` API is macOS 26, we deploy to 15.4)
    /// with a monochrome type glyph and a source/type label. Deliberately colorless: real
    /// thumbnails (PDF pages, OG images) are the only color in the grid, so cover-less cards
    /// recede instead of shouting a random hue.
    private var placeholderCover: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Rectangle().fill(Color.primary.opacity(0.035))
            VStack(spacing: 9) {
                Image(systemName: glyph)
                    .font(.system(size: 26, weight: .regular))
                Text(placeholderLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var glyph: String { item.primaryAttachment?.icon ?? item.displayIcon }

    private var placeholderLabel: String {
        if let host = cleanHost { return host }
        return item.contentType.label
    }

    /// Author · year for papers, else journal/venue, else the source domain, else the type.
    private var subtitle: String? {
        if !item.author.isEmpty {
            if let year = item.referenceMetadata?.year { return "\(item.author) · \(year)" }
            return item.author
        }
        if let journal = item.referenceMetadata?.journal, !journal.isEmpty { return journal }
        if let host = cleanHost { return host }
        return nil
    }

    private var cleanHost: String? {
        guard let host = item.sourceURL?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var typeBadge: some View {
        Image(systemName: glyph)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
            .padding(6)
    }

    // MARK: - Cover loading (read-only, cached)

    /// Load the existing cover from disk only. The grid never *generates* covers on scroll —
    /// that would (a) spin an offscreen WKWebView per HTML card and (b) call `store.updateCover`,
    /// whose `invalidate()` forces a full `fetchAllItems` (re-reading every item's cover from
    /// disk) on each card. Generation happens at import and via the sidebar/background sweep;
    /// here we only read what's already on disk — cached, off the main thread, per visible card.
    private func loadCover() async {
        cover = await LibraryThumbnailCache.shared.thumbnail(for: item)
    }
}

/// Bounded in-memory cache of decoded card thumbnails. Loads a cover from `attachment.coverURL`
/// on a background thread and caches the decoded `NSImage`, so scrolling neither re-reads the
/// file nor re-decodes the JPEG. Keyed by cover path + file size + mtime, so a regenerated
/// cover (same path, new bytes) misses the stale entry and reloads.
final class LibraryThumbnailCache {
    static let shared = LibraryThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 500 // ~visible + scroll buffer; bounded regardless of library size
    }

    @MainActor
    func thumbnail(for item: LibraryItem) async -> NSImage? {
        guard let url = item.primaryAttachment?.coverURL else { return nil }
        return await Task.detached(priority: .utility) { [cache] in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs != nil else { return nil } // no cover file on disk
            let size = (attrs?[.size] as? Int) ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let key = "\(url.path):\(size):\(mtime)" as NSString
            if let cached = cache.object(forKey: key) { return cached }
            guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
            cache.setObject(image, forKey: key)
            return image
        }.value
    }
}
