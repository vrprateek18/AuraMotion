import QuartzCore
import Foundation
import CoreGraphics
import AVFoundation
import AppKit

public struct HandPreviewFrame: Sendable {
    public let trackingID: Int
    public let sampleTime: Double
    public let positions: [HandJointName: CGPoint]
}

public struct HUDSnapshot: Sendable {
    public let state: GestureState
    public let sample: HandSample?
    public let performance: PerformanceSnapshot
    public let thermalStage: ThermalQualityStage
    public let permissions: PermissionsState
    public let isArbitrationActive: Bool
    public let cursorLocation: CGPoint?
    public var feedback: String? = nil
    public var commandMenu: CommandMenuSnapshot? = nil
    public var showHUD = true
    public var clickFeedbackID: UInt64 = 0
    public var clickFeedbackLocation: CGPoint? = nil
    public var capturePixelFormat: OSType?
    public var rawCursorLocation: CGPoint? = nil
    public var pointerAnchor: PointerAnchor = .index
    public var smoothPreview = false
}

public extension Notification.Name {
    static let auraHandPreview = Notification.Name("AuraMotionHandPreview")
}

public protocol AppEnvironmentObserver: AnyObject, Sendable {
    func environmentDidUpdateHUDSnapshot(_ snapshot: HUDSnapshot)
}

/// Central coordinator for AuraMotion.
/// Enforces a strict single-queue ownership model for interaction state on interactionQueue.
public final class AppEnvironment: CapturePipelineDelegate, VisionInferenceWorkerDelegate, GestureStateMachineDelegate, InputArbitratorDelegate, @unchecked Sendable {
    public static let shared = AppEnvironment()

    // Dedicated serial queue for all interaction state and FSM transitions
    public let interactionQueue = DispatchQueue(label: "com.auramotion.interaction", qos: .userInteractive)
    private let safetyQueue = DispatchQueue(label: "com.auramotion.safety", qos: .userInteractive)

    // Core subsystems
    public let permissionsManager = PermissionsManager()
    public let settingsRepository = SettingsRepository()
    public let capturePipeline: CapturePipeline
    public let visionWorker = VisionInferenceWorker()
    public let continuityTracker = IdentityContinuityTracker()
    public let cursorController: CursorController
    public let stateMachine = GestureStateMachine()
    public let outputCoordinator = EventOutputCoordinator()
    public let inputArbitrator = InputArbitrator()
    public let performanceTracker = PerformanceTracker()
    public let qualityLadder = QualityLadder()
    public let landmarkRecorder = LandmarkRecorder()

    public weak var observer: AppEnvironmentObserver?

    public private(set) var currentSettings: AppSettings
    public private(set) var currentCalibration: CalibrationProfile

    // Confined to interactionQueue
    private var latestSnapshotSample: HandSample?
    private var latestCursorLocation: CGPoint?
    private var capturePixelFormat: OSType?
    private var latestRawCursorLocation: CGPoint?
    private var isArbitrationCooldownActive = false
    private var isReleaseConfirmed = false
    private var isCooldownElapsed = false
    private var lastHUDPublishTime: TimeInterval = 0
    private var recognitionFeedback: String?
    private var recognitionTime: TimeInterval = 0
    private var calibrationPreviousPause: Bool?
    private var clickFeedbackID: UInt64 = 0
    private var clickFeedbackLocation: CGPoint?
    private var hasStarted = false
    private var captureStartRequested = false
    private var pointerTrack = PresentationTrack(maxLead: 12)
    private var preview = HandPreview()
    private var pointerEpoch: UInt64?
    private var lastMoveTime: Double?
    private var lastDisplayTick = 0.0
    private let displayTickSlot = DispatchSemaphore(value: 1)

    private func resetPresentedPointer() {
        pointerEpoch = nil
        lastMoveTime = nil
        pointerTrack = PresentationTrack(maxLead: 12)
    }

    public func displayTick(at target: Double) {
        // If interaction is busy, skip this refresh rather than replaying old ticks.
        guard displayTickSlot.wait(timeout: .now()) == .success else { return }
        interactionQueue.async {
            defer { self.displayTickSlot.signal() }
            guard self.hasStarted, self.currentSettings.smoothPresentation,
                  target >= CACurrentMediaTime() - 0.018 else { return }
            self.lastDisplayTick = CACurrentMediaTime()
            if let epoch = self.pointerEpoch, self.stateMachine.currentState == .pointer,
               !self.stateMachine.isManualPaused, !self.isArbitrationCooldownActive,
               self.outputCoordinator.canPost(epoch: epoch),
               let p = self.pointerTrack.position(at: target) {
                let bounds = self.currentCalibration.displayBounds
                let clamped = CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX.nextDown),
                                      y: min(max(p.y, bounds.minY), bounds.maxY.nextDown))
                self.outputCoordinator.enqueueMove(to: clamped, epoch: epoch)
            }
            if self.currentSettings.showHUD, let sample = self.latestSnapshotSample {
                let positions = self.preview.positions(at: target)
                if !positions.isEmpty {
                    let frame = HandPreviewFrame(trackingID: sample.trackingID, sampleTime: sample.hostTimestamp, positions: positions)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .auraHandPreview, object: frame)
                    }
                }
            }
        }
    }

    public func setCalibrationActive(_ active: Bool) {
        interactionQueue.async { [weak self] in
            guard let self else { return }
            if active {
                guard self.calibrationPreviousPause == nil else { return }
                self.calibrationPreviousPause = self.stateMachine.isManualPaused
                self.stateMachine.isManualPaused = true
                self.stateMachine.reset()
                self.outputCoordinator.emergencyRelease()
            } else if let previous = self.calibrationPreviousPause {
                self.stateMachine.reset()
                self.stateMachine.isManualPaused = previous
                self.calibrationPreviousPause = nil
            }
        }
    }

    private func recognize(_ message: String) {
        recognitionFeedback = message
        recognitionTime = CACurrentMediaTime()
    }

    public init() {
        let repo = SettingsRepository()
        let settings = repo.loadSettings()
        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        let calibration = repo.loadCalibration(cameraID: "builtin", displayID: displayID, arrangementHash: 0)

        var cal = calibration
        cal.displayBounds = bounds

        self.capturePipeline = CapturePipeline(pixelLayout: settings.cameraPixelLayout)
        self.currentSettings = settings
        self.currentCalibration = cal
        self.cursorController = CursorController(profile: cal)

        // Wire delegates
        self.capturePipeline.delegate = self
        self.visionWorker.delegate = self
        self.stateMachine.systemCursorLocation = { CGEvent(source: nil)?.location }
        self.stateMachine.delegate = self
        self.inputArbitrator.delegate = self

        // Wire epoch and injection validation providers into outputCoordinator
        self.outputCoordinator.epochProvider = { [weak self] in
            self?.inputArbitrator.currentEpoch() ?? 0
        }
        self.outputCoordinator.injectionAllowedProvider = { [weak self] in
            guard let self = self else { return false }
            // Output path uses only atomic/cached state. No interactionQueue-owned fields.
            return self.permissionsManager.gate.canInject && self.inputArbitrator.isInjectionEnabled()
        }

        self.stateMachine.pointerAnchor = settings.pointerAnchor
        self.stateMachine.anyFingerClick = settings.anyFingerClick
        self.visionWorker.isMirrored = settings.isCameraMirrored
        self.stateMachine.isClutchEnabled = settings.isClutchEnabled
        self.stateMachine.clutchDwellDuration = settings.clutchDwellTime
        self.stateMachine.scrollDetector.scrollController.isInertiaEnabled = settings.scrollInertiaEnabled
        self.stateMachine.isPalmSwipeEnabled = settings.isPalmSwipeEnabled
        self.stateMachine.updateCalibration(cal)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.permissionsManager.checkPermissions()
        }

        NotificationCenter.default.addObserver(
            forName: .auraMotionPermissionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.interactionQueue.async {
                guard self.hasStarted else { return }
                let permissions = self.permissionsManager.gate.cachedSnapshot
                if permissions.isCameraAuthorized && !self.captureStartRequested && self.capturePipeline.state == .idle {
                    self.startCapture(permissions)
                }
                self.startInputArbitrationIfNeeded(permissions)
                self.publishHUDSnapshot(force: true)
            }
        }
    }

    public func start() {
        // Keep lifecycle flags and capture startup serialized with frame-driven
        // interaction state.  This also makes repeated start/stop calls safe
        // when AppKit and a camera permission callback race each other.
        interactionQueue.async { [weak self] in
            guard let self, !self.hasStarted else { return }
            self.hasStarted = true
            let perms = self.permissionsManager.checkPermissions()
            self.permissionsManager.startPeriodicRefresh()

            // Diagnostic logging — write to file for reliable capture
            let diagLines = """
            [AuraMotion] Permission check at startup (\(Date())):
              Executable: \(CommandLine.arguments.first ?? "unknown")
              Bundle: \(Bundle.main.bundlePath)
              Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")
              Camera: \(perms.isCameraAuthorized)
              Accessibility (AXIsProcessTrusted): \(perms.isAccessibilityTrusted)
              PostEvent: \(perms.isPostEventAuthorized)
              ListenEvent: \(perms.isListenEventAuthorized)
              canInjectInput: \(perms.canInjectInput)
              canArbitrate: \(perms.canArbitrate)
            """
            try? diagLines.write(toFile: "/tmp/auramotion_perms.log", atomically: true, encoding: .utf8)

            // Request input permissions from the HUD or Settings when the user
            // chooses a permission. Multiple launch-time TCC sheets hide setup.
            if perms.isCameraAuthorized {
                self.startCapture(perms)
            } else if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                // First launch: trigger the TCC camera prompt
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.permissionsManager.requestCameraAccess { [weak self] granted in
                        guard let self, granted else { return }
                        self.interactionQueue.async {
                            let refreshed = self.permissionsManager.checkPermissions()
                            self.startCapture(refreshed)
                            self.startInputArbitrationIfNeeded(refreshed)
                            self.publishHUDSnapshot(force: true)
                        }
                    }
                }
            }
            self.startInputArbitrationIfNeeded(perms)
            self.publishHUDSnapshot(force: true)
            // If camera denied/restricted, do nothing — user must grant via System Settings
        }
    }

    private func startCapture(_ perms: PermissionsState) {
        guard perms.isCameraAuthorized else { return }
        guard !captureStartRequested else { return }
        guard capturePipeline.state == .idle || capturePipeline.state == .configured else { return }
        captureStartRequested = true

        capturePipeline.configure { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.capturePipeline.start { startResult in
                    if case .failure(let error) = startResult {
                        self.interactionQueue.async { [weak self] in
                            self?.captureStartRequested = false
                            self?.publishHUDSnapshot(force: true)
                        }
                        StructuredLogger.capture.error("Failed to start capture: \(error.localizedDescription)")
                    }
                }
            case .failure(let error):
                self.interactionQueue.async { [weak self] in
                    self?.captureStartRequested = false
                    self?.publishHUDSnapshot(force: true)
                }
                StructuredLogger.capture.error("Failed to configure capture: \(error.localizedDescription)")
            }
        }
    }

    private func startInputArbitrationIfNeeded(_ perms: PermissionsState) {
        if perms.canArbitrate && !inputArbitrator.isTapActive {
            _ = inputArbitrator.start()
        }
    }

    public func stop() {
        permissionsManager.stopPeriodicRefresh()
        interactionQueue.async { [weak self] in
            guard let self = self else { return }
            self.hasStarted = false
            self.captureStartRequested = false
            self.stateMachine.transition(to: .paused)
            self.outputCoordinator.emergencyRelease()
            self.capturePipeline.stop()
            self.inputArbitrator.stop()
        }
    }

    public func togglePause() {
        interactionQueue.async { [weak self] in
            guard let self = self else { return }
            self.stateMachine.isManualPaused.toggle()
            if self.stateMachine.isManualPaused {
                self.stateMachine.transition(to: .paused)
                self.outputCoordinator.emergencyRelease()
            } else {
                self.stateMachine.transition(to: .idle)
            }
        }
    }

    public func updateSettings(_ newSettings: AppSettings) {
        interactionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.currentSettings.pointerAnchor != newSettings.pointerAnchor ||
               self.currentSettings.anyFingerClick != newSettings.anyFingerClick ||
               self.currentSettings.isCameraMirrored != newSettings.isCameraMirrored {
                self.outputCoordinator.emergencyRelease()
                self.stateMachine.reset()
                self.cursorController.reset()
                self.latestCursorLocation = nil
            }
            self.resetPresentedPointer()
            self.stateMachine.pointerAnchor = newSettings.pointerAnchor
            self.stateMachine.anyFingerClick = newSettings.anyFingerClick
            self.currentSettings = newSettings
            self.visionWorker.isMirrored = newSettings.isCameraMirrored
            self.stateMachine.isClutchEnabled = newSettings.isClutchEnabled
            self.stateMachine.clutchDwellDuration = newSettings.clutchDwellTime
            self.stateMachine.scrollDetector.scrollController.isInertiaEnabled = newSettings.scrollInertiaEnabled
            self.stateMachine.isPalmSwipeEnabled = newSettings.isPalmSwipeEnabled
            self.settingsRepository.saveSettings(newSettings)
            self.publishHUDSnapshot()
        }
    }

    public func updateCalibration(_ newCalibration: CalibrationProfile) {
        interactionQueue.async { [weak self] in
            guard let self = self else { return }
            self.resetPresentedPointer()
            self.currentCalibration = newCalibration
            self.cursorController.updateProfile(newCalibration)
            self.stateMachine.updateCalibration(newCalibration)
            self.settingsRepository.saveCalibration(newCalibration)
        }
    }

    // MARK: - CapturePipelineDelegate

    public func capturePipeline(_ pipeline: CapturePipeline, didOutput carrier: SampleCarrier) {
        performanceTracker.recordCaptureFrame(
            timestamp: carrier.hostPresentationTime,
            droppedFrames: pipeline.mailbox.droppedFrames
        )

        // Quality Ladder Stage 1: check if frame should be processed
        if qualityLadder.shouldProcessVisionFrame() {
            visionWorker.processMailbox(mailbox: pipeline.mailbox)
        }
    }

    public func capturePipelineDidInterrupted(_ pipeline: CapturePipeline) {
        interactionQueue.async { [weak self] in
            guard let self = self else { return }
            self.stateMachine.transition(to: .trackingLost)
            self.outputCoordinator.emergencyRelease()
        }
    }

    public func capturePipelineInterruptionEnded(_ pipeline: CapturePipeline) {
        interactionQueue.async { [weak self] in
            self?.stateMachine.transition(to: .idle)
        }
    }

    // MARK: - VisionInferenceWorkerDelegate

    public func visionWorker(
        _ worker: VisionInferenceWorker,
        didProduce sample: HandSample?,
        carrier: SampleCarrier,
        inferenceDuration: TimeInterval,
        mailboxWaitDuration: TimeInterval
    ) {
        let now = CACurrentMediaTime()
        let pipelineLatency = now - carrier.hostPresentationTime

        performanceTracker.recordInference(
            duration: inferenceDuration,
            mailboxWait: mailboxWaitDuration,
            pipelineLatency: pipelineLatency,
            isEstimated: carrier.isEstimatedTime,
            timestamp: now
        )

        // Dispatch all state transitions and coordinate mapping strictly to interactionQueue
        interactionQueue.async { [weak self] in
            guard let self = self else { return }

            var processedSample: HandSample? = nil
            var mappedCursor: CGPoint? = nil
            self.latestRawCursorLocation = nil

            if let rawSample = sample {
                let tracked = self.continuityTracker.update(sample: rawSample, timestamp: now)
                processedSample = tracked
                self.landmarkRecorder.record(sample: tracked)

                if tracked.trackingID != self.latestSnapshotSample?.trackingID {
                    self.resetPresentedPointer()
                    self.cursorController.reset()
                }
                let anchor = self.currentSettings.pointerAnchor
                if let tip = tracked.joint(anchor.joint, minConfidence: 0.45) {
                    self.latestRawCursorLocation = self.cursorController.mapper.mapToQuartzGlobal(visionPoint: tip)
                    mappedCursor = self.cursorController.processHand(tracked, anchor: anchor)
                } else {
                    // Keep palm/shortcut detection alive without switching the cursor's
                    // tracking landmark, which caused large jumps on fingertip occlusion.
                    mappedCursor = anchor == .index ? self.latestCursorLocation : nil
                }
            }

            self.preview.observe(self.currentSettings.smoothPresentation && self.currentSettings.showHUD ? processedSample : nil,
                                 received: CACurrentMediaTime())
            if let format = CMSampleBufferGetFormatDescription(carrier.buffer) {
                self.capturePixelFormat = CMFormatDescriptionGetMediaSubType(format)
            }
            self.latestSnapshotSample = processedSample
            self.latestCursorLocation = mappedCursor

            let epoch = self.inputArbitrator.currentEpoch()
            let canInject = self.permissionsManager.gate.canInject && self.inputArbitrator.isInjectionEnabled() && !self.isArbitrationCooldownActive

            self.stateMachine.processFrame(
                sample: processedSample,
                mappedCursorLocation: mappedCursor,
                currentEpoch: epoch,
                isInjectionAllowed: canInject
            )

            // Some frames (menu navigation, pinch release, transient ambiguity) consume a
            // gesture without emitting a move or a state transition.
            if self.lastMoveTime != processedSample?.hostTimestamp { self.resetPresentedPointer() }
            self.publishHUDSnapshot()
        }
    }

    // MARK: - GestureStateMachineDelegate

    public func stateMachine(_ fsm: GestureStateMachine, didTransitionTo state: GestureState) {
        if state != .pointer { resetPresentedPointer() }
        publishHUDSnapshot()
    }

    public func stateMachine(_ fsm: GestureStateMachine, emitMoveTo location: CGPoint, epoch: UInt64) {
        guard CACurrentMediaTime() - lastDisplayTick < 0.06, currentSettings.smoothPresentation,
              fsm.currentState == .pointer, fsm.canPredictPointer,
              let sample = latestSnapshotSample, latestRawCursorLocation != nil else {
            resetPresentedPointer()
            outputCoordinator.enqueueMove(to: location, epoch: epoch)
            return
        }
        if pointerEpoch != epoch { resetPresentedPointer() }
        lastMoveTime = sample.hostTimestamp
        pointerEpoch = epoch
        pointerTrack.observe(location, timestamp: sample.hostTimestamp, received: CACurrentMediaTime())
    }

    public func stateMachine(_ fsm: GestureStateMachine, emitClickAt anchor: CGPoint, epoch: UInt64) {
        clickFeedbackID &+= 1
        clickFeedbackLocation = currentSettings.showClickFeedback ? anchor : nil
        recognize("Click recognized")
        outputCoordinator.enqueueClick(at: anchor, epoch: epoch)
    }

    public func stateMachine(_ fsm: GestureStateMachine, emitDragStartAt anchor: CGPoint, epoch: UInt64) {
        outputCoordinator.enqueueDragStart(at: anchor, epoch: epoch)
    }

    public func stateMachine(_ fsm: GestureStateMachine, emitDragMoveTo location: CGPoint, epoch: UInt64) {
        outputCoordinator.enqueueDragMove(to: location, epoch: epoch)
    }

    public func stateMachine(_ fsm: GestureStateMachine, emitDragEndAt location: CGPoint, epoch: UInt64) {
        outputCoordinator.enqueueDragEnd(at: location, epoch: epoch)
    }

    public func stateMachine(_ fsm: GestureStateMachine, emitScroll delta: ScrollDelta, epoch: UInt64) {
        outputCoordinator.enqueueScroll(delta: delta, epoch: epoch)
    }

    public func stateMachine(_ fsm: GestureStateMachine, emitSwipe direction: PalmSwipeDirection, epoch: UInt64) {
        recognize(direction == .left ? "Left swipe recognized" : "Right swipe recognized")
        outputCoordinator.enqueueSwipe(direction: direction, action: currentSettings.swipeAction, epoch: epoch)
    }

    public func stateMachine(_ fsm: GestureStateMachine, emitShortcut shortcut: FingerShortcut, epoch: UInt64) {
        recognize(shortcut == .copy ? "Copy recognized" : "Paste recognized")
        outputCoordinator.enqueueShortcut(shortcut, epoch: epoch)
    }

    public func stateMachine(_ fsm: GestureStateMachine, emitCommand command: GestureCommand, at target: CGPoint, epoch: UInt64) {
        recognize("\(command.title) recognized")
        guard command == .snapLeft || command == .snapRight else {
            outputCoordinator.enqueueCommand(command, at: target, epoch: epoch)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            let pid = app.processIdentifier
            let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
            let cocoaPoint = CGPoint(x: target.x, y: primaryHeight - target.y)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoaPoint) }) ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            let bounds = CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
            self.outputCoordinator.enqueueValidatedAction(epoch: epoch) { [weak self] in
                let result = WindowSnapper.apply(pid: pid, bounds: bounds, right: command == .snapRight)
                self?.interactionQueue.async { [weak self] in self?.recognize(result) }
            }
        }
    }

    public func stateMachineTriggerEmergencyRelease(_ fsm: GestureStateMachine) {
        outputCoordinator.emergencyRelease()
    }

    // MARK: - InputArbitratorDelegate & Strict 4-Step Re-Enable Sequence

    public func arbitratorDidDetectExternalInput(epoch: UInt64) {
        interactionQueue.async { [weak self] in
            guard let self = self else { return }

            // Step 1: Immediately drop pending work and release all buttons with confirmation
            self.isArbitrationCooldownActive = true
            self.isReleaseConfirmed = false
            self.isCooldownElapsed = false
            self.stateMachine.transition(to: .trackingLost)

            StructuredLogger.arbitration.notice("External physical input detected. Control yielded.")

            // Execute emergency release with completion barrier
            self.outputCoordinator.emergencyRelease { [weak self] in
                guard let self = self else { return }
                self.interactionQueue.async {
                    self.isReleaseConfirmed = true
                    self.checkAndReenableAfterArbitration()
                }
            }

            // Start arbitration cooldown timer
            let cooldown = self.currentSettings.arbitrationCooldownSeconds
            self.safetyQueue.asyncAfter(deadline: .now() + cooldown) { [weak self] in
                guard let self = self else { return }
                self.interactionQueue.async {
                    self.isCooldownElapsed = true
                    self.checkAndReenableAfterArbitration()
                }
            }
        }
    }

    public func arbitratorDidTimeoutExcessively() {
        StructuredLogger.arbitration.warning("CGEventTap disabled due to excessive timeouts. Running in degraded safe mode.")
    }

    /// Strict 4-Step Re-Enable Sequence:
    /// 1. Cooldown elapsed
    /// 2. releaseAllButtons() confirmed completed on output coordinator
    /// 3. Output queue drained
    /// 4. Ready for engagement clutch reacquisition
    private func checkAndReenableAfterArbitration() {
        guard isCooldownElapsed && isReleaseConfirmed else {
            return
        }

        isArbitrationCooldownActive = false
        isReleaseConfirmed = false
        isCooldownElapsed = false
        stateMachine.reset()

        // Re-enable atomic state and bump epoch
        let _ = inputArbitrator.reenableInjection()
        StructuredLogger.arbitration.notice("Arbitration cooldown ended and release confirmed. Ready for clutch reacquisition.")
    }

    private func publishHUDSnapshot(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastHUDPublishTime >= 1.0 / 30.0 else { return }
        lastHUDPublishTime = now
        // Use cached permission snapshot — zero IPC on the steady-state path.
        let cachedPerms = permissionsManager.gate.cachedSnapshot
        var snapshot = HUDSnapshot(
            state: stateMachine.currentState,
            sample: latestSnapshotSample,
            performance: performanceTracker.snapshot(),
            thermalStage: qualityLadder.activeStage,
            permissions: cachedPerms,
            isArbitrationActive: inputArbitrator.isTapActive && !isArbitrationCooldownActive,
            cursorLocation: latestCursorLocation
        )
        if calibrationPreviousPause != nil {
            snapshot.feedback = "Calibration — control paused"
        } else if !cachedPerms.isCameraAuthorized {
            snapshot.feedback = cachedPerms.statusLabel
        } else if !cachedPerms.canInjectInput {
            snapshot.feedback = cachedPerms.statusLabel ?? "Input control is blocked"
        } else if isArbitrationCooldownActive {
            snapshot.feedback = "Mouse in use — gesture control waiting"
        } else if now - recognitionTime < 1.2 {
            snapshot.feedback = recognitionFeedback
        } else if stateMachine.shortcutDetector.isHoldingContact {
            snapshot.feedback = "Hold steady, then separate fingertips"
        } else if stateMachine.commandMenu.isOpen {
            snapshot.feedback = "Point to a command, then pinch"
        } else if stateMachine.currentState == .palmRest {
            snapshot.feedback = "Hold palm still to open commands"
        }
        snapshot.commandMenu = stateMachine.commandMenu.snapshot
        snapshot.showHUD = currentSettings.showHUD
        snapshot.smoothPreview = currentSettings.smoothPresentation
        snapshot.capturePixelFormat = capturePipeline.isRunning ? capturePixelFormat : nil
        snapshot.pointerAnchor = currentSettings.pointerAnchor
        snapshot.rawCursorLocation = latestRawCursorLocation
        snapshot.clickFeedbackID = clickFeedbackID
        snapshot.clickFeedbackLocation = currentSettings.showClickFeedback ? clickFeedbackLocation : nil
        let publishedSnapshot = snapshot
        DispatchQueue.main.async { [weak self] in
            self?.observer?.environmentDidUpdateHUDSnapshot(publishedSnapshot)
        }
    }
}
