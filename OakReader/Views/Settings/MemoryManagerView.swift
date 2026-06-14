import SwiftUI

/// Lets the user inspect and edit what the agent remembers — either the global
/// user profile (`.user`) or one document's continuity notes (`.item`). Backs onto
/// `MemoryStore`, so edits here and background reflection operate on the same facts.
///
/// Styled to the app's Dia vocabulary: airy padding, hairline separators, muted
/// secondary text, soft hover, no heavy List chrome.
struct MemoryManagerView: View {
    let scope: MemoryScope
    var title: String = "Memory"

    @Environment(\.dismiss) private var dismiss
    @State private var facts: [MemoryFact] = []
    @State private var newText: String = ""
    @State private var showHistory = false
    @State private var log: [MemoryLogEntry] = []
    @State private var hoveredId: String?
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            content
            hairline
            addRow
        }
        .frame(width: 480, height: 540)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear(perform: reload)
    }

    private var hairline: some View {
        Rectangle()
            .fill(OakStyle.Colors.diaHairline)
            .frame(height: 1)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: OakStyle.Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(scope == .user
                     ? "Durable facts about you — always available to the agent."
                     : "Notes about this document — used only when it's open.")
                    .font(.system(size: 11))
                    .foregroundStyle(OakStyle.Colors.textSecondary)
            }
            Spacer(minLength: OakStyle.Spacing.sm)
            HStack(spacing: OakStyle.Spacing.xs) {
                iconButton("clock.arrow.circlepath", active: showHistory, help: "Change history") {
                    showHistory.toggle()
                    if showHistory { log = MemoryStore.recentLog(scope: scope) }
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(height: 22)
        }
        .padding(.horizontal, OakStyle.Spacing.md)
        .padding(.vertical, 14)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if facts.isEmpty && !showHistory {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if showHistory { historyBlock }
                    ForEach($facts) { $fact in
                        factRow($fact)
                    }
                }
                .padding(OakStyle.Spacing.sm)
            }
        }
    }

    private func factRow(_ fact: Binding<MemoryFact>) -> some View {
        let hovered = hoveredId == fact.wrappedValue.id
        return HStack(alignment: .top, spacing: OakStyle.Spacing.sm) {
            Button {
                let p = !fact.wrappedValue.pinned
                fact.wrappedValue.pinned = p
                MemoryStore.setPinned(p, id: fact.wrappedValue.id, scope: scope)
            } label: {
                Image(systemName: fact.wrappedValue.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(fact.wrappedValue.pinned ? Color.accentColor : OakStyle.Colors.textTertiary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(fact.wrappedValue.pinned ? "Pinned — protected from auto-edits" : "Pin to protect from auto-edits")
            .padding(.top, 1)

            TextField("Fact", text: fact.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { MemoryStore.update(id: fact.wrappedValue.id, text: fact.wrappedValue.text, scope: scope) }

            Text(sourceLabel(fact.wrappedValue.source))
                .font(.system(size: 10))
                .foregroundStyle(OakStyle.Colors.textTertiary)
                .padding(.top, 1)

            Button {
                MemoryStore.delete(id: fact.wrappedValue.id, scope: scope)
                reload()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(OakStyle.Colors.textTertiary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help("Delete")
            .opacity(hovered ? 1 : 0)
            .padding(.top, 1)
        }
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                .fill(hovered ? OakStyle.Colors.hoverBackground : .clear)
        )
        .onHover { h in
            withAnimation(.easeOut(duration: 0.13)) { hoveredId = h ? fact.wrappedValue.id : (hoveredId == fact.wrappedValue.id ? nil : hoveredId) }
        }
    }

    private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RECENT CHANGES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OakStyle.Colors.textTertiary)
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.top, 4)
            if log.isEmpty {
                Text("No changes yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(OakStyle.Colors.textSecondary)
                    .padding(.horizontal, OakStyle.Spacing.sm)
            }
            ForEach(log) { entry in
                HStack(spacing: OakStyle.Spacing.xs) {
                    Text(entry.op)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color(for: entry.op))
                        .frame(width: 48, alignment: .leading)
                    Text(entry.after ?? entry.before ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(OakStyle.Colors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.vertical, 2)
            }
            Rectangle()
                .fill(OakStyle.Colors.diaHairline)
                .frame(height: 1)
                .padding(.vertical, 6)
        }
    }

    // MARK: Empty + add

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(OakStyle.Colors.textTertiary)
            Text("Nothing remembered yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OakStyle.Colors.textSecondary)
            Text(scope == .user
                 ? "Facts appear as you chat, or add one below."
                 : "Notes appear as you discuss this document, or add one below.")
                .font(.system(size: 11))
                .foregroundStyle(OakStyle.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var addRow: some View {
        HStack(spacing: OakStyle.Spacing.sm) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OakStyle.Colors.textTertiary)
            TextField("Add a fact…", text: $newText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($addFocused)
                .onSubmit(addFact)
        }
        .padding(.horizontal, OakStyle.Spacing.md)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    private func reload() {
        facts = MemoryStore.load(scope)
        if showHistory { log = MemoryStore.recentLog(scope: scope) }
    }

    private func addFact() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        MemoryStore.add(text, source: .user, scope: scope)
        newText = ""
        reload()
        addFocused = true
    }

    private func iconButton(_ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : OakStyle.Colors.textSecondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: OakStyle.Radius.small)
                        .fill(active ? Color.accentColor.opacity(0.12) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func sourceLabel(_ source: MemoryFact.Source) -> String {
        switch source {
        case .user: return "you"
        case .remember: return "saved"
        case .reflection: return "auto"
        }
    }

    private func color(for op: String) -> Color {
        switch op {
        case "ADD": return .green
        case "DELETE": return .red
        default: return .orange
        }
    }
}
