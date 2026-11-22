import Foundation
import AVFoundation
import CoreImage
import Photos
import UIKit

enum ReelLook: String, CaseIterable, Identifiable {
    case original = "Original"
    case film35mm = "35mm Película"
    case cinemaWarm = "Cinema Quente"
    case moody = "Moody"
    case mono = "P&B"

    var id: String { rawValue }
}

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

    /// Stitches recorded session video clips in storyboard order, applies optional cinematic color look, inserts transition sound design whooshes, and saves to Photos.
    static func exportReel(
        videoURLs: [URL],
        look: ReelLook = .original,
        includeSoundDesign: Bool = true
    ) async throws {
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
        var transitionCutTimes: [CMTime] = []

        for (index, url) in videoURLs.enumerated() {
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
            if index < videoURLs.count - 1 {
                transitionCutTimes.append(cursor)
            }
        }

        guard cursor.seconds > 0.05 else {
            throw ExportError.noVideoClips
        }

        // Insert synthesized cinematic whooshes at transition cuts
        if includeSoundDesign && !transitionCutTimes.isEmpty,
           let whooshURL = createCinematicWhooshAudioFile() {
            defer { try? FileManager.default.removeItem(at: whooshURL) }
            let whooshAsset = AVURLAsset(url: whooshURL)
            if let whooshTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ), let sourceWhooshAudio = try? await whooshAsset.loadTracks(withMediaType: .audio).first {
                let whooshDuration = (try? await whooshAsset.load(.duration)) ?? CMTime(seconds: 0.55, preferredTimescale: 44100)
                let halfLead = CMTime(seconds: 0.26, preferredTimescale: 44100)

                for cutTime in transitionCutTimes {
                    let insertStart = cutTime > halfLead ? CMTimeSubtract(cutTime, halfLead) : CMTime.zero
                    try? whooshTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: whooshDuration),
                        of: sourceWhooshAudio,
                        at: insertStart
                    )
                }
            }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePilot-Reel-\(UUID().uuidString).mov")

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.exporterCreationFailed
        }

        if look != .original {
            let videoComposition = AVMutableVideoComposition(
                asset: composition,
                applyingCIFiltersWithHandler: { request in
                    let source = request.sourceImage.clampedToExtent()
                    let graded = applyLook(look, to: source).cropped(to: request.sourceImage.extent)
                    request.finish(with: graded, context: nil)
                }
            )
            exportSession.videoComposition = videoComposition
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

    /// Synthesizes an in-memory 16-bit 44.1kHz mono WAV whoosh sound effect with cubic envelope and sub-bass drop.
    private static func createCinematicWhooshAudioFile() -> URL? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePilot-Whoosh-\(UUID().uuidString).wav")
        let sampleRate: Double = 44100.0
        let durationSeconds: Double = 0.52
        let totalSamples = Int(sampleRate * durationSeconds)
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let byteRate = Int32(Int(sampleRate) * Int(numChannels) * Int(bitsPerSample / 8))
        let blockAlign = Int16(numChannels * (bitsPerSample / 8))
        let dataSize = Int32(totalSamples * Int(numChannels) * Int(bitsPerSample / 8))
        let chunkSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        data.append(contentsOf: [UInt8]("WAVE".utf8))
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        let subchunk1Size: Int32 = 16
        let audioFormat: Int16 = 1
        data.append(contentsOf: withUnsafeBytes(of: subchunk1Size.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        data.append(contentsOf: [UInt8]("data".utf8))
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        var lastFilter: Double = 0.0
        for i in 0..<totalSamples {
            let t = Double(i) / sampleRate
            let normT = t / durationSeconds
            let envelope = pow(sin(normT * .pi), 2.2)

            let white = Double.random(in: -1.0...1.0)
            let filteredNoise = 0.18 * white + 0.82 * lastFilter
            lastFilter = filteredNoise

            // Sub-bass sweep: 88Hz down to 42Hz
            let freq = 88.0 - (46.0 * normT)
            let sub = sin(2.0 * .pi * freq * t) * 0.42

            let sample = (filteredNoise * 0.65 + sub) * envelope * 0.92
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767.0)
            data.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
        }

        do {
            try data.write(to: tempURL)
            return tempURL
        } catch {
            return nil
        }
    }

    private static func applyLook(_ look: ReelLook, to image: CIImage) -> CIImage {
        switch look {
        case .original:
            return image
        case .film35mm:
            // 35mm Analog Film emulation: warm highlight roll-off, lifted rich blacks, subtle soft-light grain
            let warmed = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 5800, y: 5)
            ])
            let filmCurve = warmed.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.06,
                kCIInputContrastKey: 1.11,
                kCIInputBrightnessKey: 0.02
            ])
            // Subtle analog grain via random generator
            if let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?
                .cropped(to: image.extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                    "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                    "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.065)
                ]) {
                return noise.applyingFilter("CISoftLightBlendMode", parameters: [
                    kCIInputBackgroundImageKey: filmCurve
                ])
            }
            return filmCurve
        case .cinemaWarm:
            // Warm highlights + subtle film contrast
            let warmed = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 5600, y: 4)
            ])
            return warmed.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.08,
                kCIInputContrastKey: 1.07
            ])
        case .moody:
            // Deep contrast, cooler shadows, slight desaturation
            let cooled = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 7200, y: -4)
            ])
            return cooled.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.86,
                kCIInputContrastKey: 1.14,
                kCIInputBrightnessKey: -0.03
            ])
        case .mono:
            // High-contrast cinema black & white
            let mono = image.applyingFilter("CIPhotoEffectNoir")
            return mono.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.08
            ])
        }
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
