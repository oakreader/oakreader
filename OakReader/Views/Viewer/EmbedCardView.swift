import SwiftUI
import WebKit

/// Renders non-YouTube embed documents (tweets, generic links) using a local `embed.html` in WKWebView.
struct EmbedCardView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        if let media = viewModel.mediaDocument, media.embedHTMLURL != nil {
            LocalEmbedWebView(media: media)
                .background(Color(nsColor: .controlBackgroundColor))
        } else if let media = viewModel.mediaDocument {
            embedFallback(media: media)
        } else {
            Text("No content loaded")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func embedFallback(media: MediaDocument) -> some View {
        VStack(spacing: 16) {
            Spacer()
            VStack(spacing: 12) {
                Text(media.metadata.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                if !media.metadata.author.isEmpty {
                    Text(media.metadata.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let description = media.metadata.description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .multilineTextAlignment(.center)
                }

                Link(destination: media.sourceURL) {
                    Text("Open in Browser")
                        .font(.callout)
                }
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: 520)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Local Embed

private struct LocalEmbedWebView: NSViewRepresentable {
    let media: MediaDocument

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsMagnification = true

        // Load embed.html from local storage
        if let embedURL = media.embedHTMLURL {
            let storageDir = embedURL.deletingLastPathComponent()
            webView.loadFileURL(embedURL, allowingReadAccessTo: storageDir)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
