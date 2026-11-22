import Accelerate
import AVFoundation
import Foundation

enum BeatSyncEngine {
    private static let sampleRate = 16_000

    /// Beat positions are relative to the start of the supplied music range.
    static func beats(in asset: AVAsset, track: AVAssetTrack, range: CMTimeRange) throws -> [Double] {
        var beats: [Double] = []
        var lastStrength = 0.0
        var previousBass: Float = 0
        var bassWindow = [Float](repeating: 0, count: 160)
        var previousEnergy = 0.0
        var previousBassEnergy = 0.0
        var mean = 0.0
        var deviation = 0.0
        var previous = (time: 0.0, strength: 0.0, threshold: 0.0)
        var beforePrevious = 0.0

        func pickPeak(next: Double) {
            guard previous.strength > previous.threshold, previous.strength >= next,
                  previous.strength > beforePrevious else { return }
            if let last = beats.last, previous.time - last < 0.20 {
                guard previous.strength > lastStrength else { return }
                beats[beats.count - 1] = previous.time
            } else {
                beats.append(previous.time)
            }
            lastStrength = previous.strength
        }

        try readWindows(asset: asset, track: track, range: range, frames: 160) { samples, count, time in
            // A 180 Hz low-pass gives kick attacks weight alongside broadband percussion.
            for i in 0..<count {
                previousBass += 0.068 * (samples[i] - previousBass)
                bassWindow[i] = previousBass
            }
            var bassRMS: Float = 0
            vDSP_rmsqv(bassWindow, 1, &bassRMS, vDSP_Length(count))
            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
            let energy = log1p(80 * Double(rms))
            let bassEnergy = log1p(80 * Double(bassRMS))
            let onset = max(0, energy - previousEnergy) + 0.8 * max(0, bassEnergy - previousBassEnergy)
            pickPeak(next: onset)
            beforePrevious = previous.strength
            previous = (time, onset, max(0.12, mean + 2.0 * deviation))
            deviation += 0.025 * (abs(onset - mean) - deviation)
            mean += 0.025 * (onset - mean)
            previousEnergy = max(energy, previousEnergy - 0.12)
            previousBassEnergy = max(bassEnergy, previousBassEnergy - 0.12)
        }
        pickPeak(next: 0)
        return beats
    }

    /// RMS activity in the inserted audio slice, expressed on the Reel timeline.
    static func voiceIntervals(in asset: AVAsset, track: AVAssetTrack, range: CMTimeRange,
                               reelStart: CMTime) throws -> [Range<Double>] {
        var intervals: [Range<Double>] = []
        var noiseFloor = -58.0
        var start: Double?
        var lastEnd = 0.0
        var voicedDuration = 0.0

        func finish() {
            if let start, voicedDuration >= 0.055 {
                intervals.append((reelStart.seconds + start)..<(reelStart.seconds + lastEnd))
            }
            start = nil
            voicedDuration = 0
        }

        try readWindows(asset: asset, track: track, range: range, frames: 320) { samples, count, time in
            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
            let db = 20 * log10(max(0.00001, Double(rms)))
            if start != nil, time - lastEnd > 0.14 { finish() }
            let threshold = max(-46, noiseFloor + 10) - (start == nil ? 0 : 3)
            if db > threshold {
                if start == nil { start = time }
                lastEnd = min(range.duration.seconds, time + Double(count) / Double(sampleRate))
                voicedDuration += lastEnd - time
            } else {
                // Estimate the background between syllables, including during long takes.
                noiseFloor += (db - noiseFloor) * (db < noiseFloor ? 0.12 : 0.035)
            }
        }
        finish()
        return intervals
    }

    /// Decode directly into fixed-size analysis windows, including windows spanning PCM buffers.
    private static func readWindows(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, frames: Int,
                                    consume: (UnsafePointer<Float>, Int, Double) -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        let failure = ReelExporter.ExportError.exportFailed("Não foi possível analisar o áudio.")
        guard reader.canAdd(output) else { throw failure }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? failure }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var window = [Float](repeating: 0, count: frames)
        var filled = 0
        var windowStart = 0.0
        let rate = Double(sampleRate)
        let stride = MemoryLayout<Float>.stride
        var hasMoreSamples = true
        while hasMoreSamples {
            hasMoreSamples = try autoreleasepool {
                try Task.checkCancellation()
                guard let sample = output.copyNextSampleBuffer() else { return false }
                let count = CMSampleBufferGetNumSamples(sample)
                guard count > 0 else { return true }
                let start = (CMSampleBufferGetPresentationTimeStamp(sample) - range.start).seconds
                guard start.isFinite, let block = CMSampleBufferGetDataBuffer(sample),
                      CMBlockBufferGetDataLength(block) >= count * stride else { throw failure }
                var index = Int(min(Double(count), ceil(max(0, -start * rate))))
                let end = Int(min(Double(count), ceil(max(0, (range.duration.seconds - start) * rate))))
                if filled > 0, abs(start - (windowStart + Double(filled) / rate)) > 1.5 / rate {
                    window.withUnsafeBufferPointer { consume($0.baseAddress!, filled, windowStart) }
                    filled = 0
                }
                while index < end {
                    if filled == 0 { windowStart = max(0, start + Double(index) / rate) }
                    let n = min(frames - filled, end - index)
                    let status = window.withUnsafeMutableBytes { bytes in
                        CMBlockBufferCopyDataBytes(block, atOffset: index * stride, dataLength: n * stride,
                                                   destination: bytes.baseAddress!.advanced(by: filled * stride))
                    }
                    guard status == noErr else { throw failure }
                    filled += n
                    index += n
                    if filled == frames {
                        window.withUnsafeBufferPointer { consume($0.baseAddress!, filled, windowStart) }
                        filled = 0
                    }
                }
                return true
            }
        }
        guard reader.status == .completed else { throw reader.error ?? failure }
        if filled > 0 { window.withUnsafeBufferPointer { consume($0.baseAddress!, filled, windowStart) } }
    }
}
