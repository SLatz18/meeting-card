import Foundation

/// A local, opt-in store. No sample or transcript data crosses this API.
public final class SpeakerProfiles: @unchecked Sendable {
    public struct Profile: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
    }

    private struct Record: Codable {
        var id: UUID
        var name: String
        var embedding: SpeakerEmbedding
    }

    private let file: URL
    private let lock = NSLock()
    private var records: [Record] = []
    private var active = false

    public init(folder: URL) {
        file = folder.appendingPathComponent("SpeakerProfiles.json")
    }

    public var isEnabled: Bool { lock.withLock { active } }
    public var profiles: [Profile] {
        lock.withLock { records.map { Profile(id: $0.id, name: $0.name) } }
    }

    /// Disabling stops matching and clears the in-memory embeddings. Saved data stays deletable.
    public func setEnabled(_ enabled: Bool) throws {
        try lock.withLock {
            guard active != enabled else { return }
            records = enabled ? try read() : []
            active = enabled
        }
    }

    public func match(_ embedding: SpeakerEmbedding, excluding: Set<UUID> = []) -> Profile? {
        lock.withLock {
            guard active else { return nil }
            let candidates = records.compactMap { record in
                excluding.contains(record.id) ? nil : record.embedding.similarity(to: embedding).map { (record, $0) }
            }.sorted { $0.1 > $1.1 }
            guard let (match, score) = candidates.first, score >= embedding.profileThreshold,
                  candidates.count < 2 || score - candidates[1].1 >= 0.05 else { return nil }
            return Profile(id: match.id, name: match.name)
        }
    }

    public func save(name: String, embedding: SpeakerEmbedding) throws -> Profile {
        try lock.withLock {
            guard active else { throw StoreError.disabled }
            let clean = SpeakerLabels.clean(name)
            guard !clean.isEmpty else { throw StoreError.emptyName }
            let record = Record(id: UUID(), name: clean, embedding: embedding)
            let next = records + [record]
            try persist(next)
            records = next
            return Profile(id: record.id, name: clean)
        }
    }

    public func rename(_ id: UUID, to name: String) throws {
        try lock.withLock {
            guard active else { throw StoreError.disabled }
            let clean = SpeakerLabels.clean(name)
            guard !clean.isEmpty else { throw StoreError.emptyName }
            var next = records
            guard let i = next.firstIndex(where: { $0.id == id }) else { return }
            next[i].name = clean
            try persist(next)
            records = next
        }
    }

    public func delete(_ id: UUID) throws {
        try lock.withLock {
            guard active else { throw StoreError.disabled }
            let next = records.filter { $0.id != id }
            guard next.count != records.count else { return }
            try persist(next)
            records = next
        }
    }

    public func deleteAll() throws {
        try lock.withLock {
            try removeFile()
            records.removeAll()
        }
    }

    private func read() throws -> [Record] {
        do { return try JSONDecoder().decode([Record].self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    private func removeFile() throws {
        do { try FileManager.default.removeItem(at: file) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }

    private func persist(_ next: [Record]) throws {
        if next.isEmpty {
            try removeFile()
        } else {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
        }
    }

    private enum StoreError: Error { case disabled, emptyName }
}
