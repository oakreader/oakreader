import SwiftUI

struct TagEditorView: View {
    let viewModel: DocumentViewModel

    @State private var tagTree: [AccessibilityTagNode] = []
    @State private var selectedNodeID: UUID?
    @State private var showAddTag = false
    @State private var newTagType: PDFTagType = .paragraph
    @State private var newAltText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Structure Tags")
                    .font(.headline)

                Spacer()

                Button {
                    showAddTag = true
                } label: {
                    Label("Add Tag", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button {
                    removeSelectedTag()
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .buttonStyle(.bordered)
                .disabled(selectedNodeID == nil)

                Button {
                    loadTagTree()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding(8)

            Divider()

            if tagTree.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.badge.plus")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Structure Tags")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Add structure tags to make this document accessible.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    OutlineGroup(tagTree, children: \.childrenOptional) { node in
                        TagNodeRow(
                            node: node,
                            isSelected: node.id == selectedNodeID,
                            onSelect: { selectedNodeID = node.id },
                            onChangeType: { newType in
                                updateTagType(nodeID: node.id, newType: newType)
                            }
                        )
                    }
                }
                .listStyle(.bordered)
            }

            // Selected tag properties
            if let nodeID = selectedNodeID, let node = findNode(id: nodeID) {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Tag Properties")
                        .font(.caption)
                        .fontWeight(.medium)

                    LabeledContent("Type") {
                        Picker("", selection: Binding(
                            get: { node.tagType },
                            set: { updateTagType(nodeID: nodeID, newType: $0) }
                        )) {
                            ForEach(PDFTagType.allCases) { type in
                                Text(type.label).tag(type)
                            }
                        }
                        .frame(width: 150)
                    }

                    if node.tagType == .figure {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Alternative Text")
                                .font(.caption)
                            TextField("Alt text for image", text: Binding(
                                get: { node.alternativeText ?? "" },
                                set: { updateAltText(nodeID: nodeID, text: $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }

                    if let pageIndex = node.pageIndex {
                        Text("Page: \(pageIndex + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
        }
        .onAppear { loadTagTree() }
        .sheet(isPresented: $showAddTag) {
            addTagSheet
        }
    }

    private var addTagSheet: some View {
        VStack(spacing: 16) {
            Text("Add Structure Tag")
                .font(.headline)

            Picker("Tag Type:", selection: $newTagType) {
                ForEach(PDFTagType.allCases) { type in
                    Text(type.label).tag(type)
                }
            }

            if newTagType == .figure {
                TextField("Alternative Text", text: $newAltText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") {
                    showAddTag = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    addTag()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func loadTagTree() {
        tagTree = viewModel.accessibility.tagTree
    }

    private func addTag() {
        var node = AccessibilityTagNode(
            tagType: newTagType,
            pageIndex: viewModel.state.currentPageIndex
        )
        if newTagType == .figure {
            node.alternativeText = newAltText
        }
        tagTree.append(node)
        viewModel.accessibility.tagTree = tagTree
        showAddTag = false
        newAltText = ""
    }

    private func removeSelectedTag() {
        guard let id = selectedNodeID else { return }
        tagTree.removeAll { $0.id == id }
        viewModel.accessibility.tagTree = tagTree
        selectedNodeID = nil
    }

    private func updateTagType(nodeID: UUID, newType: PDFTagType) {
        updateNode(id: nodeID, in: &tagTree) { $0.tagType = newType }
        viewModel.accessibility.tagTree = tagTree
    }

    private func updateAltText(nodeID: UUID, text: String) {
        updateNode(id: nodeID, in: &tagTree) { $0.alternativeText = text }
        viewModel.accessibility.tagTree = tagTree
    }

    private func findNode(id: UUID) -> AccessibilityTagNode? {
        findNodeIn(id: id, nodes: tagTree)
    }

    private func findNodeIn(id: UUID, nodes: [AccessibilityTagNode]) -> AccessibilityTagNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = findNodeIn(id: id, nodes: node.children) { return found }
        }
        return nil
    }

    private func updateNode(id: UUID, in nodes: inout [AccessibilityTagNode], transform: (inout AccessibilityTagNode) -> Void) {
        for i in nodes.indices {
            if nodes[i].id == id {
                transform(&nodes[i])
                return
            }
            updateNode(id: id, in: &nodes[i].children, transform: transform)
        }
    }
}

private struct TagNodeRow: View {
    let node: AccessibilityTagNode
    let isSelected: Bool
    let onSelect: () -> Void
    let onChangeType: (PDFTagType) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconForTag(node.tagType))
                .font(.caption)
                .foregroundStyle(Color.accentColor)

            Text(node.tagType.label)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)

            if let alt = node.alternativeText, !alt.isEmpty {
                Text("(\(alt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let pageIndex = node.pageIndex {
                Text("p.\(pageIndex + 1)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private func iconForTag(_ type: PDFTagType) -> String {
        switch type {
        case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6:
            return "textformat.size"
        case .paragraph:
            return "text.alignleft"
        case .figure:
            return "photo"
        case .table, .tableRow, .tableHeaderCell, .tableDataCell:
            return "tablecells"
        case .list, .listItem:
            return "list.bullet"
        case .link:
            return "link"
        default:
            return "tag"
        }
    }
}

private extension AccessibilityTagNode {
    var childrenOptional: [AccessibilityTagNode]? {
        children.isEmpty ? nil : children
    }
}
