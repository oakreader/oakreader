import Foundation

extension String {
    func normalizedForSearch() -> String {
        // Normalize unicode, fold case, strip diacritics
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    func ranges(of searchString: String, options: String.CompareOptions = [.caseInsensitive]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchRange = startIndex..<endIndex
        while let range = self.range(of: searchString, options: options, range: searchRange) {
            ranges.append(range)
            searchRange = range.upperBound..<endIndex
        }
        return ranges
    }
}
