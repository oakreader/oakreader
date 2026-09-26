import Foundation

struct FileCoordination {
    static func coordinatedRead(at url: URL, perform: (URL) throws -> Void) throws {
        var error: NSError?
        var thrownError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { readURL in
            do {
                try perform(readURL)
            } catch {
                thrownError = error
            }
        }
        if let error { throw error }
        if let thrownError { throw thrownError }
    }

    static func coordinatedWrite(at url: URL, perform: (URL) throws -> Void) throws {
        var error: NSError?
        var thrownError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &error) { writeURL in
            do {
                try perform(writeURL)
            } catch {
                thrownError = error
            }
        }
        if let error { throw error }
        if let thrownError { throw thrownError }
    }

    static func temporaryURL(for filename: String = UUID().uuidString, extension ext: String = "pdf") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
            .appendingPathExtension(ext)
    }

    static func fileSizeString(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func fileSizeString(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
