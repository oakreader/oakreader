import SwiftUI

struct BatchOperationPicker: View {
    @Binding var selectedOperation: BatchOperationType

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Operation")
                .font(.caption)
                .fontWeight(.medium)

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ],
                spacing: 8
            ) {
                ForEach(BatchOperationType.allCases) { operation in
                    Button {
                        selectedOperation = operation
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: operation.systemImage)
                                .font(.body)
                                .frame(width: 20)

                            Text(operation.label)
                                .font(.caption)
                                .lineLimit(1)

                            Spacer()
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    selectedOperation == operation
                                        ? Color.accentColor.opacity(0.15)
                                        : Color(nsColor: .controlBackgroundColor)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    selectedOperation == operation
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.2),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
