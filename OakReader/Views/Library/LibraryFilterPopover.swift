import SwiftUI

struct LibraryFilterPopover: View {
    @Bindable var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Filters")
                    .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .semibold))
                Spacer()
                Button {
                    store.activeFilters.append(defaultCondition())
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "plus")
                        Text("Add")
                    }
                    .font(OakStyle.Font.styledCaption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if !store.activeFilters.isEmpty {
                Divider()

                // Filter rows
                VStack(spacing: 6) {
                    ForEach(store.activeFilters.indices, id: \.self) { index in
                        FilterRowView(
                            condition: $store.activeFilters[index],
                            store: store,
                            onRemove: { store.activeFilters.remove(at: index) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                // Clear All
                HStack {
                    Spacer()
                    Button("Clear All") {
                        store.clearFilters()
                    }
                    .font(OakStyle.Font.styledCaption)
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                // Empty state
                Text("No active filters. Tap + Add to create one.")
                    .font(OakStyle.Font.styledCaption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 380)
    }

    /// Available fields for user-facing toolbar filters.
    static let availableFields: [(FilterField, String)] = [
        (.itemType, "Type"),
        (.property, "Tags"),
        (.property, "Status"),
        (.author, "Author"),
    ]

    private func defaultCondition() -> FilterCondition {
        FilterCondition(field: .itemType, op: .eq, value: ItemType.pdf.rawValue)
    }
}

// MARK: - Filter Row

private struct FilterRowView: View {
    @Binding var condition: FilterCondition
    let store: LibraryStore
    let onRemove: () -> Void

    /// Human-readable field label for the current condition.
    private var fieldLabel: String {
        switch condition.field {
        case .itemType: return "Type"
        case .author: return "Author"
        case .property:
            if let pid = condition.propertyId,
               let prop = store.properties.first(where: { $0.id.uuidString == pid }) {
                return prop.name
            }
            return "Property"
        default: return condition.field.rawValue
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Field picker
            Menu {
                Button("Type") { setField(.itemType) }
                Button("Tags") { setField(.property, propertyName: "Tags") }
                Button("Status") { setField(.property, propertyName: "Status") }
                Button("Author") { setField(.author) }
            } label: {
                HStack(spacing: 3) {
                    Text(fieldLabel)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(OakStyle.Font.styledCaption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(OakStyle.Colors.buttonBackground, in: RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Operator label (non-interactive, inferred from field)
            Text(operatorLabel)
                .font(OakStyle.Font.styledCaption)
                .foregroundStyle(.secondary)

            // Value picker
            valuePicker
                .fixedSize()

            Spacer()

            // Remove button
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    private var operatorLabel: String {
        switch condition.op {
        case .eq: return "is"
        case .neq: return "is not"
        case .contains: return "contains"
        case .hasOption: return "has"
        case .withinDays: return "within"
        }
    }

    @ViewBuilder
    private var valuePicker: some View {
        switch condition.field {
        case .itemType:
            Menu {
                ForEach([ItemType.pdf, .webSnapshot, .embed, .markdown], id: \.rawValue) { type in
                    Button(type.label) {
                        condition.value = type.rawValue
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(itemTypeLabel)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(OakStyle.Font.styledCaption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(OakStyle.Colors.buttonBackground, in: RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton)

        case .property:
            propertyValuePicker

        case .author:
            TextField("Author", text: $condition.value)
                .font(OakStyle.Font.styledCaption)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: 120)
                .background(OakStyle.Colors.buttonBackground, in: RoundedRectangle(cornerRadius: 5))

        default:
            TextField("Value", text: $condition.value)
                .font(OakStyle.Font.styledCaption)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: 120)
                .background(OakStyle.Colors.buttonBackground, in: RoundedRectangle(cornerRadius: 5))
        }
    }

    @ViewBuilder
    private var propertyValuePicker: some View {
        let options = propertyOptions()
        Menu {
            ForEach(options, id: \.id) { option in
                Button(option.name) {
                    condition.value = option.name
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(condition.value.isEmpty ? "Select..." : condition.value)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(OakStyle.Font.styledCaption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(OakStyle.Colors.buttonBackground, in: RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton)
    }

    private var itemTypeLabel: String {
        ItemType(rawValue: condition.value)?.label ?? condition.value
    }

    private func propertyOptions() -> [PropertyOption] {
        guard let pid = condition.propertyId,
              let prop = store.properties.first(where: { $0.id.uuidString == pid })
        else { return [] }
        return prop.options
    }

    private func setField(_ field: FilterField, propertyName: String? = nil) {
        condition.field = field

        if field == .property, let name = propertyName,
           let prop = store.properties.first(where: { $0.name == name }) {
            condition.propertyId = prop.id.uuidString
            condition.op = .hasOption
            condition.value = prop.options.first?.name ?? ""
        } else if field == .itemType {
            condition.propertyId = nil
            condition.op = .eq
            condition.value = ItemType.pdf.rawValue
        } else if field == .author {
            condition.propertyId = nil
            condition.op = .contains
            condition.value = ""
        } else {
            condition.propertyId = nil
            condition.op = .eq
            condition.value = ""
        }
    }
}

// MARK: - Filter Pill

struct FilterPillView: View {
    let label: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(OakStyle.Font.styledCaption)
                .lineLimit(1)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

// MARK: - Helpers

extension FilterCondition {
    /// Human-readable label for display in filter pills.
    func displayLabel(store: LibraryStore) -> String {
        switch field {
        case .itemType:
            let typeLabel = ItemType(rawValue: value)?.label ?? value
            return "Type: \(typeLabel)"
        case .author:
            return "Author: \(value)"
        case .property:
            if let pid = propertyId,
               let prop = store.properties.first(where: { $0.id.uuidString == pid }) {
                return "\(prop.name): \(value)"
            }
            return "Property: \(value)"
        default:
            return "\(field.rawValue): \(value)"
        }
    }
}
