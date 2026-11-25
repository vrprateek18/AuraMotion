import XCTest
import CoreGraphics
@testable import AuraMotionCore

final class InteractionRegressionTests: XCTestCase {
    func testSingleFrameScrollPoseCannotScrollAndDeliberateScrollStillEngages() {
        let fsm = GestureStateMachine()
        let output = MockStateMachineDelegate()
        fsm.delegate = output
        fsm.isClutchEnabled = false
        fsm.confidenceGate.reacquisitionDwellSeconds = 0
        fsm.processFrame(sample: sample(middleExtended: false, time: 10), mappedCursorLocation: .zero, currentEpoch: 1, isInjectionAllowed: true)
        fsm.processFrame(sample: sample(time: 10.033), mappedCursorLocation: CGPoint(x: 0, y: 100), currentEpoch: 1, isInjectionAllowed: true)
        fsm.processFrame(sample: sample(middleExtended: false, time: 10.067), mappedCursorLocation: CGPoint(x: 0, y: 110), currentEpoch: 1, isInjectionAllowed: true)
        XCTAssertTrue(output.scrolls.isEmpty)
        XCTAssertEqual(fsm.currentState, .pointer)
        for i in 0..<10 {
            fsm.processFrame(sample: sample(time: 11 + Double(i) / 30), mappedCursorLocation: CGPoint(x: 0, y: i * 5), currentEpoch: 1, isInjectionAllowed: true)
        }
        XCTAssertFalse(output.scrolls.isEmpty)
        fsm.processFrame(sample: sample(middleExtended: false, time: 11.4), mappedCursorLocation: .zero, currentEpoch: 1, isInjectionAllowed: true)
        XCTAssertEqual(fsm.currentState, .pointer)
    }

    func testMenuUsesNormalMappedPointerAndTrackingLossDismissesIt() {
        let fsm = GestureStateMachine()
        let output = MockStateMachineDelegate()
        fsm.delegate = output
        fsm.isClutchEnabled = false
        fsm.confidenceGate.reacquisitionDwellSeconds = 0
        for frame in 0...30 {
            if fsm.commandMenu.observePalm(position: CGPoint(x: 0.5, y: 0.5), timestamp: 10 + Double(frame) / 30, target: CGPoint(x: 100, y: 200)) { break }
        }
        XCTAssertTrue(fsm.commandMenu.isOpen)
        fsm.processFrame(sample: sample(middleExtended: false, time: 11.1), mappedCursorLocation: CGPoint(x: 800, y: 700), currentEpoch: 1, isInjectionAllowed: true)
        XCTAssertEqual(output.moves, [CGPoint(x: 800, y: 700)])
        XCTAssertTrue(fsm.canPredictPointer)
        XCTAssertTrue(output.scrolls.isEmpty)
        XCTAssertTrue(output.clickAnchors.isEmpty)
        fsm.processFrame(sample: nil, mappedCursorLocation: nil, currentEpoch: 1, isInjectionAllowed: true)
        XCTAssertFalse(fsm.commandMenu.isOpen)
        XCTAssertTrue(output.commands.isEmpty)

        // A still-tracked but folded hand is also an explicit dismissal gesture;
        // it must not leave a stale command overlay waiting for its timeout.
        for frame in 0...30 {
            if fsm.commandMenu.observePalm(position: CGPoint(x: 0.5, y: 0.5), timestamp: 20 + Double(frame) / 30, target: CGPoint(x: 100, y: 200)) { break }
        }
        XCTAssertTrue(fsm.commandMenu.isOpen)
        let folded = sample(middleExtended: false, thumb: CGPoint(x: 0.25, y: 0.55), time: 21.1)
        var foldedJoints = folded.joints
        foldedJoints[.indexTip] = HandJoint(name: .indexTip, position: CGPoint(x: 0.44, y: 0.42), confidence: 0.9)
        let foldedSample = HandSample(hostTimestamp: 21.1, presentationTimeSeconds: 21.1,
            isPresentationTimeEstimated: false, joints: foldedJoints, overallConfidence: 0.9,
            estimatedHandedness: .right, trackingID: 1)
        fsm.processFrame(sample: foldedSample, mappedCursorLocation: CGPoint(x: 800, y: 700), currentEpoch: 1, isInjectionAllowed: true)
        XCTAssertFalse(fsm.commandMenu.isOpen)
    }

    func testThumbMenuUsesVisibleCursorForHitTestAndConsumesMiddlePinch() throws {
        let fsm = GestureStateMachine()
        let output = MockStateMachineDelegate()
        fsm.delegate = output
        fsm.isClutchEnabled = false
        fsm.anyFingerClick = true
        fsm.pointerAnchor = .thumb
        fsm.confidenceGate.reacquisitionDwellSeconds = 0
        let visible = CGPoint(x: 810, y: 420)
        let measured = CGPoint(x: 800, y: 420)
        fsm.systemCursorLocation = { visible }
        fsm.commandMenu.holdDuration = 0
        let target = CGPoint(x: 100, y: 200)
        XCTAssertTrue(fsm.commandMenu.observePalm(position: .zero, timestamp: 10, target: target))
        let menu = try XCTUnwrap(fsm.commandMenu.snapshot)
        fsm.commandMenu.setTileFrames([.missionControl: CGRect(x: 805, y: 400, width: 90, height: 64)], for: menu.id)
        for i in 0..<14 {
            let time = 10.1 + Double(i) / 30
            let base = sample(middleExtended: false, time: time)
            var joints = base.joints
            let thumb = try XCTUnwrap(base.joint(.thumbTip))
            joints[.thumbMP] = HandJoint(name: .thumbMP, position: CGPoint(x: 0.38, y: 0.4), confidence: 1)
            joints[.indexTip] = HandJoint(name: .indexTip, position: CGPoint(x: 0.44, y: 0.42), confidence: 1)
            if i >= 3 && i < 12 {
                joints[.middleTip] = HandJoint(name: .middleTip, position: thumb, confidence: 1)
            }
            let hand = HandSample(hostTimestamp: time, presentationTimeSeconds: time, isPresentationTimeEstimated: false,
                                  joints: joints, overallConfidence: 1, estimatedHandedness: .right, trackingID: 1)
            fsm.processFrame(sample: hand, mappedCursorLocation: measured, currentEpoch: 1, isInjectionAllowed: true)
            if i == 1 {
                XCTAssertEqual(output.moves.last, measured)
                XCTAssertTrue(fsm.canPredictPointer)
                XCTAssertEqual(fsm.commandMenu.snapshot?.selected, .missionControl)
            }
        }
        XCTAssertEqual(output.commands, [.missionControl])
        XCTAssertFalse(fsm.commandMenu.isOpen)
        XCTAssertTrue(output.clickAnchors.isEmpty)
        XCTAssertTrue(output.dragStarts.isEmpty)
        XCTAssertTrue(output.moves.allSatisfy { $0 == measured })
    }

    private func sample(middleExtended: Bool = true, thumb: CGPoint = CGPoint(x: 0.25, y: 0.55), time: Double = 10) -> HandSample {
        let positions: [HandJointName: CGPoint] = [
            .wrist: CGPoint(x: 0.5, y: 0.2), .middleMCP: CGPoint(x: 0.5, y: 0.4),
            .indexMCP: CGPoint(x: 0.44, y: 0.4), .indexPIP: CGPoint(x: 0.44, y: 0.52),
            .indexTip: CGPoint(x: 0.44, y: 0.65), .middlePIP: CGPoint(x: 0.5, y: 0.53),
            .middleTip: CGPoint(x: 0.5, y: middleExtended ? 0.67 : 0.35),
            .ringMCP: CGPoint(x: 0.56, y: 0.4), .ringPIP: CGPoint(x: 0.56, y: 0.46),
            .ringTip: CGPoint(x: 0.56, y: 0.35), .littleMCP: CGPoint(x: 0.62, y: 0.4),
            .littleTip: CGPoint(x: 0.62, y: 0.35), .thumbTip: thumb
        ]
        return HandSample(hostTimestamp: time, presentationTimeSeconds: time, isPresentationTimeEstimated: false,
            joints: Dictionary(uniqueKeysWithValues: positions.map { name, point in (name, HandJoint(name: name, position: point, confidence: 0.9)) }),
            overallConfidence: 0.9, estimatedHandedness: .right, trackingID: 1)
    }

    func testTwoFingerScrollWithThumbExtendedAndImmediateReturnToPointer() {
        let fsm = GestureStateMachine()
        let output = MockStateMachineDelegate()
        fsm.delegate = output
        fsm.isClutchEnabled = false
        fsm.confidenceGate.reacquisitionDwellSeconds = 0
        XCTAssertTrue(PoseClassifier.classify(sample: sample()).isTwoFingerPointing)
        XCTAssertFalse(PoseClassifier.classify(sample: sample()).isOpenPalm)
        for frame in 0..<10 {
            fsm.processFrame(sample: sample(time: 10 + Double(frame) / 30), mappedCursorLocation: CGPoint(x: 500, y: 500 + frame * 2), currentEpoch: 1, isInjectionAllowed: true)
        }
        XCTAssertFalse(output.scrolls.isEmpty)
        fsm.processFrame(sample: sample(middleExtended: false, time: 10.4), mappedCursorLocation: CGPoint(x: 520, y: 520), currentEpoch: 1, isInjectionAllowed: true)
        XCTAssertEqual(fsm.currentState, .pointer)
        XCTAssertEqual(output.moves.last, CGPoint(x: 520, y: 520))
    }

    func testHeldCopyDoesNotLeakCursorScrollOrSwipe() {
        let fsm = GestureStateMachine()
        let output = MockStateMachineDelegate()
        fsm.delegate = output
        fsm.isClutchEnabled = false
        fsm.confidenceGate.reacquisitionDwellSeconds = 0
        for frame in 0..<20 {
            fsm.processFrame(sample: sample(thumb: CGPoint(x: 0.51, y: 0.67), time: 10 + Double(frame) / 30), mappedCursorLocation: CGPoint(x: 500 + frame * 5, y: 500), currentEpoch: 1, isInjectionAllowed: true)
        }
        XCTAssertEqual(output.shortcuts, [.copy])
        XCTAssertTrue(output.moves.isEmpty)
        XCTAssertTrue(output.scrolls.isEmpty)
        XCTAssertTrue(output.swipes.isEmpty)
    }

    func testFilterRejectsOutOfOrderSamplesAndResetsAfterGap() {
        let filter = OneEuroFilter1D()
        XCTAssertEqual(filter.filter(x: 100, timestamp: 1), 100)
        XCTAssertEqual(filter.filter(x: 900, timestamp: 0.9), 100)
        XCTAssertEqual(filter.filter(x: 900, timestamp: 2), 900)
    }

    func testActiveScrollPreservesSubpixelMotion() {
        let detector = ScrollDetector(deadbandPoints: 1, scrollSpeedMultiplier: 1)
        _ = detector.evaluate(isTwoFingerPose: true, currentLocation: .zero)
        _ = detector.evaluate(isTwoFingerPose: true, currentLocation: CGPoint(x: 0, y: 1))
        var total: CGFloat = 0
        for frame in 1...100 {
            total += detector.evaluate(isTwoFingerPose: true, currentLocation: CGPoint(x: 0, y: 1 + Double(frame) * 0.2))?.deltaY ?? 0
        }
        XCTAssertGreaterThan(total, 19)
    }
}
