import CoreVideo
import XCTest
@testable import AuraMotionCore

final class ThumbPresentationTests: XCTestCase {
    private let tips: [HandJointName] = [.indexTip, .middleTip, .ringTip, .littleTip]
    private func sample(frame: Int, finger: HandJointName, fraction: Double, missing: HandJointName? = nil) -> HandSample {
        let thumb = CGPoint(x: 0.35, y: 0.52)
        var positions: [HandJointName: CGPoint] = [
            .wrist: CGPoint(x: 0.52, y: 0.2), .middleMCP: CGPoint(x: 0.52, y: 0.42),
            .thumbMP: CGPoint(x: 0.48, y: 0.36), .indexMCP: CGPoint(x: 0.46, y: 0.42), .thumbTip: thumb
        ]
        for (i, name) in tips.enumerated() {
            let apart = CGPoint(x: 0.52 + Double(i) * 0.05, y: 0.7)
            let t = name == finger ? fraction : 0
            positions[name] = CGPoint(x: apart.x + (thumb.x - apart.x) * t, y: apart.y + (thumb.y - apart.y) * t)
        }
        if let missing { positions[missing] = nil }
        let time = 10 + Double(frame) / 30
        return HandSample(hostTimestamp: time, presentationTimeSeconds: time, isPresentationTimeEstimated: false,
            joints: positions.map { HandJoint(name: $0.key, position: $0.value, confidence: 0.95) }
                .reduce(into: [:]) { $0[$1.name] = $1 },
            overallConfidence: 0.95, estimatedHandedness: .right, trackingID: 1)
    }

    func testEachFingerClicksOnceAtStationaryThumb() throws {
        for finger in tips {
            let profile = CalibrationProfile()
            let controller = CursorController(profile: profile)
            let fsm = GestureStateMachine()
            let output = MockStateMachineDelegate()
            fsm.delegate = output
            fsm.anyFingerClick = true
            fsm.pointerAnchor = .thumb
            fsm.confidenceGate.reacquisitionDwellSeconds = 0
            let target = controller.mapper.mapToQuartzGlobal(visionPoint: CGPoint(x: 0.35, y: 0.52))
            let fractions = [0.0, 0, 0.3, 0.6, 0.85, 1, 1, 1, 1, 1, 0]
            for (frame, t) in fractions.enumerated() {
                let observation = sample(frame: frame, finger: finger, fraction: t)
                let measured = try XCTUnwrap(controller.processHand(observation, anchor: .thumb))
                XCTAssertEqual(measured, target)
                fsm.processFrame(sample: observation, mappedCursorLocation: measured, currentEpoch: 1, isInjectionAllowed: true)
            }
            XCTAssertEqual(output.clickAnchors, [target], finger.rawValue)
            XCTAssertTrue(output.shortcuts.isEmpty)
        }
    }

    func testContactMustHaveBeenSeenApartAndOcclusionNeverClicks() {
        let fsm = GestureStateMachine()
        let output = MockStateMachineDelegate()
        fsm.anyFingerClick = true
        fsm.delegate = output
        fsm.confidenceGate.reacquisitionDwellSeconds = 0
        func feed(_ i: Int, _ closed: Bool, _ missing: HandJointName? = nil) {
            fsm.processFrame(sample: sample(frame: i, finger: .middleTip, fraction: closed ? 1 : 0, missing: missing),
                             mappedCursorLocation: .zero, currentEpoch: 1, isInjectionAllowed: true)
        }
        for i in 0..<10 { feed(i, true) }
        feed(10, false)
        feed(11, true)
        for i in 12..<20 { feed(i, true, .middleTip) }
        XCTAssertTrue(output.clickAnchors.isEmpty)
    }

    func testDisplayLeadExpiresAndDoesNotRunAwayAfterAStop() throws {
        var track = PresentationTrack(maxLead: 12)
        track.observe(.zero, timestamp: 1, received: 1.01)
        track.observe(CGPoint(x: 30, y: 0), timestamp: 1.0333, received: 1.0433)
        let projected = try XCTUnwrap(track.position(at: 1.060))
        XCTAssertGreaterThan(projected.x, 30)
        XCTAssertLessThanOrEqual(projected.x, 42)
        track.observe(CGPoint(x: 30, y: 0), timestamp: 1.0667, received: 1.0767)
        XCTAssertEqual(track.position(at: 1.09)?.x, 30)
        XCTAssertNil(track.position(at: 1.16))
    }

    func testPreviewNeverFillsAnOccludedOrLostFingertip() {
        var preview = HandPreview()
        preview.observe(sample(frame: 0, finger: .indexTip, fraction: 0), received: 10)
        preview.observe(sample(frame: 1, finger: .indexTip, fraction: 0.3, missing: .thumbTip), received: 10.033)
        XCTAssertNil(preview.positions(at: 10.05)[.thumbTip])
        preview.observe(nil, received: 10.066)
        XCTAssertTrue(preview.positions(at: 10.08).isEmpty)
    }
    func testNativeOutputSelectsSupportedRangeAndFallsBack() {
        let native = CameraPixelLayout.nativeYUV
        let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let bgra = kCVPixelFormatType_32BGRA
        XCTAssertEqual(native.outputFormat(available: [full, bgra, video], native: video), video)
        XCTAssertEqual(native.outputFormat(available: [bgra], native: full), bgra)
        XCTAssertNil(native.outputFormat(available: [], native: full))
    }
}
