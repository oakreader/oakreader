import SwiftUI

/// AI Studio — the per-item artifact surface. A grid of one-click generators
/// (NotebookLM-style) sits above the list of artifacts generated for this
/// document. Quiz/Flashcards is wired up; Mind Map / Deck / Audio land later.
struct StudioPanelView: View {
    let viewModel: DocumentViewModel

    private var model: StudioViewModel { viewModel.studio }
    @State private var sheetKind: StudioArtifactKind?

    /// The mind-map's amber anchor color — the panel's single accent, so the
    /// native chrome and the WKWebView map read as one surface.
    static let accent = Color(hex: "C77A2E")

    /// A consistent "Generating…" banner — faint amber wash, quiet medium type.
    private func streamingHeader(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            if let count {
                Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(StudioPanelView.accent.opacity(0.07)))
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader("Studio", subtitle: subtitle)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: viewModel.itemId) { await model.reload() }
        .sheet(item: $sheetKind) { kind in
            StudioGenerateSheet(kind: kind) { params in
                model.generate(kind: kind, params: params)
            }
        }
    }

    private var subtitle: String {
        guard model.isLoaded else { return " " }
        let n = model.artifacts.count
        if n == 0 { return "Generate study material" }
        return "\(n) artifact\(n == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                tileGrid

                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.08)))
                }

                // The deck currently streaming in — grows card-by-card.
                if let deck = model.streamingDeck {
                    VStack(alignment: .leading, spacing: 10) {
                        streamingHeader("Generating flashcards…", count: deck.cards.count)
                        if !deck.cards.isEmpty {
                            InlineDeckView(deck: deck)
                        }
                    }
                }

                // The mind map currently streaming in — re-renders live.
                if let outline = model.streamingMindmapOutline {
                    VStack(alignment: .leading, spacing: 10) {
                        streamingHeader("Generating mind map…")
                        StudioWebView(outline: outline, onNodeClick: { model.jumpToSource(anchorText: $0) })
                            .frame(height: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OakStyle.Colors.diaHairline, lineWidth: 1))
                    }
                }

                if !model.isLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else if model.artifacts.isEmpty && model.generatingKind == nil {
                    Text("Pick a tile above to generate study material grounded in this document.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } else {
                    ForEach(model.artifacts) { artifactCard($0) }
                }
            }
            .padding(14)
        }
    }

    private var tileGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
        ) {
            ForEach(StudioArtifactKind.allCases) { tile($0) }
        }
    }

    private func tile(_ kind: StudioArtifactKind) -> some View {
        Button {
            guard kind.isAvailable, model.generatingKind == nil else { return }
            sheetKind = kind
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(kind.isAvailable ? StudioPanelView.accent : Color.secondary.opacity(0.5))
                    Spacer()
                    if model.generatingKind == kind {
                        ProgressView().controlSize(.small)
                    } else if !kind.isAvailable {
                        Text("Soon")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text(kind.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(kind.isAvailable ? .primary : .secondary)
                Text(kind.blurb)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(OakStyle.Colors.diaSurface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(OakStyle.Colors.diaHairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(!kind.isAvailable || model.generatingKind != nil)
    }

    private func artifactCard(_ artifact: StudioArtifact) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: artifact.kind.systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(artifact.title.isEmpty ? artifact.kind.label : artifact.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(artifact.createdAt, format: .dateTime.month().day())
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            switch artifact.kind {
            case .quiz:
                if let deck = artifact.quizDeck {
                    InlineDeckView(deck: deck, onExpand: {
                        viewModel.studioFullScreenArtifact = artifact
                    })
                } else {
                    unavailableBody
                }
            case .mindmap:
                StudioWebView(outline: artifact.body, onNodeClick: { model.jumpToSource(anchorText: $0) })
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OakStyle.Colors.diaHairline, lineWidth: 1))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            viewModel.studioFullScreenArtifact = artifact
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(6)
                                .background(.thinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                        .help("Open full-screen")
                    }
            case .deck, .audio:
                unavailableBody
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                model.delete(artifact)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var unavailableBody: some View {
        Text("This artifact can't be displayed.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }
}
