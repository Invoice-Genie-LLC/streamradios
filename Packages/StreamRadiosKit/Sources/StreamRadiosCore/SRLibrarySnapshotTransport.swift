import Foundation

public enum SRLibrarySnapshotTransport {
    public static let applicationContextKey = "librarySnapshot"
    public static let snapshotRequestKey = "requestLibrarySnapshot"
    public static let episodeStateUpdateKey = "episodeStateUpdate"
    public static let mutationKey = "watchMutation"
    public static let mutationAcknowledgementKey = "watchMutationAcknowledgement"
    public static let bootstrapFileKey = "libraryBootstrap"

    public static func encode(_ snapshot: SRLibrarySnapshot) throws -> Data {
        try JSONEncoder().encode(snapshot)
    }

    public static func decode(_ data: Data) throws -> SRLibrarySnapshot {
        try JSONDecoder().decode(SRLibrarySnapshot.self, from: data)
    }

    public static func encode(_ bootstrap: SRWatchLibraryBootstrap) throws -> Data {
        try JSONEncoder().encode(bootstrap)
    }

    public static func decodeBootstrap(_ data: Data) throws -> SRWatchLibraryBootstrap {
        try JSONDecoder().decode(SRWatchLibraryBootstrap.self, from: data)
    }

    public static func encode(_ state: SREpisodeStateRecord) throws -> Data {
        try JSONEncoder().encode(state)
    }

    public static func decodeEpisodeState(_ data: Data) throws -> SREpisodeStateRecord {
        try JSONDecoder().decode(SREpisodeStateRecord.self, from: data)
    }

    public static func encode(_ mutation: SRWatchMutation) throws -> Data {
        try JSONEncoder().encode(mutation)
    }

    public static func decodeMutation(_ data: Data) throws -> SRWatchMutation {
        try JSONDecoder().decode(SRWatchMutation.self, from: data)
    }
}