import SwiftUI

// Tag selector: colored dots with names, wrapping layout
struct TagSelectorView: View {
    let store: LibraryStore

    @State private var showTagManager = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.tags.isEmpty {
                HStack {
                    Text("No tags")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    gearButton
                }
            } else {
                // Tag dots in a wrapping flow
                FlowLayout(spacing: 4) {
                    ForEach(store.tags, id: \.id) { tag in
                        tagDot(tag)
                    }
                }

                // Filter Tags label + gear at bottom
                HStack(spacing: 0) {
                    Spacer()
                    gearButton
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .sheet(isPresented: $showTagManager) {
            TagManagerSheet(store: store)
        }
    }

    private func tagDot(_ tag: PDFTag) -> some View {
        let isSelected = store.selectedTags.contains(tag.id)
        return Button {
            if store.selectedTags.contains(tag.id) {
                store.selectedTags.remove(tag.id)
            } else {
                store.selectedTags.insert(tag.id)
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: tag.colorHex))
                    .frame(width: 8, height: 8)

                Text(tag.name)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var gearButton: some View {
        Button {
            showTagManager = true
        } label: {
            Image(systemName: "gear")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .background(TooltipTrigger(tooltip: "Manage Tags"))
    }
}
