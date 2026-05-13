import SwiftUI

struct LibraryFilterChipsView: View {
    @Bindable var store: LibraryStore

    /// The system "Status" property definition.
    private var statusProperty: PropertyDefinition? {
        store.properties.first { $0.name == "Status" && $0.isSystem }
    }

    /// Item types available for filtering.
    private let filterableTypes: [(type: ItemType, label: String)] = [
        (.pdf, "PDF"),
        (.webSnapshot, "Web"),
        (.embed, "Embed"),
        (.markdown, "Note"),
        (.audio, "Audio"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Type chips
            chipSection("Type") {
                ForEach(filterableTypes, id: \.type) { entry in
                    FilterChip(
                        label: entry.label,
                        icon: entry.type.icon,
                        isActive: store.selectedTypes.contains(entry.type.rawValue),
                        activeColor: Color.accentColor
                    ) {
                        toggleType(entry.type.rawValue)
                    }
                }
            }

            // Tag chips
            if let tagsProp = store.tagsProperty, !tagsProp.options.isEmpty {
                chipSection("Tags") {
                    ForEach(tagsProp.options) { option in
                        FilterChip(
                            label: option.name,
                            isActive: store.selectedTagOptionIds.contains(option.id),
                            activeColor: Color(hex: option.colorHex)
                        ) {
                            toggleTagOption(option.id)
                        }
                    }
                }
            }

            // Status chips
            if let statusProp = statusProperty, !statusProp.options.isEmpty {
                chipSection("Status") {
                    ForEach(statusProp.options) { option in
                        FilterChip(
                            label: option.name,
                            isActive: store.selectedStatusOptionIds.contains(option.id),
                            activeColor: Color(hex: option.colorHex)
                        ) {
                            toggleStatusOption(option.id)
                        }
                    }
                }
            }

            // Clear All
            if store.hasActiveChipFilters {
                HStack {
                    Spacer()
                    Button("Clear All") {
                        store.clearChipFilters()
                    }
                    .font(OakStyle.Font.styledCaption)
                    .buttonStyle(.borderless)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func chipSection(_ title: String, @ViewBuilder chips: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(OakStyle.Font.styledCaption)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                chips()
            }
        }
    }

    private func toggleType(_ rawValue: String) {
        if store.selectedTypes.contains(rawValue) {
            store.selectedTypes.remove(rawValue)
        } else {
            store.selectedTypes.insert(rawValue)
        }
    }

    private func toggleTagOption(_ id: UUID) {
        if store.selectedTagOptionIds.contains(id) {
            store.selectedTagOptionIds.remove(id)
        } else {
            store.selectedTagOptionIds.insert(id)
        }
    }

    private func toggleStatusOption(_ id: UUID) {
        if store.selectedStatusOptionIds.contains(id) {
            store.selectedStatusOptionIds.remove(id)
        } else {
            store.selectedStatusOptionIds.insert(id)
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    var icon: String? = nil
    let isActive: Bool
    let activeColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                }
                Text(label)
                    .lineLimit(1)
            }
            .font(OakStyle.Font.styledCaption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                isActive
                    ? activeColor.opacity(0.18)
                    : OakStyle.Colors.buttonBackground,
                in: Capsule()
            )
            .foregroundStyle(isActive ? activeColor : .primary)
        }
        .buttonStyle(.borderless)
    }
}
