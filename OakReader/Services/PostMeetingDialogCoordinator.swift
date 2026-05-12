import Foundation

/// Bridges MeetingDetectionService.onMeetingEnded → SwiftUI dialog presentation.
@Observable
final class PostMeetingDialogCoordinator {
    enum DialogState {
        case hidden
        case meetingEnded(MeetingDetectionService.MeetingSession, recordedItem: LibraryItem?)
    }

    var dialogState: DialogState = .hidden

    func show(session: MeetingDetectionService.MeetingSession, recordedItem: LibraryItem?) {
        dialogState = .meetingEnded(session, recordedItem: recordedItem)
    }

    func dismiss() {
        dialogState = .hidden
    }
}
