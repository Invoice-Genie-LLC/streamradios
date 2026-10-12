import Foundation

public struct SRSyncRevision: Codable, Equatable, Comparable, Sendable {
    public var counter: Int64
    public var deviceID: String

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.deviceID < rhs.deviceID : lhs.counter < rhs.counter
    }
}

public struct SRSyncChange: Codable, Equatable, Identifiable, Sendable {
    public var revision: SRSyncRevision
    public var mutation: SRWatchMutation
    public var id: String { "\(revision.deviceID):\(revision.counter)" }
    public var scope: String { mutation.syncScope }
}

extension SRWatchMutation {
    public var syncScope: String {
        switch self {
        case .stationFavorite(let value):
            return "station:\(Self.stationIdentity(value.streamURL))"
        case .episodeProgress(let value):
            return "progress:\(value.feedID)\u{1F}\(value.audioURL ?? value.episodeID)"
        case .episodeFavorite(let value):
            return "favorite:\(value.feedID)\u{1F}\(value.audioURL ?? value.episodeID)"
        case .stationPlayed(let value):
            return "played:\(Self.stationIdentity(value.streamURL))"
        }
    }

    public static func stationIdentity(_ value: String) -> String {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? value
    }

    public func hasSameValue(as other: Self) -> Bool {
        guard refersToSameField(as: other) else { return false }
        switch (self, other) {
        case (.stationFavorite(let lhs), .stationFavorite(let rhs)):
            return lhs.isFavorite == rhs.isFavorite
        case (.episodeFavorite(let lhs), .episodeFavorite(let rhs)):
            return lhs.isFavorite == rhs.isFavorite
        case (.episodeProgress(let lhs), .episodeProgress(let rhs)):
            return abs(lhs.progress - rhs.progress) < 0.000_001
                && (lhs.positionSeconds == nil || rhs.positionSeconds == nil || lhs.positionSeconds == rhs.positionSeconds)
        case (.stationPlayed(let lhs), .stationPlayed(let rhs)):
            return lhs.playedAt == rhs.playedAt
        default: return false
        }
    }

    public func refersToSameField(as other: Self) -> Bool {
        switch (self, other) {
        case (.stationFavorite(let lhs), .stationFavorite(let rhs)):
            return Self.stationIdentity(lhs.streamURL) == Self.stationIdentity(rhs.streamURL)
        case (.episodeProgress(let lhs), .episodeProgress(let rhs)):
            return lhs.feedID == rhs.feedID && (lhs.episodeID == rhs.episodeID
                || (lhs.audioURL != nil && lhs.audioURL == rhs.audioURL))
        case (.episodeFavorite(let lhs), .episodeFavorite(let rhs)):
            return lhs.feedID == rhs.feedID && (lhs.episodeID == rhs.episodeID
                || (lhs.audioURL != nil && lhs.audioURL == rhs.audioURL))
        case (.stationPlayed(let lhs), .stationPlayed(let rhs)):
            return Self.stationIdentity(lhs.streamURL) == Self.stationIdentity(rhs.streamURL)
        default: return false
        }
    }
}

@MainActor
public final class SRSyncJournal {
    nonisolated public static let messageKey = "versionedLibraryChange"
    nonisolated public static let acknowledgementKey = "versionedLibraryAck"

    private struct Storage: Codable, Sendable {
        var deviceID = UUID().uuidString
        var counter: Int64 = 0
        var latest: [String: SRSyncChange] = [:]
        var pending: [String: SRSyncChange] = [:]
        var unapplied: [String: SRSyncChange]?
    }

    private var storage: Storage
    private let url: URL
    private let queue = DispatchQueue(label: "StreamRadios.sync-journal")
    public var changes: [SRSyncChange] { Array(storage.latest.values) }
    public var pending: [SRSyncChange] { Array(storage.pending.values) }
    public var changesRequiringApplication: [SRSyncChange] { Array((storage.unapplied ?? [:]).values) }

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            storage = decoded
        } else {
            storage = Storage()
        }
    }

    public func record(_ mutation: SRWatchMutation) async throws -> SRSyncChange? {
        let change = stage(mutation)
        try await persist()
        return change
    }

    public func stage(_ mutation: SRWatchMutation) -> SRSyncChange? {
        let scope = scope(for: mutation)
        if let existing = storage.latest[scope], mutation.hasSameValue(as: existing.mutation) {
            return storage.pending[scope]
        }
        storage.counter = max(storage.counter + 1, Int64(Date().timeIntervalSince1970 * 1_000))
        let change = SRSyncChange(
            revision: SRSyncRevision(counter: storage.counter, deviceID: storage.deviceID),
            mutation: mutation
        )
        storage.latest[scope] = change
        storage.pending[scope] = change
        storage.unapplied?[scope] = nil
        return change
    }

    public func receive(_ change: SRSyncChange, requiringApplication: Bool = false) async throws {
        try await receive([change], requiringApplication: requiringApplication)
    }

    public func receive(_ changes: [SRSyncChange], requiringApplication: Bool = false) async throws {
        for change in changes {
            let scope = scope(for: change.mutation)
            storage.counter = max(storage.counter, change.revision.counter)
            if storage.latest[scope].map({ $0.revision < change.revision }) ?? true {
                storage.latest[scope] = change
                storage.pending[scope] = nil
                if requiringApplication {
                    if storage.unapplied == nil { storage.unapplied = [:] }
                    storage.unapplied?[scope] = change
                } else {
                    storage.unapplied?[scope] = nil
                }
            }
        }
        try await persist()
    }

    public func contains(_ mutation: SRWatchMutation) -> Bool {
        storage.latest[scope(for: mutation)] != nil
    }

    public func markApplied(_ change: SRSyncChange) {
        let scope = scope(for: change.mutation)
        if storage.unapplied?[scope]?.id == change.id {
            storage.unapplied?[scope] = nil
        }
    }

    public func acknowledge(_ id: String) async throws {
        storage.pending = storage.pending.filter { $0.value.id != id }
        try await persist()
    }

    public func latest(for change: SRSyncChange) -> SRSyncChange {
        storage.latest[scope(for: change.mutation)] ?? change
    }

    public func flush() async throws { try await persist() }

    /// For `willTerminate`, where no async work runs after the handler returns.
    public func flushSynchronously() {
        let snapshot = storage
        let destination = url
        queue.sync {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: destination, options: .atomic)
        }
    }

    private func scope(for mutation: SRWatchMutation) -> String {
        if storage.latest[mutation.syncScope] != nil { return mutation.syncScope }
        return storage.latest.first { $0.value.mutation.refersToSameField(as: mutation) }?.key ?? mutation.syncScope
    }

    private func persist() async throws {
        let snapshot = storage
        let destination = url
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let data = try JSONEncoder().encode(snapshot)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: destination, options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}