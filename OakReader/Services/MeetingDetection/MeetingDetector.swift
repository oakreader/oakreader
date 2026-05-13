import Foundation

// MARK: - Signal Source

enum MeetingSignalSource: String, Sendable {
    case powerAssertion
    case windowTitle
    case browserTitle
}

// MARK: - App Identifier

struct MeetingAppIdentifier: Hashable, Sendable {
    let bundleID: String
    let displayName: String
}

// MARK: - Meeting Signal

struct MeetingSignal: Sendable {
    let source: MeetingSignalSource
    let appIdentifier: MeetingAppIdentifier
    let confidence: Double
    let timestamp: Date
    let detail: String?

    init(
        source: MeetingSignalSource,
        appIdentifier: MeetingAppIdentifier,
        confidence: Double,
        detail: String? = nil
    ) {
        self.source = source
        self.appIdentifier = appIdentifier
        self.confidence = confidence
        self.timestamp = Date()
        self.detail = detail
    }
}

// MARK: - Meeting Detector Protocol

protocol MeetingDetector: Sendable {
    func detect() async -> [MeetingSignal]
}

// MARK: - Meeting Assessment

struct MeetingAssessment: Sendable {
    let candidate: MeetingAppIdentifier
    let confidence: Double
    let signals: [MeetingSignal]

    var isMeeting: Bool { confidence >= 0.6 }
}

// MARK: - Meeting App Registry

enum MeetingAppRegistry {

    // MARK: Native Meeting Apps

    struct NativeApp {
        let bundleID: String
        let displayName: String
        /// Window title substrings that indicate an active call (lowercased).
        let activePatterns: [String]
        /// Window title substrings that indicate the app is idle (lowercased).
        let idlePatterns: [String]
    }

    static let nativeApps: [NativeApp] = [
        NativeApp(
            bundleID: "us.zoom.xos",
            displayName: "Zoom",
            activePatterns: ["zoom meeting", "zoom webinar"],
            idlePatterns: ["zoom workplace"]
        ),
        NativeApp(
            bundleID: "com.microsoft.teams2",
            displayName: "Microsoft Teams",
            activePatterns: [" | microsoft teams"],
            idlePatterns: ["chat |", "calendar |", "activity |"]
        ),
        NativeApp(
            bundleID: "com.microsoft.teams",
            displayName: "Microsoft Teams",
            activePatterns: [" | microsoft teams"],
            idlePatterns: ["chat |", "calendar |", "activity |"]
        ),
        NativeApp(
            bundleID: "com.tencent.meeting",
            displayName: "Tencent Meeting",
            activePatterns: [],
            idlePatterns: []
        ),
        NativeApp(
            bundleID: "com.electron.lark",
            displayName: "Lark",
            activePatterns: [],
            idlePatterns: []
        ),
        NativeApp(
            bundleID: "com.alibaba.DingTalkMac",
            displayName: "DingTalk",
            activePatterns: [],
            idlePatterns: []
        ),
        NativeApp(
            bundleID: "Cisco-Systems.Spark",
            displayName: "Webex",
            activePatterns: [],
            idlePatterns: []
        ),
        NativeApp(
            bundleID: "com.webex.meetingmanager",
            displayName: "Webex Meetings",
            activePatterns: [],
            idlePatterns: []
        ),
    ]

    /// All native meeting app bundle IDs for quick lookup.
    static let nativeBundleIDs: Set<String> = Set(nativeApps.map(\.bundleID))

    /// Look up a native app definition by bundle ID.
    static func nativeApp(for bundleID: String) -> NativeApp? {
        nativeApps.first { $0.bundleID == bundleID }
    }

    // MARK: Browser Apps

    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
    ]

    // MARK: Browser Meeting Patterns

    struct BrowserPattern {
        let urlPattern: String
        let label: String
    }

    static let browserMeetingPatterns: [BrowserPattern] = [
        BrowserPattern(urlPattern: "meet.google.com", label: "Google Meet"),
        BrowserPattern(urlPattern: "zoom.us/j/", label: "Zoom"),
        BrowserPattern(urlPattern: "zoom.us/wc/", label: "Zoom"),
        BrowserPattern(urlPattern: "teams.microsoft.com", label: "Microsoft Teams"),
        BrowserPattern(urlPattern: "teams.live.com", label: "Microsoft Teams"),
        BrowserPattern(urlPattern: "webex.com/meet", label: "Webex"),
        BrowserPattern(urlPattern: "webex.com/join", label: "Webex"),
    ]
}
