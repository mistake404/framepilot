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

enum ReelTransition: String, CaseIterable, Identifiable {
    case cut = "Corte Seco"
    case zoomPunch = "Zoom Punch"
    case whipBlur = "Whip Blur"
    case filmFlash = "Flash 35mm"

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

struct ClipTrim: Equatable {
    var startSeconds: Double
    var endSeconds: Double
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
        preserve4K: Bool = true,
        includeSoundDesign: Bool = true,
        includeViralCaptions: Bool = false,
        musicURL: URL? = nil,
        beatSyncEnabled: Bool = true,
        autoDuckingEnabled: Bool = true,
        transition: ReelTransition = .cut,
        removeSilences: Bool = false,
        customLUTURL: URL? = nil,
        precomputedTranscriptions: [URL: CaptionService.Transcription] = [:],
        clipTrims: [URL: ClipTrim] = [:]
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

        var renderSize = CGSize(width: 1080, height: 1920)
        var clips: [ReelInstruction] = []
        var sharedPortraitTransform: CGAffineTransform?
        var cursor = CMTime.zero
        var sources: [(URL, AVURLAsset, AVAssetTrack, CMTimeRange)] = []
        var maximumDuration = CMTime.zero
        for url in videoURLs {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { continue }
            var range = try await video.load(.timeRange)
            guard range.start.isNumeric, range.duration.isNumeric, range.duration.seconds > 0.05 else { continue }
            if let trim = clipTrims[url] {
                let total = range.duration.seconds
                let startSec = max(0, min(trim.startSeconds, total - 0.15))
                let endSec = max(startSec + 0.15, min(trim.endSeconds, total))
                if endSec - startSec >= 0.15 {
                    let timescale: CMTimeScale = 600
                    let startOffset = CMTime(seconds: startSec, preferredTimescale: timescale)
                    let trimmedDuration = CMTime(seconds: endSec - startSec, preferredTimescale: timescale)
                    range = CMTimeRange(start: range.start + startOffset, duration: trimmedDuration)
                }
            }
            if preserve4K, renderSize.width == 1080 {
                let size = try await video.load(.naturalSize)
                if min(size.width, size.height) >= 2160, max(size.width, size.height) >= 3840 {
                    renderSize = CGSize(width: 2160, height: 3840)
                }
            }
            sources.append((url, asset, video, range))
            maximumDuration = maximumDuration + range.duration
        }
        guard !sources.isEmpty else { throw ExportError.noVideoClips }
        let music: Soundtrack?
        if let musicURL {
            music = try await Soundtrack(url: musicURL, maximumDuration: maximumDuration, detectBeats: beatSyncEnabled)
        } else {
            music = nil
        }
        var speech: [Range<Double>] = []
        let duckMusic = music != nil && autoDuckingEnabled
        let lut = customLUTURL.flatMap { try? CubeLUTLoader.load($0) }
        let recognizer = includeViralCaptions ? await CaptionService.localRecognizer() : nil
        for (url, asset, video, sourceRange) in sources {
            try Task.checkCancellation()
            let beatDuration = music?.cutDuration(at: cursor, available: sourceRange.duration)
            let range = CMTimeRange(start: sourceRange.start, duration: beatDuration ?? sourceRange.duration)
            let trimSilence = removeSilences && beatDuration == nil

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
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let audioRange = try await audio?.load(.timeRange) ?? .invalid
            let analysisRange = CMTimeRangeGetIntersection(range, otherRange: audioRange)
            var voice: [Range<Double>] = []
            var transcription: CaptionService.Transcription?
            if let audio, analysisRange.duration.isNumeric, analysisRange.duration > .zero {
                if trimSilence || duckMusic {
                    voice = try BeatSyncEngine.voiceIntervals(in: asset, track: audio, range: analysisRange)
                }
                if includeViralCaptions, let edited = precomputedTranscriptions[url] {
                    transcription = edited
                } else if let recognizer {
                    transcription = await CaptionService.transcribe(url, audioTrack: audio, trackStart: audioRange.start,
                                                                    range: analysisRange, recognizer: recognizer)
                }
            }

            let segments = trimSilence ? BeatSyncEngine.activeRanges(in: range, voiceIntervals: voice) : [range]
            var remainingVoice = voice[...]
            for segment in segments {
                try Task.checkCancellation()
                try compVideoTrack.insertTimeRange(segment, of: video, at: cursor)
                var cues: [CaptionCue] = []
                let overlap = CMTimeRangeGetIntersection(segment, otherRange: audioRange)
                if let audio, overlap.duration.isNumeric, overlap.duration > .zero {
                    guard let compAudioTrack else { throw ExportError.exporterCreationFailed }
                    let audioStart = cursor + (overlap.start - segment.start)
                    try compAudioTrack.insertTimeRange(overlap, of: audio, at: audioStart)
                    if duckMusic {
                        let offset = (audioStart - overlap.start).seconds
                        while let interval = remainingVoice.first, interval.lowerBound < overlap.end.seconds {
                            let start = max(interval.lowerBound, overlap.start.seconds)
                            let end = min(interval.upperBound, overlap.end.seconds)
                            if start < end { speech.append((start + offset)..<(end + offset)) }
                            if interval.upperBound > overlap.end.seconds { break }
                            remainingVoice = remainingVoice.dropFirst()
                        }
                    }
                    cues = transcription?.cues(in: overlap, at: audioStart) ?? []
                }
                clips.append(ReelInstruction(trackID: compVideoTrack.trackID,
                                             range: CMTimeRange(start: cursor, duration: segment.duration),
                                             size: size, transform: transform, look: look, cues: cues,
                                             transition: transition, lut: lut))
                cursor = cursor + segment.duration
            }
        }

        try Task.checkCancellation()

        let transitionCutTimes = clips.dropFirst().map { $0.timeRange.start }
        if transition != .cut {
            for (index, time) in transitionCutTimes.enumerated() {
                clips[index].outgoingCut = time.seconds
                clips[index + 1].incomingCut = time.seconds
            }
        }
        // Composition segments refer back to this WAV until the export finishes.
        let whooshURL = includeSoundDesign && !transitionCutTimes.isEmpty ? createCinematicWhooshAudioFile() : nil
        defer { if let whooshURL { try? FileManager.default.removeItem(at: whooshURL) } }
        if let whooshURL {
            try await insertWhooshes(from: whooshURL, at: transitionCutTimes, in: composition, end: cursor)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePilot-Reel-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let needsEffects = look != .original || lut != nil || clips.contains { $0.containsTweening }
        let videoComposition: AVVideoComposition?
        if let sharedPortraitTransform, !needsEffects,
           preserve4K || clips.first.map({ min($0.size.width, $0.size.height) <= 1080 }) == true {
            // Uniform portrait footage can keep its native dimensions and cadence.
            compVideoTrack.preferredTransform = sharedPortraitTransform
            videoComposition = nil
        } else {
            videoComposition = makeVideoComposition(for: clips, track: compVideoTrack,
                                                   renderSize: renderSize, needsEffects: needsEffects)
        }
        let musicMix = try music?.insert(in: composition, end: cursor, speech: speech)
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw ExportError.exporterCreationFailed }
        exportSession.audioMix = musicMix
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

    private struct Soundtrack {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let range: CMTimeRange
        let beats: [Double]

        init(url: URL, maximumDuration: CMTime, detectBeats: Bool) async throws {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ExportError.exportFailed("O ficheiro de música não contém uma pista de áudio.")
            }
            let range = try await track.load(.timeRange)
            guard range.start.isNumeric, range.duration.isNumeric, range.duration > .zero else {
                throw ExportError.exportFailed("A faixa de música tem uma duração inválida.")
            }
            self.asset = asset
            self.track = track
            self.range = range
            let analysisRange = CMTimeRange(start: range.start, duration: min(range.duration, maximumDuration))
            beats = detectBeats ? try BeatSyncEngine.beats(in: asset, track: track, range: analysisRange) : []
        }

        func cutDuration(at start: CMTime, available: CMTime) -> CMTime? {
            let minimum = CMTime(value: 4, timescale: 5)
            guard available >= minimum, let lastBeat = beats.last else { return nil }
            let end = (start + available).seconds
            let period = range.duration.seconds
            let cycleStart = floor(end / period) * period
            // Prefer the latest usable beat, including the tail of the previous loop.
            let beat = beats.last(where: { $0 <= end - cycleStart }).map { cycleStart + $0 }
                ?? (cycleStart - period + lastBeat)
            let length = CMTime(seconds: beat, preferredTimescale: 48_000) - start
            return length >= minimum && length <= available ? length : nil
        }

        func insert(in composition: AVMutableComposition, end: CMTime,
                    speech: [Range<Double>]) throws -> AVAudioMix {
            guard let music = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw ExportError.exporterCreationFailed }
            var cursor = CMTime.zero
            while cursor < end {
                try Task.checkCancellation()
                let duration = min(range.duration, end - cursor)
                try music.insertTimeRange(CMTimeRange(start: range.start, duration: duration), of: track, at: cursor)
                cursor = cursor + duration
            }
            let parameters = AVMutableAudioMixInputParameters(track: music)
            Self.applyVolume(to: parameters, end: end, speech: speech)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            return mix
        }

        private static func applyVolume(to parameters: AVMutableAudioMixInputParameters, end: CMTime,
                                        speech: [Range<Double>]) {
            let normal = 0.85, quiet = 0.22, ramp = 0.25
            let duration = end.seconds
            let fadeStart = max(0, duration - 0.8)
            var phrases: [Range<Double>] = []
            for span in speech {
                if let last = phrases.last, span.lowerBound - last.upperBound <= 2 * ramp {
                    phrases[phrases.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
                } else {
                    phrases.append(span)
                }
            }

            // Split at the fade boundary so ducking and fade-out share one continuous envelope.
            var time = 0.0
            var gain = normal
            var volume = normal
            var fadeCeiling = normal
            func mixTime(_ t: Double) -> CMTime {
                t >= duration ? end : CMTime(seconds: t, preferredTimescale: 48_000)
            }
            func emit(until stop: Double, gain target: Double) {
                var nextVolume = target
                if stop >= fadeStart {
                    // A release in the fade must never bring the music back up.
                    fadeCeiling = min(fadeCeiling, target)
                    nextVolume = fadeCeiling * (duration - stop) / (duration - fadeStart)
                }
                let interval = CMTimeRange(start: mixTime(time), end: mixTime(stop))
                if interval.duration > .zero {
                    parameters.setVolumeRamp(fromStartVolume: Float(volume), toEndVolume: Float(nextVolume),
                                             timeRange: interval)
                }
                time = stop
                gain = target
                volume = nextVolume
            }
            func segment(to stop: Double, gain target: Double) {
                let stop = min(duration, stop)
                if time < fadeStart, fadeStart < stop {
                    let fraction = (fadeStart - time) / (stop - time)
                    emit(until: fadeStart, gain: gain + (target - gain) * fraction)
                }
                emit(until: stop, gain: target)
            }
            for phrase in phrases {
                segment(to: max(0, phrase.lowerBound - ramp), gain: normal)
                segment(to: phrase.lowerBound, gain: quiet)
                segment(to: phrase.upperBound, gain: quiet)
                // Preserve the release slope when it runs into the end of the Reel.
                let release = min(ramp, max(0, duration - phrase.upperBound))
                segment(to: phrase.upperBound + release, gain: quiet + (normal - quiet) * release / ramp)
            }
            segment(to: duration, gain: normal)
        }
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
        func midpoint(after index: Int) -> CMTime {
            let earlier = cuts[index]
            return earlier + CMTimeMultiplyByRatio(cuts[index + 1] - earlier, multiplier: 1, divisor: 2)
        }
        for (index, cut) in cuts.enumerated() {
            let intendedStart = cut - lead
            // Split overlapping whooshes between cuts to keep both peaks in place.
            let previousBoundary = index > 0 ? midpoint(after: index - 1) : .zero
            let nextBoundary = index + 1 < cuts.count ? midpoint(after: index) : end
            let start = max(previousBoundary, intendedStart)
            let stop = min(intendedStart + range.duration, nextBoundary)
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
            // Warm highlights and lifted blacks.
            let warmed = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 5800, y: 5)
            ])
            return warmed.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.06,
                kCIInputContrastKey: 1.11,
                kCIInputBrightnessKey: 0.02
            ])
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

    fileprivate static func applyFilmGrain(to image: CIImage) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        return noise.cropped(to: image.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.065)
            ])
            .applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    }

    fileprivate static func applyTransition(_ transition: ReelTransition, to image: CIImage, in frame: CGRect,
                                            distanceToCut: Double) -> CIImage {
        let progress = max(0, 1 - distanceToCut / 0.12)
        guard progress > 0 else { return image }
        let strength = CGFloat(progress * progress * (3 - 2 * progress))
        switch transition {
        case .cut:
            return image
        case .zoomPunch:
            let scale = 1 + 0.12 * strength
            let zoom = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                         tx: frame.midX * (1 - scale), ty: frame.midY * (1 - scale))
            return image.transformed(by: zoom).cropped(to: frame)
        case .whipBlur:
            return image.clamped(to: frame).applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: frame.width * 0.065 * strength * strength,
                kCIInputAngleKey: 0
            ]).cropped(to: frame)
        case .filmFlash:
            let flash = strength * strength
            let exposed = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.85 * flash])
            let tint = CIColor(red: 1, green: 0.88, blue: 0.68, alpha: 0.36 * flash)
            return CIImage(color: tint).cropped(to: frame).composited(over: exposed)
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
    let transition: ReelTransition
    let lut: CubeLUTLoader?
    var incomingCut: Double?
    var outgoingCut: Double?
    let enablePostProcessing = false
    var containsTweening: Bool { !cues.isEmpty || incomingCut != nil || outgoingCut != nil }
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    var requiredSourceTrackIDs: [NSValue]? { [NSNumber(value: trackID)] }

    init(trackID: CMPersistentTrackID, range: CMTimeRange, size: CGSize, transform: CGAffineTransform,
         look: ReelLook, cues: [CaptionCue], transition: ReelTransition, lut: CubeLUTLoader?) {
        self.trackID = trackID
        self.timeRange = range
        self.size = size
        self.transform = transform
        self.look = look
        self.cues = cues
        self.transition = transition
        self.lut = lut
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
            let time = request.compositionTime.seconds
            let graded = ReelExporter.applyLook(clip.look, to: positioned.cropped(to: frame)).cropped(to: frame)
            let distance = min(abs(time - (clip.incomingCut ?? -.infinity)),
                               abs(time - (clip.outgoingCut ?? .infinity)))
            var result = ReelExporter.applyTransition(clip.transition, to: clip.lut?.apply(to: graded) ?? graded,
                                                      in: frame, distanceToCut: distance)
            if clip.look == .film35mm {
                result = ReelExporter.applyFilmGrain(to: result)
            }
            if let cue = clip.cue(at: time), let badge = badge(for: cue, scale: frame.width / 1080) {
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

    private func badge(for cue: CaptionCue, scale: CGFloat) -> CIImage? {
        let key = NSNumber(value: cue.start)
        if let cached = badges.object(forKey: key) { return cached }
        guard let image = CaptionService.badge(for: cue, scale: scale) else { return nil }
        badges.setObject(image, forKey: key)
        return image
    }
}
