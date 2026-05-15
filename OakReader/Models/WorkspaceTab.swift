import Foundation

@Observable
final class WorkspaceTab: Identifiable {
    let id: UUID
    let collectionId: UUID
    var title: String
    let viewModel: WorkspaceViewModel

    init(collectionId: UUID, title: String, viewModel: WorkspaceViewModel) {
        self.id = UUID()
        self.collectionId = collectionId
        self.title = title
        self.viewModel = viewModel
    }
}
