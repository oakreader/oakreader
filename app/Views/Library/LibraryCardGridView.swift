import SwiftUI
import UniformTypeIdentifiers

/// Masonry / waterfall card view for the Library middle pane.
///
/// Layout is a column waterfall: each card is appended to whichever of N independent vertical
/// stacks is currently shortest (estimated heights), and each card declares its intrinsic aspect
/// ratio, so the browser-style masonry falls out of N columns of aspect-correct cards — no packing
/// solver, no per-card height measurement. Each column is a `LazyVStack`, so off-screen cards
/// virtualize (this is why we use plain columns rather than the `Layout` protocol, which would
/// measure every subview eagerly and defeat virtualization).
struct LibraryCardGridView: View {
    let appState: AppState
    @Binding var selection: Set<UUID>

    @State private var sweeper: LibraryCoverSweeper?

    private var store: LibraryStore { appState.libraryStore }
    private var isBinMode: Bool { store.isBinSelected }

    // Document cards carry a title/source label, so they need more breathing room than an
    // image-only moodboard (GatherOS uses a tight ~10pt gutter; text cards need roughly double
    // that so the caption block reads as part of its own card rather than as a run of text
    // spanning the grid). The outer margin runs a notch wider than the gutter — the standard
    // Photos/Finder proportion, which keeps the grid from looking pinned to the pane edges.
    private let columnSpacing: CGFloat = 28
    private let cardSpacing: CGFloat = 28
    private let outerPadding: CGFloat = 32

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
            // Pack into shortest columns in a single O(items) pass (not O(columns × items)).
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

    // MARK: - Column distribution (shortest-column masonry)

    /// Pack items into `count` columns by always appending the next card to whichever column is
    /// currently *shortest* — the standard waterfall rule (Pinterest/Photos/Finder). Round-robin
    /// (`i % count`) balances card *count* per column but not card *height*, so with mixed card
    /// heights (portrait document pages vs. landscape web cards) columns end at very different Y
    /// positions, leaving the ragged bottom + empty-column gap. Heights are *estimated* from the
    /// content type rather than the real cover ratio — covers load async and aren't known here, and
    /// a stable estimate keeps the assignment from reshuffling (popping) as covers arrive. Ties
    /// resolve to the leftmost column, so a uniform set still fills left-to-right like round-robin.
    /// Still N independent columns ⇒ each stays a virtualizing `LazyVStack`.
    private static func distribute(_ items: [LibraryItem], into count: Int) -> [[LibraryItem]] {
        guard count > 0 else { return [items] }
        var columns = Array(repeating: [LibraryItem](), count: count)
        var heights = Array(repeating: CGFloat(0), count: count)
        for item in items {
            let shortest = heights.indices.min(by: { heights[$0] < heights[$1] }) ?? 0
            columns[shortest].append(item)
            heights[shortest] += estimatedCardHeight(item)
        }
        return columns
    }

    /// Relative card height for packing (a fixed card width cancels, so this is in width-units):
    /// cover height = 1 / aspectRatio, plus a constant for the two-line title + subtitle block.
    /// Mirrors `LibraryCardView.fallbackRatio` — portrait for documents, landscape for everything
    /// else — which is also where real covers land once clamped, so the estimate tracks reality.
    private static func estimatedCardHeight(_ item: LibraryItem) -> CGFloat {
        let coverRatio: CGFloat
        switch item.contentType {
        case .pdf, .markdown: coverRatio = 0.78
        default: coverRatio = 1.55
        }
        return 1 / coverRatio + 0.28
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

/// A single type-agnostic library card: the cover shown *whole* (never cropped) with depth + type
/// badge, a neutral frosted placeholder when no preview exists, and a two-line title + metadata
/// block. The card takes the cover's own aspect ratio so a PDF page / 16:9 slide displays in full;
/// the ratio is clamped only at the extremes so a freak panorama or text-wall page can't make a
/// card absurdly long.
private struct LibraryCardView: View {
    let item: LibraryItem
    let isSelected: Bool
    /// Bumped by the background sweep when it writes new cover files; re-reads this card's cover.
    let coverRevision: Int
    let onTap: () -> Void
    let onOpen: () -> Void

    @State private var cover: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    private let cornerRadius: CGFloat = 6

    /// Continuous (squircle) corners, not circular. Every rounded surface in macOS — window
    /// chrome, icons, sheets — is continuous; a circular corner next to them reads subtly wrong
    /// even when nobody can name why.
    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// Display aspect ratio (w/h). The card adopts the cover's *own* ratio so the page shows whole;
    /// the band is wide enough to hold every normal document shape (A4 portrait ≈ 0.71 … 16:9 slide
    /// ≈ 1.78) and clamps only true outliers (a panorama or a very tall single-column page), which
    /// then letterbox rather than crop. The old tight [0.72, 1.55] band is exactly what cropped
    /// 16:9 slide/title covers and A4 pages.
    private var aspectRatio: CGFloat {
        guard let cover, cover.size.height > 0 else { return fallbackRatio }
        return min(max(cover.size.width / cover.size.height, 0.55), 1.95)
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
                .clipShape(cardShape)
                // The hairline is *definition*, not separation: its only job is to stop a
                // white cover from bleeding into a light pane (and a dark cover from
                // dissolving into a dark one). Half a point, inside the clip, so it reads as
                // the edge of the artwork rather than as a frame drawn around it.
                .overlay { cardShape.strokeBorder(hairline, lineWidth: 0.5) }
                // Elevation in two layers. A single mid-blur drop shadow is what makes a card
                // look like a 2016 web tile: it is too soft to anchor the card and too tight to
                // lift it, so it lands as a grey smudge. Real depth is a tight *contact* shadow
                // that pins the card to the surface plus a wide, very faint *ambient* shadow
                // that does the lifting — the same split UIKit/AppKit use for their own
                // elevated surfaces.
                .shadow(color: contactShadow, radius: 1.5, y: 1)
                .shadow(color: ambientShadow, radius: 9, y: 3)
                // Selection is a ring *outside* the artwork with a gap, like a focus ring —
                // not a thicker border. Growing a `strokeBorder` from 1pt to 2.5pt moves the
                // image edge by 1.5pt, so every card twitched when you selected it; macOS never
                // reflows content to indicate state. Monochrome, not accent: the covers are the
                // only colour in this grid (see the colourless placeholder below), so an accent
                // ring is the loudest thing on screen for a state as ordinary as "selected".
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.5)
                        .padding(-4)
                        .opacity(isSelected ? 1 : 0)
                }
                .animation(.easeOut(duration: 0.12), value: isSelected)

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

    // MARK: - Card surface

    /// Light mode puts a faint dark edge on the artwork; dark mode flips to a rim light, because
    /// a dark edge on a dark pane is invisible. Same perceptual weight either way.
    private var hairline: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    /// Anchors the card to the pane — tight, barely offset, so the card does not appear to float
    /// free of the surface it sits on.
    private var contactShadow: Color {
        colorScheme == .dark ? Color.black.opacity(0.45) : Color.black.opacity(0.09)
    }

    /// Does the lifting. Deeper in dark mode, where a light-mode-weight shadow reads as nothing.
    private var ambientShadow: Color {
        colorScheme == .dark ? Color.black.opacity(0.40) : Color.black.opacity(0.10)
    }

    private var thumbnail: some View {
        GeometryReader { geo in
            Group {
                if let cover {
                    // Fit (not fill) so the whole page/slide is always visible — the card already
                    // adopts the cover's aspect ratio, so in the common case this fills edge-to-edge
                    // with no bars; only a true out-of-band cover letterboxes onto the page backdrop.
                    Image(nsImage: cover)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    placeholderCover
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipped()
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
