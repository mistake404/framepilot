import Foundation
import Combine
import ARKit
import CoreMotion
import CoreImage
import AVFoundation
import Photos
import UIKit

final class SpatialCameraEngine: NSObject, ObservableObject, ARSessionDelegate {
    let arSession = ARSession()

    @Published var telemetry = CameraTelemetry()
    @Published var selectedPack: ScenePack = ScenePack.presets[0]
    @Published var activeShotIndex: Int = 0
    @Published var completedShotIds: Set<String> = []
    @Published var captureMode: CaptureMode = .video
    @Published var isRecording: Bool = false
    @Published var recordingSeconds: Int = 0
    @Published var statusToast: String?
    @Published var showGrid: Bool = true

    private let motionManager = CMMotionManager()
    private let ciContext = CIContext()
    private let writerQueue = DispatchQueue(label: "com.framepilot.videoWriter")

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private var recordingStartTimestamp: CMTime?
    private var recordingTimer: Timer?

    private var latestPitchDegrees: Double = 0
    private var latestRollDegrees: Double = 0
    private var lastTelemetryUpdate: TimeInterval = 0
    private var wasLocked: Bool = false

    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let notificationFeedback = UINotificationFeedbackGenerator()

    var activeShot: ShotTemplate? {
        guard !selectedPack.shots.isEmpty, selectedPack.shots.indices.contains(activeShotIndex) else {
            return nil
        }
        return selectedPack.shots[activeShotIndex]
    }

    override init() {
        super.init()
        arSession.delegate = self
    }

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.isLightEstimationEnabled = true
        config.worldAlignment = .gravity

        var lidarAvailable = false
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
            lidarAvailable = true
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
            lidarAvailable = true
        }

        DispatchQueue.main.async {
            self.telemetry.hasLidarSupport = lidarAvailable
        }

        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        startMotionUpdates()
        impactFeedback.prepare()
    }

    func stop() {
        if isRecording {
            stopVideoRecording()
        }
        arSession.pause()
        motionManager.stopDeviceMotionUpdates()
    }

    func selectPack(_ pack: ScenePack) {
        selectedPack = pack
        activeShotIndex = 0
        completedShotIds.removeAll()
        if let first = pack.shots.first {
            captureMode = first.preferredMode
        }
        wasLocked = false
    }

    func selectShot(at index: Int) {
        guard selectedPack.shots.indices.contains(index) else { return }
        activeShotIndex = index
        captureMode = selectedPack.shots[index].preferredMode
        wasLocked = false
    }

    func toggleShotCompleted(_ shot: ShotTemplate) {
        if completedShotIds.contains(shot.id) {
            completedShotIds.remove(shot.id)
        } else {
            completedShotIds.insert(shot.id)
        }
    }

    // MARK: - CoreMotion (Pitch & Roll)

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            // Pitch: + degrees = looking up (contrapicado), - degrees = looking down (picado)
            let pitchRad = atan2(g.z, hypot(g.x, g.y))
            let pitchDeg = pitchRad * 180.0 / .pi

            // Roll relative to nearest 90° so horizon works in portrait and landscape
            let rawRollDeg = atan2(g.x, -g.y) * 180.0 / .pi
            let nearestRightAngle = (rawRollDeg / 90.0).rounded() * 90.0
            let horizonErrorDeg = rawRollDeg - nearestRightAngle

            self.latestPitchDegrees = pitchDeg
            self.latestRollDegrees = horizonErrorDeg
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if isRecording {
            appendVideoFrame(frame)
        }

        let now = frame.timestamp
        guard now - lastTelemetryUpdate >= 0.065 else { return }
        lastTelemetryUpdate = now

        let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
        let distance = depthMap.flatMap { Self.sampleCenterDepth(from: $0) }
        let lumens = Double(frame.lightEstimate?.ambientIntensity ?? 1000)
        let lighting = ShotCoachEngine.classifyLighting(lumens: lumens)

        let pitch = latestPitchDegrees
        let roll = latestRollDegrees
        let detected = ShotCoachEngine.detectShotKind(distanceMeters: distance, pitchDegrees: pitch)
        let target = activeShot
        let advice = ShotCoachEngine.evaluate(
            distanceMeters: distance,
            pitchDegrees: pitch,
            rollDegrees: roll,
            lighting: lighting,
            target: target
        )

        DispatchQueue.main.async {
            self.telemetry.lidarDistanceMeters = distance
            self.telemetry.pitchDegrees = pitch
            self.telemetry.rollDegrees = roll
            self.telemetry.ambientLumens = lumens
            self.telemetry.lighting = lighting
            self.telemetry.detectedShotKind = detected
            self.telemetry.advice = advice

            if advice.isLocked && !self.wasLocked {
                self.impactFeedback.impactOccurred()
            }
            self.wasLocked = advice.isLocked
        }
    }

    /// Samples a 5x5 patch around the center of the LiDAR depth map and returns median distance in meters.
    private static func sampleCenterDepth(from depthMap: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let centerX = width / 2
        let centerY = height / 2

        var samples: [Float] = []
        samples.reserveCapacity(25)

        for dy in -2...2 {
            let y = centerY + dy
            guard y >= 0, y < height else { continue }
            let rowPtr = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for dx in -2...2 {
                let x = centerX + dx
                guard x >= 0, x < width else { continue }
                let value = rowPtr[x]
                if value.isFinite && value > 0.08 && value < 8.0 {
                    samples.append(value)
                }
            }
        }

        guard !samples.isEmpty else { return nil }
        samples.sort()
        return Double(samples[samples.count / 2])
    }

    // MARK: - Capture Photo

    func capturePhoto() {
        guard let frame = arSession.currentFrame else { return }
        let pixelBuffer = frame.capturedImage
        let orientation = currentImageOrientation()

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                self.showToast("Permite acesso à galeria nas Definições")
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
            }) { success, _ in
                DispatchQueue.main.async {
                    if success {
                        self.notificationFeedback.notificationOccurred(.success)
                        self.markActiveShotCaptured()
                        self.showToast("Foto guardada na galeria")
                    } else {
                        self.showToast("Erro ao guardar foto")
                    }
                }
            }
        }
    }

    // MARK: - Capture Video

    func toggleVideoRecording() {
        if isRecording {
            stopVideoRecording()
        } else {
            startVideoRecording()
        }
    }

    private func startVideoRecording() {
        guard let frame = arSession.currentFrame else { return }
        let width = CVPixelBufferGetWidth(frame.capturedImage)
        let height = CVPixelBufferGetHeight(frame.capturedImage)
        let transform = currentVideoTransform()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramePilot-\(UUID().uuidString).mov")

        writerQueue.async { [weak self] in
            guard let self else { return }
            do {
                let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)
                let settings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height
                ]
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                input.transform = transform

                let attrs: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: attrs
                )

                guard writer.canAdd(input) else { return }
                writer.add(input)
                writer.startWriting()

                self.assetWriter = writer
                self.videoInput = input
                self.pixelBufferAdaptor = adaptor
                self.recordingURL = tempURL
                self.recordingStartTimestamp = nil

                DispatchQueue.main.async {
                    self.isRecording = true
                    self.recordingSeconds = 0
                    self.impactFeedback.impactOccurred()
                    self.recordingTimer?.invalidate()
                    self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                        self?.recordingSeconds += 1
                    }
                }
            } catch {
                self.showToast("Não foi possível iniciar vídeo")
            }
        }
    }

    private func appendVideoFrame(_ frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let timestamp = CMTime(seconds: frame.timestamp, preferredTimescale: 600)

        writerQueue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  let input = self.videoInput,
                  let adaptor = self.pixelBufferAdaptor,
                  writer.status == .writing,
                  input.isReadyForMoreMediaData else { return }

            if self.recordingStartTimestamp == nil {
                writer.startSession(atSourceTime: timestamp)
                self.recordingStartTimestamp = timestamp
            }

            guard let pool = adaptor.pixelBufferPool else { return }
            var renderedBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &renderedBuffer)
            if let renderedBuffer {
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                self.ciContext.render(ciImage, to: renderedBuffer)
                adaptor.append(renderedBuffer, withPresentationTime: timestamp)
            }
        }
    }

    private func stopVideoRecording() {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
        }

        writerQueue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  let input = self.videoInput,
                  let outputURL = self.recordingURL else { return }

            input.markAsFinished()
            writer.finishWriting { [weak self] in
                guard let self else { return }
                self.assetWriter = nil
                self.videoInput = nil
                self.pixelBufferAdaptor = nil
                self.recordingStartTimestamp = nil

                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    guard status == .authorized || status == .limited else {
                        self.showToast("Permite acesso à galeria nas Definições")
                        return
                    }
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
                    }) { success, _ in
                        try? FileManager.default.removeItem(at: outputURL)
                        DispatchQueue.main.async {
                            if success {
                                self.notificationFeedback.notificationOccurred(.success)
                                self.markActiveShotCaptured()
                                self.showToast("Vídeo guardado na galeria")
                            } else {
                                self.showToast("Erro ao guardar vídeo")
                            }
                        }
                    }
                }
            }
        }
    }

    private func markActiveShotCaptured() {
        guard let shot = activeShot else { return }
        completedShotIds.insert(shot.id)
        if activeShotIndex + 1 < selectedPack.shots.count {
            activeShotIndex += 1
            captureMode = selectedPack.shots[activeShotIndex].preferredMode
            wasLocked = false
        }
    }

    private func showToast(_ text: String) {
        DispatchQueue.main.async {
            self.statusToast = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                if self?.statusToast == text {
                    self?.statusToast = nil
                }
            }
        }
    }

    private func currentImageOrientation() -> CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        case .portraitUpsideDown: return .left
        default: return .right
        }
    }

    private func currentVideoTransform() -> CGAffineTransform {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .identity
        case .landscapeRight: return CGAffineTransform(rotationAngle: .pi)
        case .portraitUpsideDown: return CGAffineTransform(rotationAngle: -.pi / 2)
        default: return CGAffineTransform(rotationAngle: .pi / 2)
        }
    }
}
