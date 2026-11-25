import QuartzCore
import Foundation
import AVFoundation
import CoreMedia
import os

public protocol CapturePipelineDelegate: AnyObject, Sendable {
    func capturePipeline(_ pipeline: CapturePipeline, didOutput carrier: SampleCarrier)
    func capturePipelineDidInterrupted(_ pipeline: CapturePipeline)
    func capturePipelineInterruptionEnded(_ pipeline: CapturePipeline)
}

public enum CameraPixelLayout: String, Codable, Sendable {
    case bgra, nativeYUV

    func outputFormat(available: [OSType], native: OSType) -> OSType? {
        let nv12 = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        if self == .nativeYUV {
            if nv12.contains(native), available.contains(native) { return native }
            if let supported = nv12.first(where: available.contains) { return supported }
        }
        return available.contains(kCVPixelFormatType_32BGRA) ? kCVPixelFormatType_32BGRA : nil
    }
}

public enum CaptureLifecycleState: String, Sendable {
    case idle
    case configuring
    case configured
    case starting
    case running
    case stopping
}

/// Manages AVCaptureSession with a bounded latest-frame mailbox and asynchronous, serialized lifecycle on captureQueue.
public final class CapturePipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.auramotion.capture", qos: .userInteractive)
    private let timebaseSync = TimebaseSynchronizer()

    public weak var delegate: CapturePipelineDelegate?
    public let mailbox = FrameMailbox()

    private var activeDevice: AVCaptureDevice?
    private var lifecycleState: CaptureLifecycleState = .idle
    private var snapshotState: CaptureLifecycleState = .idle
    private let stateLock = NSLock()

    private let pixelLayout: CameraPixelLayout
    public init(pixelLayout: CameraPixelLayout = .bgra) {
        self.pixelLayout = pixelLayout
        super.init()
        setupNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    /// Thread-safe atomic snapshot of current lifecycle state.
    public var state: CaptureLifecycleState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return snapshotState
    }

    /// Thread-safe check whether capture session is actively running.
    public var isRunning: Bool {
        return state == .running
    }

    public var synchronizationClock: CMClock? {
        return captureSession.synchronizationClock
    }

    private func updateState(_ newState: CaptureLifecycleState) {
        stateLock.lock()
        snapshotState = newState
        stateLock.unlock()
        lifecycleState = newState
    }

    // MARK: - Asynchronous Lifecycle API

    /// Configures the capture session exclusively on captureQueue.
    public func configure(
        completionQueue: DispatchQueue = .main,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }

            if self.lifecycleState == .configured {
                completionQueue.async { completion(.success(())) }
                return
            }

            guard self.lifecycleState == .idle else {
                let err = NSError(
                    domain: "AuraMotion.Capture",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot configure while in state \(self.lifecycleState.rawValue)"]
                )
                completionQueue.async { completion(.failure(err)) }
                return
            }

            self.updateState(.configuring)

            do {
                try self.performConfiguration()
                self.updateState(.configured)
                completionQueue.async { completion(.success(())) }
            } catch {
                self.updateState(.idle)
                completionQueue.async { completion(.failure(error)) }
            }
        }
    }

    /// Starts running the capture session exclusively on captureQueue.
    public func start(
        completionQueue: DispatchQueue = .main,
        completion: (@Sendable (Result<Void, Error>) -> Void)? = nil
    ) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }

            if self.lifecycleState == .running {
                completionQueue.async { completion?(.success(())) }
                return
            }

            guard self.lifecycleState == .configured || self.lifecycleState == .idle else {
                let err = NSError(
                    domain: "AuraMotion.Capture",
                    code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot start capture while in state \(self.lifecycleState.rawValue)"]
                )
                completionQueue.async { completion?(.failure(err)) }
                return
            }

            // Auto-configure if idle
            if self.lifecycleState == .idle {
                do {
                    self.updateState(.configuring)
                    try self.performConfiguration()
                    self.updateState(.configured)
                } catch {
                    self.updateState(.idle)
                    completionQueue.async { completion?(.failure(error)) }
                    return
                }
            }

            self.updateState(.starting)
            self.timebaseSync.reset()
            self.captureSession.startRunning()

            self.updateState(.running)
            completionQueue.async { completion?(.success(())) }
        }
    }

    /// Stops running the capture session exclusively on captureQueue.
    /// Serialized sequentially with start/configure, ensuring stop is never lost.
    public func stop(
        completionQueue: DispatchQueue = .main,
        completion: (@Sendable () -> Void)? = nil
    ) {
        captureQueue.async { [weak self] in
            guard let self = self else {
                completionQueue.async { completion?() }
                return
            }

            guard self.lifecycleState == .running || self.lifecycleState == .starting else {
                self.updateState(.idle)
                completionQueue.async { completion?() }
                return
            }

            self.updateState(.stopping)
            self.captureSession.stopRunning()
            self.mailbox.clear()
            self.timebaseSync.reset()
            self.updateState(.idle)

            completionQueue.async { completion?() }
        }
    }

    // MARK: - Internal Configuration

    private func performConfiguration() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Remove existing inputs/outputs if re-configuring
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }

        guard let selection = CameraFormatSelector.selectBestCameraAndFormat() else {
            throw NSError(domain: "AuraMotion.Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video camera found"])
        }

        activeDevice = selection.device
        let input = try AVCaptureDeviceInput(device: selection.device)

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        } else {
            throw NSError(domain: "AuraMotion.Capture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
        }

        let output = AVCaptureVideoDataOutput()
        // MANDATORY: drop stale video frames immediately
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)

        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        } else {
            throw NSError(domain: "AuraMotion.Capture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video data output"])
        }

        // Configure device format and framerate
        try selection.device.lockForConfiguration()
        selection.device.activeFormat = selection.format
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(selection.targetFrameRate))
        selection.device.activeVideoMinFrameDuration = frameDuration
        selection.device.activeVideoMaxFrameDuration = frameDuration
        selection.device.unlockForConfiguration()

        // The advertised output formats depend on the connected, active input.
        let native = CMFormatDescriptionGetMediaSubType(selection.format.formatDescription)
        if let type = pixelLayout.outputFormat(available: output.availableVideoPixelFormatTypes, native: native) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(type)]
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard lifecycleState == .running else { return }

        let arrivalHostTime = CACurrentMediaTime()
        let (hostTime, isEstimated) = timebaseSync.hostPresentationTime(
            for: sampleBuffer,
            session: captureSession,
            arrivalHostTime: arrivalHostTime
        )

        let carrier = SampleCarrier(
            buffer: sampleBuffer,
            hostPresentationTime: hostTime,
            isEstimatedTime: isEstimated
        )

        mailbox.postFrame(carrier)
        delegate?.capturePipeline(self, didOutput: carrier)
    }

    // MARK: - Interruptions & Notifications

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: .AVCaptureSessionWasInterrupted,
            object: captureSession
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruptionEnded(_:)),
            name: .AVCaptureSessionInterruptionEnded,
            object: captureSession
        )
    }

    @objc private func handleInterruption(_ note: Notification) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            self.timebaseSync.reset()
            self.mailbox.clear()
            self.delegate?.capturePipelineDidInterrupted(self)
        }
    }

    @objc private func handleInterruptionEnded(_ note: Notification) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            self.timebaseSync.reset()
            self.delegate?.capturePipelineInterruptionEnded(self)
        }
    }
}
