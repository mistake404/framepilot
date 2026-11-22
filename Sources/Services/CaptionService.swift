import Foundation
import AVFoundation
import Speech
import CoreImage
import UIKit

struct CaptionCue {
    let start: Double
    let end: Double
    let words: [String]
    let activeIndex: Int
}

enum CaptionService {
    private static let font = UIFont.systemFont(ofSize: 58, weight: .black)
    private static let maxTextWidth: CGFloat = 850

    struct Word: Identifiable, Hashable {
        let id = UUID()
        var text: String
        let start: Double
        let end: Double
    }

    struct Transcription {
        var words: [Word]
        let sourceOrigin: Double

        func cues(in range: CMTimeRange, at reelStart: CMTime) -> [CaptionCue] {
            let cleanWords = words.compactMap { word -> Word? in
                let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return Word(text: trimmed.uppercased(), start: word.start, end: word.end)
            }
            return CaptionService.makeCues(cleanWords, sourceStart: range.start.seconds - sourceOrigin,
                                           duration: range.duration.seconds, reelStart: reelStart.seconds)
        }
    }

    /// Convenience helper to transcribe a full video clip URL for interactive caption review/editing.
    static func transcribeClip(_ url: URL, recognizer: SFSpeechRecognizer) async -> Transcription? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let audio = try? await asset.loadTracks(withMediaType: .audio).first,
              let audioRange = try? await audio.load(.timeRange),
              audioRange.duration.isNumeric, audioRange.duration > .zero else {
            return nil
        }
        return await transcribe(url, audioTrack: audio, trackStart: audioRange.start,
                                range: audioRange, recognizer: recognizer)
    }

    static func localRecognizer() async -> SFSpeechRecognizer? {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-PT")) ?? SFSpeechRecognizer(),
              recognizer.supportsOnDeviceRecognition,
              Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
        else { return nil }

        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        return status == .authorized && recognizer.isAvailable ? recognizer : nil
    }

    static func transcribe(_ url: URL, audioTrack: AVAssetTrack, trackStart: CMTime,
                           range: CMTimeRange, recognizer: SFSpeechRecognizer) async -> Transcription? {
        var recognitionURL = url
        var sourceOrigin = 0.0
        var temporaryURL: URL?
        defer { if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) } }

        // A movie with a delayed audio track has two possible time origins. Give
        // Speech the relevant audio starting at zero, then map it back to the source.
        if trackStart != .zero {
            let audio = AVMutableComposition()
            guard let track = audio.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return nil }
            do {
                try track.insertTimeRange(range, of: audioTrack, at: .zero)
            } catch { return nil }
            guard let export = AVAssetExportSession(asset: audio, presetName: AVAssetExportPresetAppleM4A)
            else { return nil }
            recognitionURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
            temporaryURL = recognitionURL
            export.outputURL = recognitionURL
            export.outputFileType = .m4a
            await export.export()
            guard export.status == .completed, !Task.isCancelled else { return nil }
            sourceOrigin = range.start.seconds
        }

        let request = SFSpeechURLRecognitionRequest(url: recognitionURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        // finish() is idempotent, including a late error after a final result.
        let results = AsyncStream<[Word]> { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let words = result.bestTranscription.segments.map {
                        Word(text: $0.substring.uppercased(with: recognizer.locale),
                             start: $0.timestamp, end: $0.timestamp + $0.duration)
                    }
                    continuation.yield(words)
                    continuation.finish()
                } else if error != nil {
                    continuation.finish()
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { task.cancel() }
            }
        }

        for await words in results {
            return Transcription(words: words, sourceOrigin: sourceOrigin)
        }
        return nil
    }

    private static func makeCues(_ words: [Word], sourceStart: Double, duration: Double,
                                 reelStart: Double) -> [CaptionCue] {
        let sourceEnd = sourceStart + duration
        var cues: [CaptionCue] = []
        var group: [Word] = []
        var lineWidth: CGFloat = 0
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let spaceWidth = (" " as NSString).size(withAttributes: attributes).width

        func flush() {
            let labels = group.map(\.text)
            for (index, word) in group.enumerated() {
                cues.append(CaptionCue(start: reelStart + (word.start - sourceStart),
                                       end: reelStart + (word.end - sourceStart),
                                       words: labels, activeIndex: index))
            }
            group.removeAll(keepingCapacity: true)
            lineWidth = 0
        }

        for (index, word) in words.enumerated() {
            let nextStart = index + 1 < words.count ? words[index + 1].start : sourceEnd
            let start = max(sourceStart, word.start)
            let spokenEnd = word.end > word.start ? word.end : word.start + 0.12
            // Bridge sub-frame recognition gaps to avoid a flash between words.
            let visibleEnd = nextStart - spokenEnd < 1.0 / 30 ? nextStart : spokenEnd
            let end = min(sourceEnd, nextStart, visibleEnd)
            guard end > start, !word.text.isEmpty else { continue }

            let width = (word.text as NSString).size(withAttributes: attributes).width
            if group.count == 3 || group.last.map({ start - $0.end > 0.35 }) == true
                || (!group.isEmpty && lineWidth + spaceWidth + width > maxTextWidth) {
                flush()
            }
            lineWidth += (group.isEmpty ? 0 : spaceWidth) + width
            group.append(Word(text: word.text, start: start, end: end))
        }
        flush()
        return cues
    }

    /// One tight, single-scale bitmap per active word, cached by the compositor.
    static func badge(for cue: CaptionCue, scale pixelScale: CGFloat) -> CIImage? {
        let text = NSMutableAttributedString(string: "")
        for (index, word) in cue.words.enumerated() {
            let color: UIColor = index == cue.activeIndex ? .yellow : .white
            text.append(NSAttributedString(string: (index == 0 ? "" : " ") + word, attributes: [
                .font: font, .foregroundColor: color
            ]))
        }

        let textSize = text.size()
        guard textSize.width > 0 else { return nil }
        let scale = min(1, maxTextWidth / textSize.width)
        let size = CGSize(width: ceil(textSize.width * scale) + 48, height: ceil(font.lineHeight) + 24)
        let format = UIGraphicsImageRendererFormat()
        format.scale = pixelScale
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.black.withAlphaComponent(0.83).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 20).fill()
            let context = renderer.cgContext
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: scale, y: scale)
            text.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2))
        }
        return image.cgImage.map { CIImage(cgImage: $0) }
    }
}
