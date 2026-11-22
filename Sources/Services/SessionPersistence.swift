import Foundation

struct PersistedTake: Codable {
    let shotId: String
    let shotTitle: String
    let isVideo: Bool
    let filename: String?
    let durationSeconds: Double
}

struct PersistedSession: Codable {
    let packId: String
    let activeShotIndex: Int
    let freeModeTargetKind: ShotKind?
    let freeModeTargetDuration: Double
    let freeModeTakeOrder: [String]
    let completedShotIds: [String]
    let takes: [PersistedTake]
    let trims: [String: ClipTrim]
    let captionStyle: CaptionStyle
    let captionPosition: CaptionPosition
}

enum SessionPersistence {
    static var sessionDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("FramePilot", isDirectory: true)
            .appendingPathComponent("ActiveSession", isDirectory: true)
    }

    private static var manifestURL: URL {
        sessionDirectory.appendingPathComponent("session.json")
    }

    static func save(_ session: PersistedSession) {
        do {
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(session)
            try data.write(to: manifestURL, options: .atomic)
        } catch {}
    }

    static func load() -> PersistedSession? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(PersistedSession.self, from: data)
    }

    static func clearManifest() {
        try? FileManager.default.removeItem(at: manifestURL)
    }
}
