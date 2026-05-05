import SwiftUI

struct SmartCollectionEditorSheet: View {
    let store: LibraryStore
    let collection: PDFCollection?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var matchMode: FilterRuleSet.MatchMode = .all
    @State private var conditions: [FilterCondition] = [
        FilterCondition(field: .title, op: .contains, value: "")
    ]

    private var isEditing: Bool { collection != nil }

    var body: some View {
        VStack(spacing: 16) {
            Text(isEditing ? "Edit Smart Collection" : "New Smart Collection")
                .font(.headline)

            TextField("Collection Name", text: $name)
                .textFieldStyle(.roundedBorder)

            Divider()

            // Match mode
            HStack {
                Text("Match")
                    .font(.system(size: 13))
                Picker("", selection: $matchMode) {
                    Text("All").tag(FilterRuleSet.MatchMode.all)
                    Text("Any").tag(FilterRuleSet.MatchMode.any)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                Text("of the following conditions:")
                    .font(.system(size: 13))
                Spacer()
            }

            // Conditions
            VStack(spacing: 8) {
                ForEach(conditions.indices, id: \.self) { index in
                    conditionRow(index: index)
                }
            }

            Button {
                conditions.append(FilterCondition(field: .title, op: .contains, value: ""))
            } label: {
                Label("Add Condition", systemImage: "plus.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isEditing ? "Save" : "Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    let validConditions = conditions.filter { !$0.value.isEmpty }
                    let rules = FilterRuleSet(match: matchMode, conditions: validConditions)

                    if let collection {
                        store.renameCollection(collection, to: trimmed)
                        store.updateSmartCollectionRules(collection, rules: rules)
                    } else {
                        store.createSmartCollection(name: trimmed, icon: "magnifyingglass", rules: rules)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 480)
        .onAppear {
            if let collection {
                name = collection.name
                if let rules = collection.filterRules {
                    matchMode = rules.match
                    conditions = rules.conditions.isEmpty
                        ? [FilterCondition(field: .title, op: .contains, value: "")]
                        : rules.conditions
                }
            }
        }
    }

    // MARK: - Condition Row

    @ViewBuilder
    private func conditionRow(index: Int) -> some View {
        HStack(spacing: 6) {
            Picker("", selection: $conditions[index].field) {
                Text("Title").tag(FilterField.title)
                Text("Author").tag(FilterField.author)
                Text("Type").tag(FilterField.itemType)
                Text("Last Opened").tag(FilterField.lastOpenedAt)
                Text("Date Added").tag(FilterField.createdAt)
                Text("Property").tag(FilterField.property)
            }
            .frame(width: 100)

            Picker("", selection: $conditions[index].op) {
                ForEach(operatorsForField(conditions[index].field), id: \.self) { op in
                    Text(op.displayName).tag(op)
                }
            }
            .frame(width: 100)

            TextField("Value", text: $conditions[index].value)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 100)

            if conditions.count > 1 {
                Button {
                    conditions.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func operatorsForField(_ field: FilterField) -> [FilterOperator] {
        switch field {
        case .itemType:
            return [.eq, .neq]
        case .lastOpenedAt:
            return [.withinDays]
        case .title, .author:
            return [.eq, .neq, .contains]
        case .createdAt:
            return [.withinDays]
        case .property:
            return [.hasOption, .eq, .contains]
        }
    }
}

// MARK: - Display Names

private extension FilterOperator {
    var displayName: String {
        switch self {
        case .eq: return "is"
        case .neq: return "is not"
        case .contains: return "contains"
        case .withinDays: return "within days"
        case .hasOption: return "has option"
        }
    }
}
