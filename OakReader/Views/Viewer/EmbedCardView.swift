import SwiftUI
import WebKit

/// Renders non-YouTube embed documents (tweets, generic links) using a local `embed.html` in WKWebView.
/// Follows the same security pattern as `WebArchiveViewerRepresentable` — blocks all external requests.
struct EmbedCardView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        if let media = viewModel.mediaDocument, media.embedHTMLURL != nil {
            EmbedWebViewRepresentable(media: media)
                .background(Color(nsColor: .controlBackgroundColor))
        } else if let media = viewModel.mediaDocument {
            // Fallback: show metadata as plain text
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

// MARK: - WKWebView Wrapper

private struct EmbedWebViewRepresentable: NSViewRepresentable {
    let media: MediaDocument

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsMagnification = true

        // Block all external network requests
        let ruleJSON = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "BlockExternalEmbed",
            encodedContentRuleList: ruleJSON
        ) { [weak webView] list, _ in
            DispatchQueue.main.async {
                guard let webView, let ruleList = list else { return }
                webView.configuration.userContentController.add(ruleList)
            }
        }

        // Load embed.html from local storage
        if let embedURL = media.embedHTMLURL {
            let storageDir = embedURL.deletingLastPathComponent()
            webView.loadFileURL(embedURL, allowingReadAccessTo: storageDir)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
