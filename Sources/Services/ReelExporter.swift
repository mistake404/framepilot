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

    /// Stitches recorded session video clips in storyboard order, applies optional cinematic color look, inserts transition sound design whooshes, auto-generates dynamic viral subtitles, and saves to Photos.
    static func exportReel(
        videoURLs: [URL],
        look: ReelLook = .original,
        includeSoundDesign: Bool = true,
        includeViralCaptions: Bool = false
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

        let renderSize = CGSize(width: 1080, height: 1920)
        var clips: [ReelInstruction] = []
        var sharedPortraitTransform: CGAffineTransform?
        var cursor = CMTime.zero
        let recognizer = includeViralCaptions ? await CaptionService.localRecognizer() : nil

        for url in videoURLs {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = try await video.load(.timeRange)
            guard range.start.isNumeric, range.duration.isNumeric, range.duration.seconds > 0.05 else { continue }

            let size = try await video.load(.naturalSize)
            let orientation = try await video.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: size).applying(orientation).standardized
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                throw ExportError.exportFailed("Dimensões de vídeo inválidas.")
            }
            if clips.isEmpty {
                if abs(bounds.width * 16 - bounds.height * 9) < 1 {
                    sharedPortraitTransform = orientation
                }
            } else if clips.first?.size != size || sharedPortraitTransform != orientation {
                sharedPortraitTransform = nil
            }
            let scale = max(renderSize.width / bounds.width, renderSize.height / bounds.height)
            let transform = orientation
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: renderSize.width / 2 - bounds.midX * scale,
                                                 y: renderSize.height / 2 - bounds.midY * scale))
            try compVideoTrack.insertTimeRange(range, of: video, at: cursor)

            var cues: [CaptionCue] = []
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if let audio = audioTracks.first {
                let audioRange = try await audio.load(.timeRange)
                let overlap = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                if overlap.duration.isNumeric, overlap.duration > .zero {
                    guard let compAudioTrack else { throw ExportError.exporterCreationFailed }
                    let audioStart = cursor + (overlap.start - range.start)
                    try compAudioTrack.insertTimeRange(overlap, of: audio, at: audioStart)
                    if let recognizer {
                        cues = await CaptionService.cues(for: url, audioTrack: audio, trackStart: audioRange.start,
                                                         range: overlap, reelStart: audioStart, recognizer: recognizer)
                    }
                }
            }
            clips.append(ReelInstruction(trackID: compVideoTrack.trackID,
                                         range: CMTimeRange(start: cursor, duration: range.duration),
                                         size: size, transform: transform, look: look, cues: cues))
            cursor = cursor + range.duration
        }

        guard !clips.isEmpty else { throw ExportError.noVideoClips }
        try Task.checkCancellation()

        // Composition segments refer back to this WAV until the export finishes.
        let whooshURL = includeSoundDesign && clips.count > 1 ? createCinematicWhooshAudioFile() : nil
        defer { if let whooshURL { try? FileManager.default.removeItem(at: whooshURL) } }
        if let whooshURL {
            let cuts = clips.dropFirst().map { $0.timeRange.start }
            try await insertWhooshes(from: whooshURL, at: cuts, in: composition, end: cursor)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePilot-Reel-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let needsEffects = look != .original || clips.contains { !$0.cues.isEmpty }
        let videoComposition: AVVideoComposition?
        if let sharedPortraitTransform, !needsEffects {
            // Uniform portrait footage can keep its native dimensions and cadence.
            compVideoTrack.preferredTransform = sharedPortraitTransform
            videoComposition = nil
        } else {
            videoComposition = makeVideoComposition(for: clips, track: compVideoTrack,
                                                   renderSize: renderSize, needsEffects: needsEffects)
        }
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw ExportError.exporterCreationFailed }
        exportSession.videoComposition = videoComposition
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = true

        await withTaskCancellationHandler {
            await exportSession.export()
        } onCancel: {
            exportSession.cancelExport()
        }
        try Task.checkCancellation()
        guard exportSession.status == .completed else {
            throw ExportError.exportFailed(exportSession.error?.localizedDescription ?? "Falha desconhecida")
        }
        try await saveVideoToPhotos(url: outputURL)
    }

    private static func makeVideoComposition(for clips: [ReelInstruction], track: AVCompositionTrack,
                                             renderSize: CGSize, needsEffects: Bool) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.sourceTrackIDForFrameTiming = track.trackID
        if needsEffects {
            videoComposition.customVideoCompositorClass = ReelCompositor.self
            videoComposition.instructions = clips
            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        } else {
            videoComposition.instructions = clips.map { clip in
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layer.setTransform(clip.transform, at: clip.timeRange.start)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = clip.timeRange
                instruction.layerInstructions = [layer]
                return instruction
            }
        }
        return videoComposition
    }

    private static func insertWhooshes(from url: URL, at cuts: [CMTime], in composition: AVMutableComposition,
                                       end: CMTime) async throws {
        let asset = AVURLAsset(url: url)
        guard let source = try await asset.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return }
        let range = try await source.load(.timeRange)
        let lead = CMTime(seconds: 0.26, preferredTimescale: 44100)
        for (index, cut) in cuts.enumerated() {
            let intendedStart = cut - lead
            let start = max(.zero, intendedStart)
            let nextStart = index + 1 < cuts.count ? max(.zero, cuts[index + 1] - lead) : end
            let stop = min(intendedStart + range.duration, nextStart, end)
            if start < stop {
                let slice = CMTimeRange(start: range.start + (start - intendedStart), duration: stop - start)
                try track.insertTimeRange(slice, of: source, at: start)
            }
        }
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

    fileprivate static func applyLook(_ look: ReelLook, to image: CIImage) -> CIImage {
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

private final class ReelInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let trackID: CMPersistentTrackID
    let timeRange: CMTimeRange
    let size: CGSize
    let transform: CGAffineTransform
    let look: ReelLook
    let cues: [CaptionCue]
    let enablePostProcessing = false
    var containsTweening: Bool { !cues.isEmpty }
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    var requiredSourceTrackIDs: [NSValue]? { [NSNumber(value: trackID)] }

    init(trackID: CMPersistentTrackID, range: CMTimeRange, size: CGSize, transform: CGAffineTransform,
         look: ReelLook, cues: [CaptionCue]) {
        self.trackID = trackID
        self.timeRange = range
        self.size = size
        self.transform = transform
        self.look = look
        self.cues = cues
    }

    func cue(at time: Double) -> CaptionCue? {
        var lower = 0
        var upper = cues.count
        while lower < upper {
            let mid = lower + (upper - lower) / 2
            if cues[mid].end <= time { lower = mid + 1 } else { upper = mid }
        }
        guard lower < cues.count, cues[lower].start <= time else { return nil }
        return cues[lower]
    }
}

// The iOS 18 SDK annotated the AVVideoCompositing dictionaries as Sendable.
#if compiler(>=6.0)
private typealias PixelBufferAttributes = [String: any Sendable]
#else
private typealias PixelBufferAttributes = [String: Any]
#endif

private final class ReelCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: PixelBufferAttributes? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                                      kCVPixelFormatType_32BGRA]]
    }
    var requiredPixelBufferAttributesForRenderContext: PixelBufferAttributes {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
    private let badges: NSCache<NSNumber, CIImage> = {
        let cache = NSCache<NSNumber, CIImage>()
        cache.countLimit = 3
        return cache
    }()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let clip = request.videoCompositionInstruction as? ReelInstruction,
                  let source = request.sourceFrame(byTrackID: clip.trackID),
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: ReelExporter.ExportError.exportFailed("Não foi possível compor um fotograma."))
                return
            }
            let image = CIImage(cvPixelBuffer: source)
            let frame = CGRect(origin: .zero, size: request.renderContext.size)
            // Track matrices use a top-left origin. Core Image uses bottom-left.
            let toTrack = CGAffineTransform(scaleX: clip.size.width / image.extent.width,
                                            y: -clip.size.height / image.extent.height)
                .concatenating(CGAffineTransform(translationX: 0, y: clip.size.height))
            let toCI = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: frame.height)
            let positioned = image.transformed(by: toTrack.concatenating(clip.transform).concatenating(toCI))
            var result = ReelExporter.applyLook(clip.look, to: positioned.cropped(to: frame)).cropped(to: frame)
            let time = request.compositionTime.seconds
            if let cue = clip.cue(at: time), let badge = badge(for: cue) {
                let progress = min(1, max(0, (time - cue.start) / 0.10))
                let scale = CGFloat(0.94 + 0.06 * progress)
                let pop = badge.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let offset = CGAffineTransform(translationX: frame.midX - pop.extent.midX,
                                               y: frame.height * 0.26 - pop.extent.midY)
                result = pop.transformed(by: offset).composited(over: result)
            }
            context.render(result, to: output, bounds: frame, colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: output)
        }
    }

    private func badge(for cue: CaptionCue) -> CIImage? {
        let key = NSNumber(value: cue.start)
        if let cached = badges.object(forKey: key) { return cached }
        guard let image = CaptionService.badge(for: cue) else { return nil }
        badges.setObject(image, forKey: key)
        return image
    }
}
