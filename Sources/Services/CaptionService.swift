import Foundation
import AVFoundation
import Speech
import CoreImage
import UIKit

struct WordStamp {
    let word: String
    let startTime: Double
    let endTime: Double
}

struct RenderedCaption {
    let startTime: Double
    let endTime: Double
    let image: CIImage
}

enum CaptionService {

    /// Transcribes speech from an array of video clips with relative composition offsets,
    /// generating pre-rendered viral-style (Hormozi/TikTok) caption stamps.
    static func generateViralCaptions(for clips: [(url: URL, startTimeInReel: Double, duration: Double)]) async -> [RenderedCaption] {
        // Request authorization if needed
        let authStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard authStatus == .authorized else { return [] }

        // Prefer pt-PT or system locale recognizer
        let locale = Locale(identifier: "pt-PT")
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            return []
        }

        var allWords: [WordStamp] = []

        for clip in clips {
            let request = SFSpeechURLRecognitionRequest(url: clip.url)
            request.shouldReportPartialResults = false
            request.taskHint = .dictation

            let wordsInClip = await withCheckedContinuation { (continuation: CheckedContinuation<[WordStamp], Never>) in
                recognizer.recognitionTask(with: request) { result, error in
                    if let result = result, result.isFinal {
                        let segs = result.bestTranscription.segments.map { seg in
                            WordStamp(
                                word: seg.substring.uppercased(),
                                startTime: clip.startTimeInReel + seg.timestamp,
                                endTime: clip.startTimeInReel + seg.timestamp + max(0.22, seg.duration)
                            )
                        }
                        continuation.resume(returning: segs)
                    } else if error != nil {
                        continuation.resume(returning: [])
                    }
                }
            }
            allWords.append(contentsOf: wordsInClip)
        }

        guard !allWords.isEmpty else { return [] }

        // Group into short 2-3 word energetic clusters
        var renderedCaptions: [RenderedCaption] = []
        var i = 0
        while i < allWords.count {
            let count = min(3, allWords.count - i)
            let cluster = Array(allWords[i..<(i + count)])
            guard let first = cluster.first, let last = cluster.last else { break }

            let startTime = first.startTime
            let endTime = max(startTime + 0.6, last.endTime)

            // Render cluster with active word highlighted
            if let ciImage = renderClusterImage(words: cluster.map(\.word)) {
                renderedCaptions.append(
                    RenderedCaption(startTime: startTime, endTime: endTime, image: ciImage)
                )
            }
            i += count
        }

        return renderedCaptions
    }

    /// Renders bold viral subtitle badge (black rounded background, luminous yellow/white text)
    private static func renderClusterImage(words: [String]) -> CIImage? {
        let text = words.joined(separator: " ")
        let targetWidth: CGFloat = 820
        let targetHeight: CGFloat = 140
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetWidth, height: targetHeight))

        let uiImage = renderer.image { ctx in
            let fullRect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)

            // Dark semi-translucent pill
            let path = UIBezierPath(roundedRect: fullRect.insetBy(dx: 10, dy: 10), cornerRadius: 28)
            UIColor.black.withAlphaComponent(0.72).setFill()
            path.fill()

            // Subtle neon border
            UIColor.yellow.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 3
            path.stroke()

            // Text layout
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 42, weight: .black),
                .foregroundColor: UIColor(red: 1.0, green: 0.92, blue: 0.15, alpha: 1.0), // Hormozi neon yellow
                .strokeColor: UIColor.black,
                .strokeWidth: -3.0,
                .paragraphStyle: paragraphStyle
            ]

            let attributed = NSAttributedString(string: text, attributes: attrs)
            let textRect = CGRect(x: 20, y: (targetHeight - 54) / 2, width: targetWidth - 40, height: 60)
            attributed.draw(in: textRect)
        }

        guard let cg = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }
}
