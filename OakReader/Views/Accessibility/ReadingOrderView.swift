import SwiftUI
import PDFKit

struct ReadingOrderView: View {
    let viewModel: DocumentViewModel

    @State private var readingOrderItems: [ReadingOrderItem] = []
    @State private var draggedItemID: UUID?

    struct ReadingOrderItem: Identifiable {
        let id = UUID()
        var order: Int
        var bounds: CGRect
        var label: String
        var pageIndex: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Reading Order")
                    .font(.headline)

                Spacer()

                Button {
                    detectReadingOrder()
                } label: {
                    Label("Auto-Detect", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)

                Button {
                    readingOrderItems.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(readingOrderItems.isEmpty)
            }
            .padding(8)

            Divider()

            HSplitView {
                // Left: Order list
                VStack(spacing: 0) {
                    Text("Content Order")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(4)

                    if readingOrderItems.isEmpty {
                        VStack {
                            Spacer()
                            Text("Click \"Auto-Detect\" to analyze the page reading order.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                            Spacer()
                        }
                    } else {
                        List {
                            ForEach(currentPageItems) { item in
                                HStack(spacing: 8) {
                                    // Order number
                                    ZStack {
                                        Circle()
                                            .fill(Color.accentColor)
                                            .frame(width: 24, height: 24)
                                        Text("\(item.order)")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .foregroundStyle(.white)
                                    }

                                    Text(item.label)
                                        .font(.caption)
                                        .lineLimit(1)

                                    Spacer()
                                }
                            }
                            .onMove { source, destination in
                                var items = currentPageItems
                                items.move(fromOffsets: source, toOffset: destination)
                                updateOrder(items)
                            }
                        }
                        .listStyle(.bordered)
                    }
                }
                .frame(minWidth: 200)

                // Right: Visual overlay
                ZStack {
                    if let doc = viewModel.pdfDocument,
                       let page = doc.page(at: viewModel.state.currentPageIndex) {
                        let thumbnail = page.thumbnail(of: CGSize(width: 400, height: 520), for: .mediaBox)
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .background(Color.white)

                        // Reading order indicators
                        GeometryReader { geometry in
                            let pageBounds = page.bounds(for: .mediaBox)
                            let scaleX = geometry.size.width / pageBounds.width
                            let scaleY = geometry.size.height / pageBounds.height

                            ForEach(currentPageItems) { item in
                                let x = item.bounds.midX * scaleX
                                let y = (pageBounds.height - item.bounds.midY) * scaleY

                                ZStack {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 28, height: 28)
                                        .shadow(radius: 2)

                                    Text("\(item.order)")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundStyle(.white)
                                }
                                .position(x: x, y: y)
                            }
                        }
                    } else {
                        Text("No page available")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 300)
            }
        }
    }

    private var currentPageItems: [ReadingOrderItem] {
        readingOrderItems
            .filter { $0.pageIndex == viewModel.state.currentPageIndex }
            .sorted { $0.order < $1.order }
    }

    private func updateOrder(_ reordered: [ReadingOrderItem]) {
        let otherPages = readingOrderItems.filter { $0.pageIndex != viewModel.state.currentPageIndex }
        var updated = reordered
        for i in updated.indices {
            updated[i].order = i + 1
        }
        readingOrderItems = otherPages + updated
    }

    private func detectReadingOrder() {
        guard let doc = viewModel.pdfDocument,
              let page = doc.page(at: viewModel.state.currentPageIndex) else { return }

        let pageBounds = page.bounds(for: .mediaBox)
        var items: [ReadingOrderItem] = []

        // Simple reading order detection based on annotation/text positions
        // In production, this would use the PDF structure tree
        let annotations = page.annotations
        for (index, annotation) in annotations.enumerated() {
            items.append(ReadingOrderItem(
                order: index + 1,
                bounds: annotation.bounds,
                label: annotation.contents ?? annotation.type ?? "Content \(index + 1)",
                pageIndex: viewModel.state.currentPageIndex
            ))
        }

        // If no annotations, create a simple top-to-bottom reading order
        if items.isEmpty {
            let regionCount = 5
            let regionHeight = pageBounds.height / CGFloat(regionCount)
            for i in 0..<regionCount {
                items.append(ReadingOrderItem(
                    order: i + 1,
                    bounds: CGRect(
                        x: pageBounds.width * 0.5,
                        y: pageBounds.height - CGFloat(i) * regionHeight - regionHeight / 2,
                        width: 1,
                        height: 1
                    ),
                    label: "Region \(i + 1)",
                    pageIndex: viewModel.state.currentPageIndex
                ))
            }
        }

        // Remove existing items for this page and add new ones
        readingOrderItems.removeAll { $0.pageIndex == viewModel.state.currentPageIndex }
        readingOrderItems.append(contentsOf: items)
    }
}
