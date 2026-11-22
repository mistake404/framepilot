import Foundation
import AVFoundation
import Photos
import UIKit

struct SessionTake: Identifiable {
    let id = UUID()
    let shotId: String
    let shotTitle: String
    let isVideo: Bool
    let fileURL: URL?
    let thumbnail: UIImage?
    let durationSeconds: Double
}

enum ReelExporter {
    enum ExportError: LocalizedError {
        case noVideoClips
        case exporterCreationFailed
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoClips:
                return "Grava pelo menos 1 plano em vídeo para montar o Reel."
            case .exporterCreationFailed:
                return "Não foi possível preparar o exportador de vídeo."
            case .exportFailed(let reason):
                return "Erro ao montar Reel: \(reason)"
            }
        }
    }

    /// Stitches recorded session video clips in storyboard order into a single video and saves it to Photos.
    static func exportReel(videoURLs: [URL]) async throws {
        guard !videoURLs.isEmpty else {
            throw ExportError.noVideoClips
        }

        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.exporterCreationFailed
        }

        let compAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursor = CMTime.zero
        var didSetTransform = false

        for url in videoURLs {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration.isNumeric && duration.seconds > 0.05 else { continue }
            let timeRange = CMTimeRange(start: .zero, duration: duration)

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if let sourceVideo = videoTracks.first {
                try compVideoTrack.insertTimeRange(timeRange, of: sourceVideo, at: cursor)
                if !didSetTransform {
                    compVideoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
                    didSetTransform = true
                }
            }

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if let sourceAudio = audioTracks.first, let compAudioTrack {
                try? compAudioTrack.insertTimeRange(timeRange, of: sourceAudio, at: cursor)
            }

            cursor = CMTimeAdd(cursor, duration)
        }

        guard cursor.seconds > 0.05 else {
            throw ExportError.noVideoClips
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePilot-Reel-\(UUID().uuidString).mov")

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.exporterCreationFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { continuation in
            exportSession.exportAsynchronously {
                continuation.resume()
            }
        }

        guard exportSession.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.exportFailed(exportSession.error?.localizedDescription ?? "Falha desconhecida")
        }

        try await saveVideoToPhotos(url: outputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }

    private static func saveVideoToPhotos(url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.exportFailed("Sem permissão de galeria")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? ExportError.exportFailed("Erro ao guardar na galeria"))
                }
            }
        }
    }
}
