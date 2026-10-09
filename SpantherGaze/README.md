# SpantherGaze (iOS)

Native SPANTHER prototype: SwiftUI + SpriteKit + ARKit face tracking. Meteors fall toward Earth; holding your gaze on one bursts it. Gaze time per size comes from `docs/BALANCE.md` (S 0.5 s, M 0.8 s, L 1.2 s, XL 2.0 s) through `SpantherGaze/Resources/balance.json`.

## Status

- `GazeCore` (pure Swift) builds and its 16 unit tests pass with Swift 6.0.3 on Linux.
- The app target compiles in GitHub Actions (Xcode 16.4 Release, and the newest Xcode on the runner in Debug), unsigned. A signed build to a real iPhone has not been done yet. Step-by-step Mac instructions (in Russian) are in the root README.
- Nothing has run on an iPhone yet (CLAUDE.md rule 6).

## Build and run on an iPhone

1. Open `SpantherGaze.xcodeproj` in Xcode 16 or newer.
   If Xcode refuses the project file, run `brew install xcodegen && xcodegen generate` in this folder and open the generated project.
2. Target SpantherGaze → Signing & Capabilities → choose your Team (a free Apple ID works for your own phone). Change the bundle id if Xcode asks.
3. Connect the iPhone (TrueDepth camera or A12 chip and newer), select it, press Run.
4. The first time, allow the camera. On the phone, trust the developer in Settings → General → VPN & Device Management.

Unit tests: `cd GazeCore && swift test` (Mac or Linux). Camera code only works on a device; ARKit face tracking does not run in the Simulator.

## How it fits CLAUDE.md

| Module | Files | Notes |
|---|---|---|
| GazeCore | `GazeCore/Sources/GazeCore` | Matrices, coordinate transforms (all in `Transforms.swift`), gaze ray to screen plane, ridge calibration, One Euro, accuracy metrics, balance config, the full game model. No UIKit/ARKit. |
| Tracking | `SpantherGaze/Tracking` | `FaceTracker` runs ARKit at 60 fps off the main thread. `PupilDetector` protocol with a Vision implementation; MediaPipe can be added behind the same protocol to compare on the same recordings. |
| Screens | `SpantherGaze/Screens` | Menu, 9-dot calibration, 13-dot check (error and jitter in pt, cm and degrees), SpriteKit game, debug overlay. |
| Logging | `SpantherGaze/Logging` | CSV of calibration/check samples and every meteor outcome, exported only through the Share button. |

## Gaze pipeline

1. ARKit gives the face pose, both eye transforms and `lookAtPoint`. Two rays per eye (through `lookAtPoint`, and along the eye's own axis) are intersected with the screen plane (camera z = 0).
2. Feature vector: both ray hits, quadratic terms, head yaw/pitch/roll, distance, and Vision pupil offsets when "Зрачки через Vision" is on.
3. 9 dots, about 1 s of samples each. The player is told they may move their head a little, which lowered error in the study cited in `docs/eye-tracking-options.md`.
4. Ridge regression maps features to screen points; a One Euro filter smooths the result.
5. 13 new dots measure mean error and jitter. The hit zone is drawn radius + that error, clamped to 30–115 pt.

## Gameplay (all from balance.json)

- Progress drains to zero over 1 s when the gaze leaves; tracking dropouts under 150 ms freeze it; after 1 s without a face the game pauses with "Посмотри на экран".
- The meteor being looked at slows down by 40% on levels 1–3 and 20% later.
- 10 levels of 45 s on the S-curve from BALANCE.md, 5 Earth shields, no game-over screen: running out of shields restarts the level a little easier.
- Kill ratio at the end of a level: 80% or more advances, under 50% repeats easier, in between repeats at the same difficulty (BALANCE.md does not say; this is my default).
- "Играть пальцем" uses the same rules with a finger on the meteor.

## Unverified on device

- The portrait axis mapping in `Transforms.cameraPlaneToPortrait` and the Vision image orientation `.leftMirrored` are best guesses. Calibration absorbs axis mix-ups, but check them in the debug overlay.
- 60 pt per cm is assumed for cm figures (current iPhones are 60–64).
