import Foundation

/// Parses page range strings like "1-5", "3,7,12", "1-3,8,10-12" into 0-based indices.
enum PageRangeParser {
    static func parse(_ input: String, maxPage: Int) -> [Int] {
        var indices: [Int] = []
        let parts = input.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for part in parts {
            if part.contains("-") {
                let bounds = part.split(separator: "-").compactMap {
                    Int(String($0).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                guard bounds.count == 2, bounds[0] >= 1, bounds[1] >= bounds[0] else { continue }
                let start = max(bounds[0], 1)
                let end = min(bounds[1], maxPage)
                for page in start...end {
                    indices.append(page - 1)
                }
            } else if let page = Int(part), page >= 1, page <= maxPage {
                indices.append(page - 1)
            }
        }
        return indices
    }
}
