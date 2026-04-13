import SwiftUI

struct PageNavigationView: View {
    let viewModel: DocumentViewModel

    @State private var pageText: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.viewer.previousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!viewModel.viewer.canGoToPreviousPage)
            .help("Previous Page")

            HStack(spacing: 4) {
                TextField("Page", text: $pageText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .multilineTextAlignment(.center)
                    .onSubmit {
                        if let page = Int(pageText) {
                            viewModel.viewer.goToPage(page - 1)
                        }
                        syncPageText()
                    }

                Text("of \(viewModel.pageCount)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Button {
                viewModel.viewer.nextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!viewModel.viewer.canGoToNextPage)
            .help("Next Page")
        }
        .onAppear { syncPageText() }
        .onChange(of: viewModel.state.currentPageIndex) { _, _ in
            syncPageText()
        }
    }

    private func syncPageText() {
        pageText = "\(viewModel.state.currentPageIndex + 1)"
    }
}
