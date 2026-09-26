import SwiftUI

struct PageRangeSelector: View {
    @Binding var pageRange: PageRange
    let totalPages: Int

    @State private var rangeMode: RangeMode = .all
    @State private var startPage: Int = 1
    @State private var endPage: Int = 1
    @State private var customText: String = ""

    enum RangeMode: String, CaseIterable {
        case all = "All Pages"
        case range = "Page Range"
        case custom = "Custom"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Pages:", selection: $rangeMode) {
                ForEach(RangeMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: rangeMode) { _, newValue in
                updatePageRange(mode: newValue)
            }

            switch rangeMode {
            case .all:
                Text("All \(totalPages) pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .range:
                HStack {
                    Text("From:")
                    TextField("Start", value: $startPage, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("To:")
                    TextField("End", value: $endPage, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
                .onChange(of: startPage) { _, _ in updatePageRange(mode: .range) }
                .onChange(of: endPage) { _, _ in updatePageRange(mode: .range) }

            case .custom:
                VStack(alignment: .leading, spacing: 4) {
                    TextField("e.g., 1, 3, 5-8, 12", text: $customText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: customText) { _, _ in updatePageRange(mode: .custom) }
                    Text("Enter page numbers and/or ranges separated by commas")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            syncFromPageRange()
        }
    }

    private func syncFromPageRange() {
        switch pageRange {
        case .all:
            rangeMode = .all
        case .range(let r):
            rangeMode = .range
            startPage = r.lowerBound + 1
            endPage = r.upperBound + 1
        case .custom(let pages):
            rangeMode = .custom
            customText = pages.map { String($0 + 1) }.joined(separator: ", ")
        }
        endPage = min(endPage, totalPages)
    }

    private func updatePageRange(mode: RangeMode) {
        switch mode {
        case .all:
            pageRange = .all
        case .range:
            let start = max(0, min(startPage - 1, totalPages - 1))
            let end = max(start, min(endPage - 1, totalPages - 1))
            pageRange = .range(start...end)
        case .custom:
            let indices = parseCustomPages(customText)
            if indices.isEmpty {
                pageRange = .all
            } else {
                pageRange = .custom(indices)
            }
        }
    }

    private func parseCustomPages(_ text: String) -> [Int] {
        var result: [Int] = []
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts {
            if part.contains("-") {
                let rangeParts = part.split(separator: "-")
                if rangeParts.count == 2,
                   let start = Int(rangeParts[0].trimmingCharacters(in: .whitespaces)),
                   let end = Int(rangeParts[1].trimmingCharacters(in: .whitespaces)) {
                    let s = max(1, min(start, totalPages))
                    let e = max(s, min(end, totalPages))
                    result.append(contentsOf: (s...e).map { $0 - 1 })
                }
            } else if let page = Int(part) {
                let clamped = max(1, min(page, totalPages))
                result.append(clamped - 1)
            }
        }
        return Array(Set(result)).sorted()
    }
}
