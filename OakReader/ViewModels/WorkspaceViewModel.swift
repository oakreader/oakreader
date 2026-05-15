import Foundation

@Observable
final class WorkspaceViewModel {
    let collectionId: UUID
    weak var appState: AppState?

    var sourceItems: [LibraryItem] = []
    var selectedSourceIDs: Set<UUID> = []
    var isSourcesPanelVisible: Bool = true
    var studioTab: WorkspaceStudioTab?

    // MARK: - Lazy ViewModels

    private var _chatVM: ChatViewModel?
    var chatVM: ChatViewModel {
        if let vm = _chatVM { return vm }
        let vm = ChatViewModel()
        vm.appState = appState
        vm.itemId = "workspace:\(collectionId.uuidString)"
        if let db = appState?.libraryStore.database {
            vm.sessionService = ConversationService(database: db)
        }
        _chatVM = vm
        return vm
    }

    private var _voiceVM: VoiceViewModel?
    var voiceVM: VoiceViewModel {
        if let vm = _voiceVM { return vm }
        let vm = VoiceViewModel()
        _voiceVM = vm
        return vm
    }

    init(collectionId: UUID) {
        self.collectionId = collectionId
    }

    // MARK: - Source Resolution

    func resolveSourceItems() {
        guard let store = appState?.libraryStore else { return }
        sourceItems = store.items.filter { item in
            item.collections.contains { $0.id == collectionId }
        }
        // Select all by default
        selectedSourceIDs = Set(sourceItems.map(\.id))
        syncChatSources()
    }

    // MARK: - Source Syncing

    func syncChatSources() {
        let selected = sourceItems.filter { selectedSourceIDs.contains($0.id) }
        let refs = selected.map { item in
            ChatCompletionItem.LibraryRefPayload(
                storageKey: item.storageKey,
                title: item.title,
                author: item.author,
                citeKey: item.citeKey,
                contentType: item.contentType.rawValue,
                pageCount: item.pageCount
            )
        }
        chatVM.scopedSources = refs
    }

    // MARK: - Source Selection

    func toggleSource(_ id: UUID) {
        if selectedSourceIDs.contains(id) {
            selectedSourceIDs.remove(id)
        } else {
            selectedSourceIDs.insert(id)
        }
        syncChatSources()
    }

    func selectAllSources() {
        selectedSourceIDs = Set(sourceItems.map(\.id))
        syncChatSources()
    }

    func deselectAllSources() {
        selectedSourceIDs = []
        syncChatSources()
    }
}
