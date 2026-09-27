import Foundation

/// Wire types → domain models.
///
/// The domain models only know how to build themselves from GRDB record types
/// (`init(record:)`), and those inits carry real logic — decoding a filter rule
/// set, parsing CSL JSON, mapping raw strings onto enums. Reimplementing that
/// against the wire types would mean two copies of the same parsing, drifting
/// apart the first time either changed.
///
/// So the record types become the conversion layer instead: wire → record →
/// domain. They stay `Codable` structs with exactly the columns, and the
/// GRDB protocol conformances on them are simply unused once nothing queries
/// through them. That keeps this file to field mapping, which is all it should
/// ever have been.
///
/// This is also the answer to the coupling that made `AnnotationRecord` painful
/// to move: a record type is fine as a data shape, and only becomes a problem
/// when it leaks into views as the domain model.

// MARK: - Collections

extension PDFCollection {
    init(wire: CatalogCollection) {
        self.init(record: CollectionRecord(
            id: wire.id,
            userId: localUserId,
            name: wire.name,
            icon: wire.icon,
            sortOrder: wire.sortOrder,
            parentId: wire.parentId,
            isSmart: wire.isSmart,
            isSystem: wire.isSystem,
            filterRules: wire.filterRules,
            createdAt: wire.createdAt,
            updatedAt: wire.updatedAt,
            source: wire.source,
            sourceKey: wire.sourceKey
        ))
    }
}

// MARK: - Attachments

extension Attachment {
    init(wire: CatalogAttachment, itemStorageKey: String) {
        self.init(record: AttachmentRecord(
            id: wire.id,
            itemId: wire.itemId,
            storageKey: wire.storageKey,
            fileName: wire.fileName,
            contentType: wire.contentType,
            linkMode: wire.linkMode,
            sourceURL: wire.sourceUrl,
            fileSize: Int64(wire.fileSize),
            pageCount: wire.pageCount,
            isPrimary: wire.isPrimary,
            createdAt: "",
            updatedAt: ""
        ), itemStorageKey: itemStorageKey)
    }
}

// MARK: - Property values

extension PropertyValue {
    init(wire: CatalogPropertyValue) {
        // A select-type value carries its option; a free-text one does not.
        let option: PropertyOption? = wire.optionId.map { optionId in
            PropertyOption(
                id: UUID(uuidString: optionId) ?? UUID(),
                propertyId: UUID(uuidString: wire.propertyId) ?? UUID(),
                name: wire.optionName ?? "",
                colorHex: wire.optionColorHex ?? "999999"
            )
        }
        self.init(
            id: UUID(uuidString: wire.id) ?? UUID(),
            propertyId: UUID(uuidString: wire.propertyId) ?? UUID(),
            propertyName: wire.propertyName,
            propertyType: PropertyType(rawValue: wire.propertyType) ?? .text,
            option: option,
            textValue: wire.textValue
        )
    }
}

// MARK: - Items

extension LibraryItem {
    /// Build a library item from the core's graph.
    ///
    /// `collections` is left empty: the wire form carries collection *ids*, and
    /// resolving them needs the collection list the store holds. Sending whole
    /// collections per item would repeat 142 of them across 644 items, so
    /// `resolvingCollections` fills them in once both halves have arrived.
    init(wire: CatalogItem) {
        let record = ItemRecord(
            id: wire.id,
            userId: localUserId,
            storageKey: wire.storageKey,
            title: wire.title,
            author: wire.author,
            lastOpenedAt: wire.lastOpenedAt,
            syncStatus: "local",
            createdAt: wire.createdAt,
            updatedAt: wire.updatedAt,
            citeKey: wire.citeKey,
            lastPosition: wire.lastPosition,
            source: wire.source,
            sourceKey: wire.sourceKey,
            extra: wire.extra,
            processingStatus: wire.processingStatus,
            deletedAt: wire.deletedAt
        )
        self.init(
            record: record,
            attachments: wire.attachments.map {
                Attachment(wire: $0, itemStorageKey: wire.storageKey)
            },
            propertyValues: wire.propertyValues.map(PropertyValue.init(wire:)),
            collections: [],
            // Deliberately nil: covers are read lazily from the attachment's
            // storage key, never carried in the library graph.
            coverImageData: nil,
            referenceMetadata: wire.citationJson.flatMap { ReferenceMetadata(jsonString: $0) }
        )
    }

    /// Resolve collection ids against the loaded collection list.
    func resolvingCollections(_ ids: [String], from byId: [UUID: PDFCollection]) -> LibraryItem {
        guard !ids.isEmpty else { return self }
        var copy = self
        copy.collections = ids.compactMap { UUID(uuidString: $0).flatMap { byId[$0] } }
        return copy
    }
}

// MARK: - Properties

extension PropertyOption {
    init(wire: CatalogPropertyOption) {
        self.init(record: PropertyOptionRecord(
            id: wire.id,
            propertyId: wire.propertyId,
            name: wire.name,
            colorHex: wire.colorHex,
            position: wire.position
        ))
    }

    var wire: CatalogPropertyOption {
        CatalogPropertyOption(
            id: id.uuidString,
            propertyId: propertyId.uuidString,
            name: name,
            colorHex: colorHex,
            position: position
        )
    }
}

extension PropertyDefinition {
    init(wire: CatalogProperty) {
        self.init(
            record: PropertyRecord(
                id: wire.id,
                name: wire.name,
                type: wire.type,
                icon: wire.icon,
                position: wire.position,
                isSystem: wire.isSystem
            ),
            options: wire.options.map(PropertyOption.init(wire:))
        )
    }

}

// MARK: - Domain → wire

extension CatalogAttachment {
    init(record: AttachmentRecord) {
        self.init(
            id: record.id,
            itemId: record.itemId,
            storageKey: record.storageKey,
            fileName: record.fileName,
            contentType: record.contentType,
            linkMode: record.linkMode,
            sourceUrl: record.sourceURL,
            fileSize: Int(record.fileSize),
            pageCount: record.pageCount,
            isPrimary: record.isPrimary
        )
    }
}

extension CatalogItem {
    /// The wire form of a brand-new item, for insertion.
    ///
    /// Collections, citation and property values are empty by construction: an
    /// item acquires those afterwards, and the insert only writes the item and
    /// its attachments.
    init(record: ItemRecord, attachments: [AttachmentRecord]) {
        self.init(
            id: record.id,
            storageKey: record.storageKey,
            title: record.title,
            author: record.author,
            lastOpenedAt: record.lastOpenedAt,
            lastPosition: record.lastPosition,
            citeKey: record.citeKey,
            source: record.source,
            sourceKey: record.sourceKey,
            extra: record.extra,
            processingStatus: record.processingStatus,
            deletedAt: record.deletedAt,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            attachments: attachments.map(CatalogAttachment.init(record:)),
            collectionIds: [],
            citationJson: nil,
            propertyValues: []
        )
    }
}
