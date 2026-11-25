# AuraMotion Pro

### Hand gestures. Native macOS control.

AuraMotion Pro is a native macOS menu-bar application that turns camera-based hand gestures into cursor movement, scrolling, clicks, clipboard shortcuts, and application switching. Built with Swift 6 and Apple's Vision framework, it processes hand landmarks on-device without MediaPipe or a separate machine-learning runtime.

Adaptive cursor filtering, personal calibration, and a gesture state machine help make touch-free interaction more responsive and predictable. A floating HUD displays tracking and permission status, while a hand-operated command menu provides additional mouse and window controls.

**Status:** Active development. Recognition quality depends on lighting, camera placement, hand visibility, and calibration. Automated tests cover interaction logic and synthetic tracking scenarios; they do not establish accuracy or latency for every live-camera environment.

## Features

- **Cursor stabilization:** Whole-hand landmark fusion, adaptive One Euro filtering, tremor suppression, and isolated-jump rejection.
- **Gesture input:** Point to move, extend two fingers to scroll, pinch to click or drag, and use fingertip contacts for copy and paste.
- **Application switching:** Swipe an open palm to switch apps. Settings also support switching Spaces or windows of the current app.
- **Hand command menu:** Access nine mouse, application, and window actions through a floating selection grid.
- **Personal calibration:** Separate guided setups for fingertip contacts and cursor movement response.
- **Live feedback:** A non-activating HUD, click feedback, hand skeleton, and diagnostics for frame rates, inference timing, and cursor filtering.
- **Input coordination:** Permission checks, stale-event rejection, drag release handling, and optional yielding to physical mouse-button input.
- **Local processing:** Camera frames are processed on-device. Optional diagnostic recording saves hand landmarks locally rather than video.

## Requirements

- macOS 14 or later.
- A Mac with a working built-in or external camera. Development and tuning have focused on Apple Silicon.
- Xcode with a Swift 6 toolchain and the macOS SDK selected for command-line builds.
- Camera and Accessibility access. Input Monitoring enables physical-input arbitration.

The package uses Apple frameworks and an included C11 atomics target; it does not declare third-party package dependencies.

## Getting started

Run these commands from the repository root:

```bash
./scripts/build_app.sh
./scripts/start.sh
```

The build script compiles the release executable, creates `build/AuraMotion.app`, applies an ad-hoc signature, and verifies the bundle's signature. The startup script stops an existing AuraMotion process and launches the bundled executable directly.

For a double-click startup from Finder, use **Start AuraMotion.command** in the repository root. It opens Terminal and runs the same startup script. Keep this file alongside the `scripts` and `build` directories.

You can also launch the application bundle directly:

```bash
open build/AuraMotion.app
```

### Permissions

Grant the requested access in **System Settings → Privacy & Security**:

| Permission | Purpose |
| --- | --- |
| Camera | Capture frames for hand-pose detection. |
| Accessibility | Control the pointer, send input, and manipulate supported windows. |
| Input Monitoring | Observe physical input so gesture control can yield to mouse-button presses. Optional for arbitration. |

The app also checks macOS event-posting authorization before injecting input. Click a red warning in the HUD to open the corresponding macOS privacy pane. The HUD’s **Settings** button opens AuraMotion preferences even while access is pending.

Local builds are ad-hoc signed. After a rebuild, macOS may require authorization for the updated executable even when an older AuraMotion entry is enabled. If the app reports missing access:

1. Quit AuraMotion from its menu-bar menu.
2. Remove an outdated AuraMotion entry from the relevant privacy setting.
3. Add the current `build/AuraMotion.app` and enable access.
4. Relaunch AuraMotion and check the permission status in **Settings…**.

The Terminal launcher does not bypass macOS permissions, and permissions granted to another launch context may not apply to the Finder-launched app. Add the application bundle when authorizing AuraMotion, rather than the `.command` launcher. Permission changes are checked periodically and when the app becomes active.

### First use

Keep your hand clearly visible to the camera with even lighting and an uncluttered background. Start with small, deliberate movements.

From the AuraMotion menu-bar icon:

1. Open **Calibration…** to record separated and touching fingertips for click, copy, and paste.
2. Open **Movement Calibration…** to record still, slow, and faster movements and personalize cursor response.
3. Open **Settings…** to adjust activation delay, mirroring, scroll inertia, palm-swipe behavior, and visual feedback.

In **Settings**, choose **Thumb** or **Index** under **Pointer fingertip**. The default thumb anchor lets you bring a finger to the thumb while keeping the pointer on target. Turn off **Click by pinching any finger to the thumb** to use the middle and ring fingers for clipboard shortcuts. Both preferences can be changed independently.

**Smooth pointer and hand preview at 60 Hz** enables bounded prediction between camera observations. Clicks and commands use observed fingertip contacts. **Camera format after restart** offers BGRA (default) and native YUV (NV12) on supported cameras. Restart AuraMotion to apply the format, then check **Active camera format** to see the format delivered by the camera.

Gesture control pauses during calibration and restores its previous pause state when you save, cancel, or close the calibration window.

## Gesture guide

| Action | Gesture | Behavior |
| --- | --- | --- |
| Move cursor | Aim with the selected fingertip and move your hand. | Thumb aiming works with the index finger relaxed. The pointing pose engages after the configured activation delay. |
| Left click | Bring a fingertip to the thumb. | By default any of the four fingers can click. Separate the fingertips before repeating. |
| Drag | Keep the clicking finger and thumb touching, then move. | Sustained contact and movement beyond the drag threshold start dragging. Separate the fingers to release. A stationary pinch may click before dragging begins. |
| Scroll | Extend your index and middle fingers together. | Move vertically or horizontally to scroll. Return to index-only pointing to stop scrolling and resume cursor control. |
| Copy | Touch your thumb tip to your middle fingertip. | Sends Command-C when any-finger clicking is off. |
| Paste | Touch your thumb tip to your ring fingertip. | Sends Command-V when any-finger clicking is off. |
| Previous app | Swipe an open palm left. | Sends Command-Shift-Tab in the default app-switching mode. |
| Next app | Swipe an open palm right. | Sends Command-Tab in the default app-switching mode. |
| Open command menu | Hold an open palm still for about 0.9 seconds. | Opens the grid on the display containing the cursor and remembers the original target. |
| Select a command | Aim the normal system cursor at a tile, then pinch. | The menu uses the same pointer anchor, mapping and smoothing as the desktop. |
| Dismiss command menu | Fold/lower your hand or move it out of view. | Cancels selection. The menu also times out automatically. |
| Pause or resume | Use the menu-bar **Pause Gesture Control** toggle. | Suspends or resumes gesture control. |

Copy and paste act on the focused application's selection and clipboard support. Separate your fingertips between repeated actions. Swipe behavior is configurable; Spaces mode requires an available neighboring desktop or full-screen space.

### Command menu

The nine commands are **Right click**, **Double click**, **All windows / Mission Control**, **Previous app**, **Next app**, **Minimize**, **Full screen**, **Left half**, and **Right half**.

Mouse actions use the cursor target captured before the menu opens. Window resizing depends on the target application's Accessibility support and minimum window size. Shortcut-based actions depend on the active app and macOS shortcut configuration.

### HUD and background behavior

AuraMotion runs as a menu-bar application. Closing or hiding the floating HUD does **not** quit gesture control. Use **Quit AuraMotion** in the menu-bar menu to stop the application, or pause control when you want to keep it open without sending input.

## How it works

```text
Camera capture → Latest-frame mailbox → Vision hand landmarks
              → Tracking and cursor filtering → Gesture state machine
              → Permission-checked event output → macOS
```

- **Capture:** AVFoundation discards late frames, while a bounded mailbox keeps the newest available frame for inference.
- **Inference:** Apple's `VNDetectHumanHandPoseRequest` produces hand landmarks for tracking and pose evaluation.
- **Tracking:** Confidence checks, identity continuity, whole-hand fusion, and adaptive filtering reduce unstable cursor movement.
- **Interaction:** A serialized state machine coordinates pointing, pinching, dragging, scrolling, palm actions, and menu selection. Contact confirmation and release hysteresis reduce repeated or accidental actions.
- **Output:** Quartz events are coalesced and checked against cached permissions and interaction epochs before posting. Old queued events are rejected after control changes.
- **Arbitration:** A listen-only event tap and C11 atomics coordinate yielding to physical input. App-generated events are tagged to avoid self-interruption.

Drag-release handling covers application-managed interruptions such as tracking loss, pause, capture interruption, and normal shutdown. A forced process termination or system failure can prevent cleanup from executing.

## Project structure

```text
Sources/
├── AuraMotionApp/          App lifecycle, menu bar, and SwiftUI windows
├── AuraMotionCore/
│   ├── App/                Coordination, permissions, and quality management
│   ├── Capture/            Camera capture and frame mailbox
│   ├── Vision/             Hand-pose inference and observation decoding
│   ├── Tracking/           Landmark fusion, filtering, and coordinate mapping
│   ├── Interaction/        Gesture detection, state machine, and command menu
│   ├── Output/             Mouse, keyboard, scrolling, and window actions
│   ├── Domain/             Settings, samples, and calibration models
│   ├── Persistence/        Local settings and calibration storage
│   └── Diagnostics/        Telemetry, landmark recording, and replay
└── AuraAtomics/            C11 primitives for physical-input coordination
Tests/AuraMotionTests/      Unit tests and recorded landmark fixtures
Resources/                 Bundle metadata and entitlements
scripts/                   Build, launch, and diagnostic utilities
```

## Testing and diagnostics

Run the automated tests:

```bash
swift test
```

The test suites cover gesture transitions, contact confirmation, cursor stability, hand fusion, calibration, coordinate transforms, event coalescing, stale-event rejection, arbitration, permission handling, lifecycle behavior, and landmark replay.

For live observations, open **Diagnostics & Telemetry…** from the menu bar. It shows capture and inference rates, dropped frames, timing, fingertip confidence, and a raw-versus-filtered horizontal cursor trace. The Capture → Vision result measurement excludes event-output and display delay.

To compare BGRA and NV12 with a visible hand, quit AuraMotion and run `./scripts/compare_live.sh --with-hand` from a terminal with camera access. Keep one hand in view through the four trials. The script reports hand and thumb counts, frame rate, buffer size and timing for each format.

Run the synthetic Vision baseline separately:

```bash
./scripts/run_benchmark.sh
```

This benchmark invokes Vision on a blank frame. It measures framework invocation overhead, not live hand-detection accuracy or camera-to-cursor latency.

## Privacy and local data

Camera processing stays on-device, and the app does not upload camera frames or save video. Settings and calibration profiles are stored locally. If you explicitly start diagnostic landmark recording, the app saves timestamped hand samples as JSON under `~/Library/Application Support/AuraMotion/Recordings` for replay and debugging.

## Contributing

Bug reports should include the macOS version, Mac model, camera type, launch method, relevant permission status, and steps to reproduce the issue. For recognition problems, describe lighting, hand position, and the expected gesture.

For code changes, explain the resulting behavior and include relevant regression coverage when changing gesture recognition, filtering, input output, or lifecycle handling. Run `swift test` before submitting changes and distinguish automated results from live-camera observations.

See [CHANGES.md](CHANGES.md) for implementation notes and historical validation results.
