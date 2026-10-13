import Foundation

/// Cite handles for the JSON the `oak` CLI prints, so the agent can cite what an
/// `oak` command showed it. Foundation-only, so the test bundle can compile it.
extension CitationSourceRegistry {

    /// Add a `cite` handle to every result row that names a library item, so the model can
    /// cite a document straight out of a search or list without re-typing its identity.
    ///
    /// Done by rewriting the CLI's JSON rather than by teaching the CLI about chat sessions:
    /// `oak` is a standalone binary that also runs outside the app, and citation handles are
    /// a property of a conversation, not of the library.
    func annotateOakOutput(_ output: String, visibleChars: Int) -> String {
        // pdf.js writes warnings ("Required "glyf" table is not found") to stderr,
        // which shares the pipe, so the JSON can start on a later line. Parsing the
        // whole output failed on those, and the model got no handle to cite.
        let jsonStart = output.hasPrefix("{")
            ? output.startIndex
            : output.range(of: "\n{")?.upperBound ?? output.startIndex
        let json = jsonStart == output.startIndex ? output : "{" + output[jsonStart...]
        guard let data = json.data(using: .utf8),
              var envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return output }

        // A command that names one item — `import`, `items read` — answers with a
        // single `result` object rather than a `results` array. It deserves a
        // handle just as much: the model has just filed a document and should be
        // able to link to it in the same breath.
        if var single = envelope["result"] as? [String: Any],
           let itemId = single["id"] as? String, !itemId.isEmpty {
            let handle = register(CitationSourceRegistry.Source(
                itemId: itemId, page: nil, time: nil, heading: nil, text: nil))
            single["cite"] = "oak:\(handle)"
            // The text of a read document gets a number per passage, so the model
            // can cite the page a claim is on and not only the document.
            if let content = single["content"] as? String {
                single["content"] = numberedContent(content, itemId: itemId, visibleChars: visibleChars)
            }
            envelope["result"] = single
            guard let encoded = try? JSONSerialization.data(withJSONObject: envelope,
                                                            options: [.sortedKeys]),
                  let text = String(data: encoded, encoding: .utf8)
            else { return output }
            return text
        }

        guard var rows = envelope["results"] as? [[String: Any]], !rows.isEmpty
        else { return output }

        var annotated = false
        for index in rows.indices {
            // `search` rows carry `itemId`; `items list` rows nest it as `item.id`.
            let nested = rows[index]["item"] as? [String: Any]
            guard let itemId = (rows[index]["itemId"] as? String)
                    ?? (rows[index]["id"] as? String)
                    ?? (nested?["id"] as? String),
                  !itemId.isEmpty else { continue }
            let handle = register(CitationSourceRegistry.Source(
                itemId: itemId, page: nil, time: nil, heading: nil, text: nil))
            rows[index]["cite"] = "oak:\(handle)"
            annotated = true
        }
        guard annotated else { return output }

        envelope["results"] = rows
        guard let encoded = try? JSONSerialization.data(withJSONObject: envelope,
                                                        options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8)
        else { return output }
        return text
    }

    /// Number the passages of an `items read` body against `itemId`.
    ///
    /// A PDF read with `--pages` arrives as `--- Page N ---` sections, so each
    /// passage keeps its page. Anything else is numbered as one block. Only the
    /// part the model will see is numbered: the output is cut at
    /// `visibleChars`, and a number past the cut would never be cited.
    private func numberedContent(_ content: String, itemId: String, visibleChars: Int) -> String {
        let visible = String(content.prefix(visibleChars))
        guard let marker = try? NSRegularExpression(pattern: #"^--- Page (\d+) ---$"#,
                                                    options: .anchorsMatchLines)
        else { return visible }
        let ns = visible as NSString
        let matches = marker.matches(in: visible, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return numbered(visible, itemId: itemId) }

        var sections: [String] = []
        for (i, m) in matches.enumerated() {
            let start = m.range.location + m.range.length
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: start, length: end - start))
            let page = Int(ns.substring(with: m.range(at: 1))).map { $0 - 1 }  // 0-based
            sections.append(ns.substring(with: m.range) + "\n"
                + numbered(body, itemId: itemId, page: page))
        }
        return sections.joined(separator: "\n\n")
    }
}
