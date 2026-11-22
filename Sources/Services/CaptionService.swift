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

    private struct Word {
        let text: String
        let start: Double
        let end: Double
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

    static func cues(for url: URL, audioTrack: AVAssetTrack, trackStart: CMTime,
                     range: CMTimeRange, reelStart: CMTime,
                     recognizer: SFSpeechRecognizer) async -> [CaptionCue] {
        var recognitionURL = url
        var sourceStart = range.start.seconds
        var temporaryURL: URL?
        defer { if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) } }

        // A movie with a delayed audio track has two possible time origins. Give
        // Speech exactly the inserted audio, starting at zero, for these clips.
        if trackStart != .zero {
            let audio = AVMutableComposition()
            guard let track = audio.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return [] }
            do {
                try track.insertTimeRange(range, of: audioTrack, at: .zero)
            } catch { return [] }
            guard let export = AVAssetExportSession(asset: audio, presetName: AVAssetExportPresetAppleM4A)
            else { return [] }
            recognitionURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
            temporaryURL = recognitionURL
            export.outputURL = recognitionURL
            export.outputFileType = .m4a
            await export.export()
            guard export.status == .completed, !Task.isCancelled else { return [] }
            sourceStart = 0
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
            return makeCues(words, sourceStart: sourceStart, duration: range.duration.seconds,
                            reelStart: reelStart.seconds)
        }
        return []
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
    static func badge(for cue: CaptionCue) -> CIImage? {
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
        format.scale = 1
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
