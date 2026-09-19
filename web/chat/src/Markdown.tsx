import { memo } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

/**
 * Assistant prose.
 *
 * The `chat-markdown` class is what t3code's stylesheet targets, and that
 * stylesheet is vendored verbatim (src/vendor/t3code/styles/chat-markdown.css),
 * so element styling comes from their rules rather than a reimplementation.
 *
 * Their own renderer is not liftable: ChatMarkdown.tsx is 3,363 lines with ~80
 * imports reaching into Effect atoms, their state stores, syntax highlighting,
 * diff rendering, GitHub media and pull-request previews. react-markdown +
 * remark-gfm covers the same element set for a document reader.
 *
 * Memoised on `text`: a streaming turn re-renders on every coalesced delta,
 * and reparsing the whole document each time is the cost that makes a chat
 * surface feel heavy.
 */
export const Markdown = memo(function Markdown({ text }: { text: string }) {
  return (
    <div className="chat-markdown selectable">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          // Links leave the panel: hand them to the shell rather than
          // navigating the WebView away from the app.
          a: ({ href, children }) => (
            <a
              href={href}
              onClick={(e) => {
                e.preventDefault();
                if (href) window.open(href, "_blank");
              }}
            >
              {children}
            </a>
          ),
        }}
      >
        {text}
      </ReactMarkdown>
    </div>
  );
});
