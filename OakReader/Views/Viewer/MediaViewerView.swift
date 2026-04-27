import SwiftUI
import WebKit

/// Viewer for embed documents (YouTube).
struct MediaViewerView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        if let media = viewModel.mediaDocument {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Player area
                    youtubeEmbed(media: media)

                    Divider()

                    // Metadata
                    metadataSection(media: media)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)

                    // Transcript
                    if let transcriptURL = media.transcriptURL,
                       let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
                       !transcript.isEmpty {
                        Divider()
                        transcriptSection(transcript: transcript)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                    }
                }
            }
            .background(OakStyle.Colors.contentBackground)
        } else {
            Text("No media loaded")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - YouTube Embed

    @ViewBuilder
    private func youtubeEmbed(media: MediaDocument) -> some View {
        let videoId = extractYouTubeVideoId(from: media.sourceURL)
        if let videoId {
            YouTubeEmbedView(videoId: videoId)
                .aspectRatio(16/9, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Metadata Section

    @ViewBuilder
    private func metadataSection(media: MediaDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(media.metadata.title)
                .font(.title2.bold())

            HStack(spacing: 8) {
                Text(media.metadata.author)
                    .foregroundStyle(.secondary)

                if let duration = media.metadata.duration {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(formatDuration(duration))
                        .foregroundStyle(.secondary)
                }

                if let publishedAt = media.metadata.publishedAt {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(publishedAt)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)

            if let description = media.metadata.description, !description.isEmpty {
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Transcript Section

    @ViewBuilder
    private func transcriptSection(transcript: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript")
                .font(.headline)

            Text(transcript)
                .font(.body)
                .textSelection(.enabled)
                .lineSpacing(4)
        }
    }

    // MARK: - Helpers

    private func extractYouTubeVideoId(from url: URL) -> String? {
        let urlString = url.absoluteString
        // youtube.com/watch?v=VIDEO_ID
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let vParam = components.queryItems?.first(where: { $0.name == "v" })?.value {
            return vParam
        }
        // youtu.be/VIDEO_ID
        if url.host == "youtu.be" {
            return url.pathComponents.last
        }
        // youtube.com/embed/VIDEO_ID
        if urlString.contains("/embed/") {
            return url.pathComponents.last
        }
        return nil
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - YouTube Embed (WKWebView)

/// NSViewRepresentable wrapping WKWebView for YouTube privacy-enhanced embed.
struct YouTubeEmbedView: NSViewRepresentable {
    let videoId: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsAirPlayForMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        loadEmbed(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    private func loadEmbed(in webView: WKWebView) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            * { margin: 0; padding: 0; }
            body { background: #000; }
            iframe { width: 100%; height: 100vh; border: none; }
        </style>
        </head>
        <body>
        <iframe src="https://www.youtube-nocookie.com/embed/\(videoId)?rel=0&modestbranding=1"
                allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
                allowfullscreen>
        </iframe>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}
