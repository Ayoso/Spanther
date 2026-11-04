# SpantherGaze (iOS)

Native SPANTHER prototype: SwiftUI + SpriteKit + ARKit face tracking. Meteors fall toward Earth; holding your gaze on one bursts it. Gaze time per size comes from `docs/BALANCE.md` (S 0.5 s, M 0.8 s, L 1.2 s, XL 2.0 s) through `SpantherGaze/Resources/balance.json`.

## Status

- `GazeCore` (pure Swift) builds and its 38 unit tests pass with Swift 6.0 on Linux and in CI.
- The app target compiles in GitHub Actions (Xcode 16.4 Release, and the newest Xcode on the runner in Debug), unsigned. Step-by-step Mac instructions (in Russian) are in the root README, the Windows route is in `SIDELOAD.md`.
- First run on a real iPhone: Aziz, iPhone 13, 2026-11-04, installed with Sideloadly, played to level 6. Check error 1.29 cm; tracking ran at 30 fps, not 60. The aim went wild from level 5 on, which led to the gaze model changes below (replayed on that session, not yet confirmed on the phone).
- CI also runs the app in the iOS Simulator (job `simulator-smoke`): a Debug-only bot plays with the launch argument `-SpantherAutoplay eyes|touch`, the job checks that the app keeps running and that kills spend energy and reloads happen, and it pushes screenshots, session CSVs and logs to the `ci-screenshots` branch. Face tracking does not exist in the Simulator, so "eyes" there means the bot's gaze.

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
| Tracking | `SpantherGaze/Tracking` | `FaceTracker` runs ARKit off the main thread and asks for a 60 fps video format (the first iPhone 13 session ran at 30 fps). `PupilDetector` protocol with a Vision implementation; MediaPipe can be added behind the same protocol to compare on the same recordings. |
| Screens | `SpantherGaze/Screens` | Menu, 9-dot calibration, 13-dot check (error and jitter in pt, cm and degrees), SpriteKit game, debug overlay. |
| Logging | `SpantherGaze/Logging` | CSV exported only through the Share button: calibration/check samples, every tracked frame of an eye game (`frame`: features, gaze, raw `eyeBlinkLeft/Right`, gaze-hold flag), every meteor outcome, and `blink` / `energy` / `reload` events. |

## Gaze pipeline

1. ARKit gives the face pose, both eye transforms and `lookAtPoint`. Two rays per eye (through `lookAtPoint`, and along the eye's own axis) are intersected with the screen plane (camera z = 0).
2. Feature vector: both ray hits, quadratic terms on the `lookAtPoint` hit, and Vision pupil offsets when "Зрачки через Vision" is on. A pupil result stays usable for 0.3 s; with none, the pupil features count as the calibration average. Head pose is not a feature: the hits already move with the head and the phone, and as separate features the pose terms made the aim follow the phone when it moved (see `GazeFeatures.vector`).
3. 9 dots, about 1 s of samples each. The player is told they may move their head a little, which lowered error in the study cited in `docs/eye-tracking-options.md`.
4. Ridge regression maps features to screen points; a One Euro filter smooths the result. Each feature is clamped to its calibrated range plus 25%, so the quadratic terms cannot throw the aim thousands of points away.
5. When the `lookAtPoint` hit is further outside its calibrated range than the range itself, the player is looking away from the screen: the aim hides (`notLooking`) instead of flying off, and the filter restarts.
6. 13 new dots measure mean error and jitter. The hit zone is drawn radius + that error, clamped to 30–115 pt.

## Replaying a session (CLAUDE.md rule 7)

Export the CSV on the phone (menu, «Экспорт CSV последней сессии»), then run the current GazeCore code over it:

```
cd GazeCore && swift run GazeReplay ~/Downloads/spanther-2026-11-05_01-13-16.csv
```

It refits the calibration for each feature set and prints the check error, how often the aim leaves the screen in each level, how often the player counted as looking away, and the blink detector's blinks and reloads next to the ones the app logged. Use it to compare tracking changes on the same recording instead of a new attempt. Session CSVs are face data: keep them out of the repository (rule 5).

## Gameplay (all from balance.json)

- Progress drains to zero over 1 s when the gaze leaves; tracking dropouts under 150 ms freeze it; after 1 s without a face the game pauses with "Посмотри на экран".
- The meteor being looked at slows down by 40% on levels 1–3 and 20% later.
- 10 levels of 45 s on the S-curve from BALANCE.md, 5 Earth shields, no game-over screen: running out of shields restarts the level a little easier.
- Kill ratio at the end of a level: 80% or more advances, under 50% repeats easier, in between repeats at the same difficulty (BALANCE.md does not say; this is my default).
- "Играть пальцем" uses the same rules with a finger on the meteor.
- Energy pool of 10; a kill costs S 1, M 2, L 3, XL 5. A meteor you cannot afford gets a red ring, the aim on it turns red, and it makes no progress. Three blinks within 2 s (or three taps on the energy bar in touch mode) refill the pool. `BlinkDetector` in `GazeCore/Energy.swift` reads ARKit `eyeBlinkLeft/Right`; while the lids close the gaze point is held so the aim does not dip.

## Unverified on device

- The portrait axis mapping in `Transforms.cameraPlaneToPortrait` and the Vision image orientation `.leftMirrored` are best guesses. Calibration absorbs axis mix-ups, but check them in the debug overlay.
- 60 pt per cm is assumed for cm figures (current iPhones are 60–64).
- Blink thresholds (0.6 closed, 0.35 open, 50–500 ms) are starting values and need tuning on real faces, children's especially.
