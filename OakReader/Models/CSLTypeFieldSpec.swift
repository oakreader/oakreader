import Foundation

// MARK: - Type-Specific Field Specifications

/// Describes a single text field to show for a CSL item type.
struct CSLFieldSpec: Hashable {
    let key: String       // CSLItem property name (used with getField/setField)
    let label: String     // Display label (type-specific)
    let isMultiline: Bool

    init(_ key: String, _ label: String, multiline: Bool = false) {
        self.key = key
        self.label = label
        self.isMultiline = multiline
    }
}

/// Describes a creator role to show for a CSL item type.
struct CSLCreatorSpec: Hashable {
    let role: String      // CSL role key (used with getCreators/setCreators)
    let label: String     // Type-specific display label

    init(_ role: String, _ label: String) {
        self.role = role
        self.label = label
    }
}

/// The complete field+creator specification for one CSL item type.
struct CSLTypeSpec {
    let fields: [CSLFieldSpec]
    let creators: [CSLCreatorSpec]
}

// MARK: - Registry

/// Provides type-specific field and creator specs for each CSL item type.
enum CSLTypeFieldRegistry {

    /// Returns the field/creator spec for a given CSL item type.
    static func spec(for type: CSLItemType) -> CSLTypeSpec {
        switch type {
        case .articleJournal:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("containerTitle", "Journal"),
                    CSLFieldSpec("volume", "Volume"),
                    CSLFieldSpec("issue", "Issue"),
                    CSLFieldSpec("page", "Pages"),
                    CSLFieldSpec("DOI", "DOI"),
                    CSLFieldSpec("ISSN", "ISSN"),
                    CSLFieldSpec("journalAbbreviation", "Abbrev."),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("language", "Language"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                    CSLCreatorSpec("editor", "Editor"),
                    CSLCreatorSpec("translator", "Translator"),
                ]
            )

        case .book:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("collectionTitle", "Series"),
                    CSLFieldSpec("collectionNumber", "Series No."),
                    CSLFieldSpec("volume", "Volume"),
                    CSLFieldSpec("numberOfVolumes", "# Volumes"),
                    CSLFieldSpec("edition", "Edition"),
                    CSLFieldSpec("publisher", "Publisher"),
                    CSLFieldSpec("publisherPlace", "Place"),
                    CSLFieldSpec("ISBN", "ISBN"),
                    CSLFieldSpec("numberOfPages", "Pages"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("language", "Language"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                    CSLCreatorSpec("editor", "Editor"),
                    CSLCreatorSpec("translator", "Translator"),
                    CSLCreatorSpec("collection-editor", "Series Editor"),
                ]
            )

        case .chapter:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("containerTitle", "Book Title"),
                    CSLFieldSpec("collectionTitle", "Series"),
                    CSLFieldSpec("volume", "Volume"),
                    CSLFieldSpec("edition", "Edition"),
                    CSLFieldSpec("page", "Pages"),
                    CSLFieldSpec("chapterNumber", "Chapter"),
                    CSLFieldSpec("publisher", "Publisher"),
                    CSLFieldSpec("publisherPlace", "Place"),
                    CSLFieldSpec("ISBN", "ISBN"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                    CSLCreatorSpec("container-author", "Book Author"),
                    CSLCreatorSpec("editor", "Editor"),
                    CSLCreatorSpec("translator", "Translator"),
                ]
            )

        case .paperConference:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("containerTitle", "Proceedings"),
                    CSLFieldSpec("eventTitle", "Conference"),
                    CSLFieldSpec("eventPlace", "Place"),
                    CSLFieldSpec("volume", "Volume"),
                    CSLFieldSpec("page", "Pages"),
                    CSLFieldSpec("publisher", "Publisher"),
                    CSLFieldSpec("DOI", "DOI"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                    CSLCreatorSpec("editor", "Editor"),
                ]
            )

        case .thesis:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("genre", "Thesis Type"),
                    CSLFieldSpec("publisher", "University"),
                    CSLFieldSpec("publisherPlace", "Place"),
                    CSLFieldSpec("numberOfPages", "Pages"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("language", "Language"),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                ]
            )

        case .report:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("number", "Report No."),
                    CSLFieldSpec("genre", "Report Type"),
                    CSLFieldSpec("collectionTitle", "Series"),
                    CSLFieldSpec("publisher", "Institution"),
                    CSLFieldSpec("publisherPlace", "Place"),
                    CSLFieldSpec("numberOfPages", "Pages"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                ]
            )

        case .webpage:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("containerTitle", "Website Title"),
                    CSLFieldSpec("URL", "URL"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("language", "Language"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                ]
            )

        case .articleNewspaper:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("containerTitle", "Newspaper"),
                    CSLFieldSpec("section", "Section"),
                    CSLFieldSpec("page", "Pages"),
                    CSLFieldSpec("edition", "Edition"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("language", "Language"),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                ]
            )

        case .articleMagazine:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("containerTitle", "Magazine"),
                    CSLFieldSpec("volume", "Volume"),
                    CSLFieldSpec("issue", "Issue"),
                    CSLFieldSpec("page", "Pages"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("language", "Language"),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                ]
            )

        case .patent:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("number", "Patent No."),
                    CSLFieldSpec("authority", "Issuing Authority"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Inventor"),
                ]
            )

        case .motionPicture:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("containerTitle", "Series"),
                    CSLFieldSpec("medium", "Format"),
                    CSLFieldSpec("publisher", "Distributor"),
                    CSLFieldSpec("publisherPlace", "Place"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("director", "Director"),
                    CSLCreatorSpec("author", "Producer"),
                    CSLCreatorSpec("script-writer", "Scriptwriter"),
                    CSLCreatorSpec("performer", "Cast"),
                ]
            )

        case .article:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("containerTitle", "Repository"),
                    CSLFieldSpec("DOI", "DOI"),
                    CSLFieldSpec("number", "Article No."),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("language", "Language"),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                    CSLCreatorSpec("editor", "Editor"),
                ]
            )

        case .software:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("version", "Version"),
                    CSLFieldSpec("genre", "System"),
                    CSLFieldSpec("publisher", "Company"),
                    CSLFieldSpec("URL", "URL"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                ],
                creators: [
                    CSLCreatorSpec("author", "Programmer"),
                ]
            )

        case .graphic:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("medium", "Medium"),
                    CSLFieldSpec("dimensions", "Dimensions"),
                    CSLFieldSpec("archive", "Archive"),
                    CSLFieldSpec("archiveLocation", "Location"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Artist"),
                ]
            )

        case .speech:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("genre", "Presentation Type"),
                    CSLFieldSpec("eventTitle", "Conference/Meeting"),
                    CSLFieldSpec("eventPlace", "Place"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("language", "Language"),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Presenter"),
                ]
            )

        case .interview:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("medium", "Medium"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Interviewee"),
                    CSLCreatorSpec("interviewer", "Interviewer"),
                ]
            )

        case .personalCommunication:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("genre", "Type"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("language", "Language"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                    CSLCreatorSpec("recipient", "Recipient"),
                ]
            )

        case .manuscript:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("genre", "Manuscript Type"),
                    CSLFieldSpec("publisher", "Library/Archive"),
                    CSLFieldSpec("publisherPlace", "Place"),
                    CSLFieldSpec("numberOfPages", "Pages"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("language", "Language"),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                    CSLCreatorSpec("translator", "Translator"),
                ]
            )

        case .map:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("genre", "Map Type"),
                    CSLFieldSpec("scale", "Scale"),
                    CSLFieldSpec("edition", "Edition"),
                    CSLFieldSpec("publisher", "Publisher"),
                    CSLFieldSpec("publisherPlace", "Place"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Cartographer"),
                ]
            )

        case .legislation:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("number", "Statute No."),
                    CSLFieldSpec("section", "Section"),
                    CSLFieldSpec("volume", "Code"),
                    CSLFieldSpec("page", "Pages"),
                    CSLFieldSpec("authority", "Authority"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                ]
            )

        case .bill:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("number", "Bill No."),
                    CSLFieldSpec("section", "Section"),
                    CSLFieldSpec("volume", "Code"),
                    CSLFieldSpec("page", "Pages"),
                    CSLFieldSpec("authority", "Authority"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Sponsor"),
                ]
            )

        case .legalCase:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("number", "Docket No."),
                    CSLFieldSpec("volume", "Reporter Volume"),
                    CSLFieldSpec("containerTitle", "Reporter"),
                    CSLFieldSpec("page", "First Page"),
                    CSLFieldSpec("authority", "Court"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                ]
            )

        case .hearing:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("number", "Document No."),
                    CSLFieldSpec("section", "Section"),
                    CSLFieldSpec("publisher", "Publisher"),
                    CSLFieldSpec("page", "Pages"),
                    CSLFieldSpec("authority", "Committee"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                ]
            )

        case .entryEncyclopedia:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("containerTitle", "Encyclopedia"),
                    CSLFieldSpec("volume", "Volume"),
                    CSLFieldSpec("edition", "Edition"),
                    CSLFieldSpec("page", "Pages"),
                    CSLFieldSpec("publisher", "Publisher"),
                    CSLFieldSpec("publisherPlace", "Place"),
                    CSLFieldSpec("ISBN", "ISBN"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                    CSLCreatorSpec("editor", "Editor"),
                ]
            )

        case .entryDictionary:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("containerTitle", "Dictionary"),
                    CSLFieldSpec("volume", "Volume"),
                    CSLFieldSpec("edition", "Edition"),
                    CSLFieldSpec("page", "Pages"),
                    CSLFieldSpec("publisher", "Publisher"),
                    CSLFieldSpec("publisherPlace", "Place"),
                    CSLFieldSpec("ISBN", "ISBN"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                    CSLCreatorSpec("editor", "Editor"),
                ]
            )

        case .postWeblog:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("containerTitle", "Blog Title"),
                    CSLFieldSpec("URL", "URL"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("language", "Language"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                ]
            )

        case .post:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("containerTitle", "Forum Title"),
                    CSLFieldSpec("URL", "URL"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("language", "Language"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                ]
            )

        case .broadcast:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("containerTitle", "Program"),
                    CSLFieldSpec("number", "Episode No."),
                    CSLFieldSpec("medium", "Format"),
                    CSLFieldSpec("publisher", "Network"),
                    CSLFieldSpec("publisherPlace", "Place"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                ],
                creators: [
                    CSLCreatorSpec("director", "Director"),
                    CSLCreatorSpec("author", "Producer"),
                    CSLCreatorSpec("guest", "Guest"),
                ]
            )

        case .song:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("containerTitle", "Album"),
                    CSLFieldSpec("medium", "Format"),
                    CSLFieldSpec("publisher", "Label"),
                    CSLFieldSpec("volume", "Volume"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Performer"),
                    CSLCreatorSpec("composer", "Composer"),
                    CSLCreatorSpec("producer", "Producer"),
                ]
            )

        case .dataset:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("version", "Version"),
                    CSLFieldSpec("number", "Dataset No."),
                    CSLFieldSpec("publisher", "Repository"),
                    CSLFieldSpec("DOI", "DOI"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                ]
            )

        case .standard:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("number", "Standard No."),
                    CSLFieldSpec("authority", "Issuing Body"),
                    CSLFieldSpec("publisher", "Publisher"),
                    CSLFieldSpec("edition", "Edition"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                ]
            )

        case .review:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("reviewedTitle", "Reviewed Work"),
                    CSLFieldSpec("containerTitle", "Publication"),
                    CSLFieldSpec("volume", "Volume"),
                    CSLFieldSpec("issue", "Issue"),
                    CSLFieldSpec("page", "Pages"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Reviewer"),
                    CSLCreatorSpec("reviewed-author", "Reviewed Author"),
                ]
            )

        case .regulation:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("number", "Regulation No."),
                    CSLFieldSpec("authority", "Authority"),
                    CSLFieldSpec("volume", "Code"),
                    CSLFieldSpec("page", "Pages"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                ]
            )

        case .treaty:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("number", "Treaty No."),
                    CSLFieldSpec("volume", "Volume"),
                    CSLFieldSpec("page", "Pages"),
                    CSLFieldSpec("publisher", "Publisher"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("URL", "URL"),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                ]
            )

        case .document:
            return CSLTypeSpec(
                fields: [
                    CSLFieldSpec("title", "Title"),
                    CSLFieldSpec("publisher", "Publisher"),
                    CSLFieldSpec("publisherPlace", "Place"),
                    CSLFieldSpec("abstract", "Abstract", multiline: true),
                    CSLFieldSpec("language", "Language"),
                    CSLFieldSpec("URL", "URL"),
                    CSLFieldSpec("note", "Note", multiline: true),
                ],
                creators: [
                    CSLCreatorSpec("author", "Author"),
                    CSLCreatorSpec("editor", "Editor"),
                ]
            )
        }
    }

    /// Returns the spec for a CSL type raw value string, falling back to document.
    static func spec(forRawType rawType: String) -> CSLTypeSpec {
        let itemType = CSLItemType(rawValue: rawType) ?? .document
        return spec(for: itemType)
    }
}
