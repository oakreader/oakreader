import Foundation

/// Where a Pocket TTS voice is from, for grouping the picker.
///
/// Users choose a voice by how it sounds, not by its name, so the picker groups by accent and
/// the raw ids (`fantine`, `p244`) stay out of the way. Scotland is in the British Isles, so
/// `eponine` groups with the English voices and carries its nation in the region string.
public enum PocketTTSAccent: Sendable, Hashable {
    case britishIsles(String)
    case northAmerica(String)
    case unspecified

    /// Section heading in the voice picker.
    public var group: String {
        switch self {
        case .britishIsles: return "British & Irish"
        case .northAmerica: return "North American"
        case .unspecified: return "Other"
        }
    }

    /// Short label shown next to the voice name.
    public var label: String? {
        switch self {
        case let .britishIsles(region), let .northAmerica(region): return region
        case .unspecified: return nil
        }
    }
}

/// Redistribution terms of the reference recording a voice was cloned from.
///
/// Tracked per voice because they differ, and one of them is restrictive: `cosette` comes from
/// the Expresso dataset under CC-BY-NC, so it must never be a shipped default.
public enum PocketTTSVoiceLicence: Sendable, Hashable {
    case ccBy40
    case cc0
    case ccByNonCommercial40

    /// Whether the voice is safe to use without a non-commercial restriction attached.
    public var allowsCommercialUse: Bool { self != .ccByNonCommercial40 }
}

/// One selectable voice: a precomputed CaLM KV cache published by Kyutai.
public struct PocketTTSVoice: Sendable, Identifiable, Hashable {
    /// Kyutai's voice id, which is also the `embeddings_v3/<id>.safetensors` basename.
    public let id: String
    /// Title-cased name for the picker.
    public let displayName: String
    public let accent: PocketTTSAccent
    public let licence: PocketTTSVoiceLicence
    /// Where the reference recording came from, for the attribution CC-BY requires.
    public let source: String

    /// "Fantine — English, Manchester", or just the name when the accent is unknown.
    public var pickerTitle: String {
        guard let label = accent.label else { return displayName }
        return "\(displayName) — \(label)"
    }
}

/// The voices Kyutai publishes in `embeddings_v3/`, with accents resolved to real regions.
///
/// Accents are not guesswork. Most of the English voices are VCTK speakers, and VCTK ships a
/// `speaker-info.txt` giving each speaker's accent and region; the ids below are the mapping
/// from Kyutai's voice list. Voices whose reference audio is a donation or a LibriVox reading
/// have no documented accent, so they are `.unspecified` rather than assumed.
public enum PocketTTSVoiceCatalog {
    public static let all: [PocketTTSVoice] = [
        // VCTK — CC-BY-4.0, accent and region from the corpus's own speaker-info.txt.
        .init(id: "anna", displayName: "Anna",
              accent: .britishIsles("English, Southern England"),
              licence: .ccBy40, source: "VCTK p228"),
        .init(id: "vera", displayName: "Vera",
              accent: .britishIsles("English, Southern England"),
              licence: .ccBy40, source: "VCTK p229"),
        .init(id: "fantine", displayName: "Fantine",
              accent: .britishIsles("English, Manchester"),
              licence: .ccBy40, source: "VCTK p244"),
        .init(id: "charles", displayName: "Charles",
              accent: .britishIsles("English, Surrey"),
              licence: .ccBy40, source: "VCTK p254"),
        .init(id: "paul", displayName: "Paul",
              accent: .britishIsles("English, Nottingham"),
              licence: .ccBy40, source: "VCTK p259"),
        .init(id: "eponine", displayName: "Éponine",
              accent: .britishIsles("Scottish, Edinburgh"),
              licence: .ccBy40, source: "VCTK p262"),
        .init(id: "azelma", displayName: "Azelma",
              accent: .northAmerica("Canadian, Toronto"),
              licence: .ccBy40, source: "VCTK p303"),
        .init(id: "george", displayName: "George",
              accent: .northAmerica("American, New England"),
              licence: .ccBy40, source: "VCTK p315"),
        .init(id: "mary", displayName: "Mary",
              accent: .northAmerica("American, Indiana"),
              licence: .ccBy40, source: "VCTK p333"),
        .init(id: "jane", displayName: "Jane",
              accent: .northAmerica("American, Pennsylvania"),
              licence: .ccBy40, source: "VCTK p339"),
        .init(id: "michael", displayName: "Michael",
              accent: .northAmerica("American, New Jersey"),
              licence: .ccBy40, source: "VCTK p360"),
        .init(id: "eve", displayName: "Eve",
              accent: .northAmerica("American, New Jersey"),
              licence: .ccBy40, source: "VCTK p361"),

        // Voice donations and LibriVox readings — CC0, no documented accent.
        .init(id: "javert", displayName: "Javert", accent: .unspecified,
              licence: .cc0, source: "Unmute voice donation"),
        .init(id: "marius", displayName: "Marius", accent: .unspecified,
              licence: .cc0, source: "Unmute voice donation"),
        .init(id: "bill_boerst", displayName: "Bill Boerst", accent: .unspecified,
              licence: .cc0, source: "Voice-Zero (LibriVox)"),
        .init(id: "caro_davy", displayName: "Caro Davy", accent: .unspecified,
              licence: .cc0, source: "Voice-Zero (LibriVox)"),
        .init(id: "peter_yearsley", displayName: "Peter Yearsley", accent: .unspecified,
              licence: .cc0, source: "Voice-Zero (LibriVox)"),
        .init(id: "stuart_bell", displayName: "Stuart Bell", accent: .unspecified,
              licence: .cc0, source: "Voice-Zero (LibriVox)"),

        // Other CC-BY-4.0 sources.
        .init(id: "alba", displayName: "Alba", accent: .unspecified,
              licence: .ccBy40, source: "Kyutai tts-voices (alba-mackenna)"),
        .init(id: "jean", displayName: "Jean", accent: .unspecified,
              licence: .ccBy40, source: "EARS p010"),

        // Expresso is CC-BY-NC. Kept because it is Kyutai's own demo voice and the one the
        // Core ML conversion was validated against, but it must never become a default.
        .init(id: "cosette", displayName: "Cosette", accent: .unspecified,
              licence: .ccByNonCommercial40, source: "Expresso ex04 (non-commercial)")
    ]

    /// The default read-aloud voice.
    ///
    /// A British CC-BY-4.0 voice on purpose: `cosette`, which upstream defaults to, carries a
    /// non-commercial restriction, and `alba`, the upstream fallback, has no documented accent.
    public static let defaultVoiceID = "fantine"

    /// Voices safe to ship without a non-commercial restriction.
    public static var commerciallyUsable: [PocketTTSVoice] {
        all.filter { $0.licence.allowsCommercialUse }
    }

    public static func voice(id: String) -> PocketTTSVoice? {
        all.first { $0.id == id }
    }

    /// Voices bucketed for the picker, British first because that is what most readers want.
    public static var grouped: [(group: String, voices: [PocketTTSVoice])] {
        let order = ["British & Irish", "North American", "Other"]
        return order.compactMap { group in
            let voices = all.filter { $0.accent.group == group }
            return voices.isEmpty ? nil : (group, voices)
        }
    }
}
