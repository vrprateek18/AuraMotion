import XCTest
import CoreGraphics
@testable import AuraMotionCore

final class CommandMenuTests: XCTestCase {
    // Deliberately use screen points on a secondary display, including a gap.
    private let frames: [GestureCommand: CGRect] = [
        .rightClick: CGRect(x: -700, y: 200, width: 150, height: 72),
        .doubleClick: CGRect(x: -540, y: 200, width: 150, height: 72)
    ]

    private func aim(_ menu: GestureCommandMenu, at point: CGPoint, distance: CGFloat = 0.7,
                     time: Double = 11.1, finger: HandJointName = .indexTip) -> GestureCommand? {
        menu.navigate(cursor: point, isPointing: distance >= 0.38, finger: finger, pinchDistance: distance,
                      contactThreshold: 0.28, releaseThreshold: 0.38, timestamp: time)
    }

    func testOnlyActualOnscreenTilesCanBeSelected() throws {
        let menu = GestureCommandMenu()
        open(menu)
        _ = aim(menu, at: CGPoint(x: 0.5, y: 0.5))
        XCTAssertNil(menu.snapshot?.selected)
        _ = aim(menu, at: CGPoint(x: -500, y: 220))
        XCTAssertEqual(menu.snapshot?.selected, .doubleClick)
        _ = aim(menu, at: CGPoint(x: -546, y: 220))
        XCTAssertNil(menu.snapshot?.selected)
        XCTAssertNil(aim(menu, at: CGPoint(x: -546, y: 220), distance: 0.10, time: 11.4))
        XCTAssertNil(aim(menu, at: CGPoint(x: -546, y: 220), distance: 0.10, time: 11.5))
        XCTAssertTrue(menu.isOpen)
    }

    private func open(_ menu: GestureCommandMenu, target: CGPoint = CGPoint(x: 700, y: 400)) {
        for frame in 0...30 {
            menu.observePalm(position: CGPoint(x: 0.5, y: 0.5), timestamp: 10 + Double(frame) / 30, target: target)
            if let view = menu.snapshot {
                menu.setTileFrames(frames, for: view.id)
                break
            }
        }
    }

    func testStillPalmOpensButMovingPalmDoesNot() {
        let menu = GestureCommandMenu()
        for frame in 0..<40 {
            XCTAssertFalse(menu.observePalm(position: CGPoint(x: Double(frame) * 0.02, y: 0.5), timestamp: Double(frame) / 30, target: .zero))
        }
        open(menu)
        XCTAssertTrue(menu.isOpen)
        XCTAssertNil(menu.snapshot?.selected)
    }

    func testPointThenPinchSelectsOnceAndPreservesOriginalTarget() throws {
        let menu = GestureCommandMenu()
        let target = CGPoint(x: 700, y: 400)
        open(menu, target: target)
        XCTAssertEqual(menu.snapshot?.target, target)
        let tile = CGPoint(x: -619, y: 238)
        XCTAssertNil(aim(menu, at: tile))
        XCTAssertEqual(menu.snapshot?.selected, .rightClick)
        XCTAssertNil(aim(menu, at: tile, distance: 0.15, time: 11.3, finger: .ringTip))
        XCTAssertEqual(aim(menu, at: tile, distance: 0.15, time: 11.4, finger: .ringTip), .rightClick)
        XCTAssertEqual(menu.closingFinger, .ringTip)
        XCTAssertFalse(menu.isOpen)
        XCTAssertTrue(menu.consumeClosingContact(distance: 0.1, releaseThreshold: 0.38))
        XCTAssertTrue(menu.consumeClosingContact(distance: 0.6, releaseThreshold: 0.38))
        XCTAssertFalse(menu.consumeClosingContact(distance: 0.6, releaseThreshold: 0.38))
    }

    func testCancelAndTimeoutCannotExecuteCommands() {
        let menu = GestureCommandMenu()
        open(menu)
        menu.cancel()
        XCTAssertNil(aim(menu, at: .zero, distance: 0.1))
        open(menu)
        let oldID = menu.snapshot!.id
        XCTAssertNil(aim(menu, at: .zero, distance: 0.1, time: 30))
        XCTAssertFalse(menu.isOpen)
        open(menu)
        menu.setTileFrames([:], for: oldID)
        _ = aim(menu, at: CGPoint(x: -690, y: 201))
        XCTAssertEqual(menu.snapshot?.selected, .rightClick)
    }

    func testNewClickCommandsUseCapturedTargetAndDoNotMoveCursor() {
        let poster = RecordingEventPoster()
        let target = CGPoint(x: 700, y: 400)
        poster.postCommand(.rightClick, at: target)
        poster.postCommand(.doubleClick, at: target)
        XCTAssertEqual(poster.allEvents, [.rightClick(target), .doubleClick(target)])
    }

    func testStaleCommandIsDroppedBeforeValidCommand() {
        let poster = RecordingEventPoster()
        let coordinator = EventOutputCoordinator(synthesizer: poster)
        coordinator.epochProvider = { 2 }
        coordinator.injectionAllowedProvider = { true }
        coordinator.enqueueCommand(.rightClick, at: .zero, epoch: 1)
        coordinator.enqueueCommand(.doubleClick, at: .zero, epoch: 2)
        let done = expectation(description: "Output drained")
        coordinator.enqueueValidatedAction(epoch: 2) { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(poster.allEvents, [.doubleClick(.zero)])
    }

    func testWindowHalvesRespectVisibleBoundsAndNegativeDisplayOrigins() {
        let visible = CGRect(x: -1920, y: 25, width: 1920, height: 1025)
        let left = WindowSnapper.frame(in: visible, right: false)
        let right = WindowSnapper.frame(in: visible, right: true)
        XCTAssertEqual(left.union(right), visible)
        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(left.width, 960)
    }

    func testKeyboardCommandsReleaseModifiers() {
        let poster = RecordingEventPoster()
        for command in [GestureCommand.missionControl, .minimize, .fullScreen] {
            poster.reset()
            poster.postCommand(command, at: .zero)
            XCTAssertEqual(poster.allEvents.count, 2)
            guard case .keyEvent(_, let down, let flags) = poster.allEvents.last else { return XCTFail("Expected key release") }
            XCTAssertFalse(down)
            XCTAssertEqual(flags, 0)
        }
    }
}
