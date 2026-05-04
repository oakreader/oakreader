import SwiftUI
import WebKit

/// Renders non-YouTube embed documents (tweets, generic links).
/// Twitter embeds load via platform.twitter.com oEmbed for full rendering.
/// Generic links use a local `embed.html` with blocked external requests.
struct EmbedCardView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        if let media = viewModel.mediaDocument {
            switch media.metadata.resolvedEmbedType {
            case .twitter:
                TwitterEmbedWebView(media: media)
                    .background(Color(nsColor: .controlBackgroundColor))
            case .link:
                if media.embedHTMLURL != nil {
                    LocalEmbedWebView(media: media)
                        .background(Color(nsColor: .controlBackgroundColor))
                } else {
                    embedFallback(media: media)
                }
            default:
                embedFallback(media: media)
            }
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

// MARK: - Twitter Embed (loads oEmbed with network access)

private struct TwitterEmbedWebView: NSViewRepresentable {
    let media: MediaDocument

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsMagnification = true
        webView.isInspectable = false

        // Build oEmbed HTML that loads the tweet via Twitter's widget script
        let tweetURL = media.sourceURL.absoluteString
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          body {
            margin: 0; padding: 24px;
            display: flex; justify-content: center;
            font-family: -apple-system, sans-serif;
            background: transparent;
          }
          .container { max-width: 550px; width: 100%; }
        </style>
        </head>
        <body>
        <div class="container">
          <blockquote class="twitter-tweet" data-dnt="true">
            <a href="\(tweetURL)"></a>
          </blockquote>
          <script async src="https://platform.twitter.com/widgets.js"></script>
        </div>
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: URL(string: "https://platform.twitter.com"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}

// MARK: - Local Embed (blocks external requests)

private struct LocalEmbedWebView: NSViewRepresentable {
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
