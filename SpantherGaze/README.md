# SpantherGaze (iOS)

Native SPANTHER prototype: SwiftUI + SpriteKit + ARKit face tracking. Meteors fall toward Earth; holding your gaze on one bursts it. Gaze time per size comes from `docs/BALANCE.md` (S 0.5 s, M 0.8 s, L 1.2 s, XL 2.0 s) through `SpantherGaze/Resources/balance.json`.

## Status

- `GazeCore` (pure Swift) builds and its 81 unit tests pass with Swift 6.0 on Linux and in CI.
- The app target compiles in GitHub Actions (Xcode 16.4 Release, and the newest Xcode on the runner in Debug), unsigned. Step-by-step Mac instructions (in Russian) are in the root README, the Windows route is in `SIDELOAD.md`.
- First run on a real iPhone: Aziz, iPhone 13, 2026-11-04, installed with Sideloadly, played to level 6. Check error 1.29 cm; tracking ran at 30 fps, not 60. The aim went wild from level 5 on, which led to the gaze model changes below (replayed on that session, not yet confirmed on the phone). Every frame interval in that CSV was 33.3 ms from the first calibration dot, so the camera ran at 30 fps from the start, not after heating up. The CSV and the debug overlay now show the camera format, the formats the phone offers, the thermal state and Low Power Mode, so the next session shows why.
- CI also runs the app in the iOS Simulator (job `simulator-smoke`): a Debug-only bot plays with the launch argument `-SpantherAutoplay eyes|touch|wink|rhythm`, the job checks that the app keeps running and that kills spend energy and reloads happen, that the wink test and a rhythm track play to the end, and it pushes screenshots, session CSVs and logs to the `ci-screenshots` branch. Face tracking does not exist in the Simulator, so "eyes" there means the bot's gaze.

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
| Tracking | `SpantherGaze/Tracking` | `FaceTracker` runs ARKit off the main thread and picks the fastest video format the phone offers (CLAUDE.md asks for 60 fps; the first iPhone 13 session ran at 30). It reports that format, the thermal state and Low Power Mode to the debug overlay and the CSV. `PupilDetector` protocol with a Vision implementation; MediaPipe can be added behind the same protocol to compare on the same recordings. |
| Screens | `SpantherGaze/Screens` | Menu, 9-dot calibration, 13-dot check (error and jitter in pt, cm and degrees), SpriteKit game, debug overlay. |
| Logging | `SpantherGaze/Logging` | CSV exported only through the Share button: calibration/check samples, every tracked frame of an eye game (`frame`: features, gaze, raw `eyeBlinkLeft/Right`, gaze-hold flag), every meteor outcome, `blink` / `energy` / `reload` events, `tracking` rows (camera format, formats offered, thermal state, Low Power Mode) at the start of a session and on each change, and each frame's processing time (`proc_ms`). |

## Gaze pipeline

1. ARKit gives the face pose, both eye transforms and `lookAtPoint`. Two rays per eye (through `lookAtPoint`, and along the eye's own axis) are intersected with the screen plane (camera z = 0).
2. Feature vector: both ray hits, quadratic terms on the `lookAtPoint` hit, and Vision pupil offsets when "Зрачки через Vision" is on. A pupil result stays usable for 0.3 s; with none, the pupil features count as the calibration average. Head pose is not a feature: the hits already move with the head and the phone, and as separate features the pose terms made the aim follow the phone when it moved (see `GazeFeatures.vector`).
3. 9 dots, about 1 s of samples each. The player is told they may move their head a little, which lowered error in the study cited in `docs/eye-tracking-options.md`.
4. Ridge regression maps features to screen points; a One Euro filter smooths the result. Each feature is clamped to its calibrated range plus 25%, so the quadratic terms cannot throw the aim thousands of points away.
5. When the `lookAtPoint` hit is further outside its calibrated range than the range itself, the player is looking away from the screen: the aim hides (`notLooking`) instead of flying off, and the filter restarts.
6. 13 new dots measure mean error and jitter. The hit zone is drawn radius + that error, clamped to 30–115 pt.
7. The aim adapter (`GazeAdapter` in `GazeCore/Adapt.swift`) adds a small correction to the ridge prediction, before the filter, so the aim stays on target when the phone is held at another tilt than at calibration. See below.

## Aim adapter (the phone held differently)

In the first iPhone sessions the aim slid when the phone's tilt changed after calibration. The ridge model is fitted at one grip, and the lookAt hits and pupil offsets it reads shift a little with the head's angle to the camera. The model itself is unchanged; on top of it:

- correction = b + B · (head pitch and yaw − the calibration's mean pose), per screen axis. `b` takes a slow drift, `B` how the aim moves with tilt, so a new tilt is corrected before the next label.
- `B` starts from physics, not from zero: the raw aim follows a turn of the head against the phone by a share of that turn projected on the screen (calibration distance × angle × 60 pt/cm). Aziz's rhythm session of 7 November showed a share of 1.25–1.6 for pitch (36–47 pt per degree at 27 cm) and about 0.7 for yaw; the defaults are 1.0 and 0.5, and labels refine them. Labels almost never come at different tilts, because players hold still while they aim, so a `B` learned from labels alone stayed near zero and the tilt went uncorrected.
- It is learned from moments when the game knows where the player looks: the 13 check dots (a warm start), the rhythm start star and every rhythm note winked in its window (the median raw aim over the 0.3 s before the eye closed), and the meteor being burned in the eye game (each frame at 1/20 of a label's weight).
- Labels lose half their weight every 15 s, a prior keeps the bias at zero and the tilt terms at their starting values until there is evidence, a label further than 180 pt from both the corrected and the raw aim is left out, and the correction is capped at 300 pt.
- Menu toggle «Подстройка прицела под наклон» turns it off to compare. The debug overlay shows the correction, labels learned and left out; the CSV has `label` rows and the correction on every frame (`corr_x_pt`, `corr_y_pt`).
- `GazeReplay` replays it on a session (prequential: each label is predicted before it is learned) and prints the mean distance to the labels without and with the adapter, by source and by head pitch, and a sweep over the starting pitch and yaw shares. On Aziz's rhythm session the rhythm notes were 1.19 cm from the raw aim, 0.47 cm from the aim corrected by the adapter as it was before the starting slope, and 0.36 cm with it.

## Replaying a session (CLAUDE.md rule 7)

Export the CSV on the phone (menu, «Экспорт CSV последней сессии»), then run the current GazeCore code over it:

```
cd GazeCore && swift run GazeReplay ~/Downloads/spanther-2026-11-05_01-13-16.csv
```

It refits the calibration for each feature set and prints the check error, how often the aim leaves the screen in each level, how often the player counted as looking away, and the blink detector's blinks and reloads next to the ones the app logged. For files recorded after 4 November 2026 it also prints the camera format, thermal state and frame processing time. Use it to compare tracking changes on the same recording instead of a new attempt. Session CSVs are face data: keep them out of the repository (rule 5).

## Gameplay (all from balance.json)

- Progress drains to zero over 1 s when the gaze leaves; tracking dropouts under 150 ms freeze it; after 1 s without a face the game pauses with "Посмотри на экран".
- The meteor being looked at slows down by 40% on levels 1–3 and 20% later.
- 10 levels of 45 s on the S-curve from BALANCE.md, 5 Earth shields, no game-over screen: running out of shields restarts the level a little easier.
- Kill ratio at the end of a level: 80% or more advances, under 50% repeats easier, in between repeats at the same difficulty (BALANCE.md does not say; this is my default).
- "Играть пальцем" uses the same rules with a finger on the meteor.
- Energy pool of 10; a kill costs S 1, M 2, L 3, XL 5. A meteor you cannot afford gets a red ring, the aim on it turns red, and it makes no progress. Three blinks within 2 s (or three taps on the energy bar in touch mode) refill the pool. `BlinkDetector` in `GazeCore/Energy.swift` reads ARKit `eyeBlinkLeft/Right`; while the lids close the gaze point is held so the aim does not dip.

## Wink test (groundwork for the rhythm mode)

Menu, «Тест подмигиваний». A click sounds every second and the screen lights the eye to wink on it: 20 left, 20 right, then 20 alternating, about 72 s. The result screen shows, per eye, how many cues the detector caught on the asked eye, the mean timing offset and its spread, how many hits land within ±100, ±180 and ±250 ms once that offset is removed, and how far the other eye squinted. «Отправить CSV» exports the session. `WinkDetector` in `GazeCore/Wink.swift` reads the same ARKit `eyeBlinkLeft/Right` values as the reload blinks: an eye is closed at 0.6 or its open level + 0.3, and both eyes closing within 25 ms (or 1.5 frames at a lower frame rate) is a blink, not a wink. Natural blinks close both eyes within 0–17 ms; in Aziz's wink test the other eye often followed a wink 2–3 frames later (33–50 ms), and those stay winks. `GazeReplay` reads the test's `wink_frame`, `cue` and `wink` rows and replays the detector at close thresholds 0.5, 0.6 and 0.7 on the same run.

## Rhythm mode

Menu, «Ритм: подмигивай в такт». An original rhythm game drawn as a star atlas on warm paper (light paper also lights the face for the camera). Stars appear to the beat; a dial hand goes round each one and reaches the red mark at 12 o'clock on its beat. The player looks at the star and closes an eye then. Notes hit in a row join into a constellation, and the results screen shows it as a plate.

- Start: «Посмотри на звезду и подмигни». The wink on the start star (or a tap) starts the music 1 s later and gives the aim adapter its first label at the current grip.
- No visible aim. A cursor that sits a little off the spot the player looks at pulls the eyes after it, and both drift off together. Instead the star the aim is near lights up (a warm wash under it, and the star grows a little) and holds the aim: `GazeLock` in `GazeCore/Lock.swift` locks the nearest star within the level's hit zone, keeps it until the aim is 1.4 zones away, another star in reach is clearly closer, or the aim has been gone for 0.35 s. A wink plays the locked star, even where an earlier note's window holds the wink too. `GazeReplay` replays the lock over a recorded play: on Aziz's of 7 November it was on the note he winked at in 24 of 24 winks, and it changed 54 times over 25 notes, so the light barely flickers. The aim is drawn only with «Отладка» on.
- Levels: easy plays the strongest accents, at least 1 s apart, and also takes an ordinary blink, for players who cannot wink yet. Normal plays more notes with either eye. Hard plays all accents up to 2 notes/s, and a note on the left half of the screen needs the left eye, on the right half the right eye.
- Judging (`RhythmJudge` in `GazeCore/Rhythm.swift`): windows ±90 / ±160 / ±240 ms («Точно», «Хорошо», «Есть»), on the onset of the closure minus the player's delay. The aim must be within 90 / 70 / 55 pt + the check error (up to 90) of the note. The delay starts at 0.12 s, is seeded by the wink test and learned in play.
- By finger: the hand button next to «Играть». A tap plays the note under the finger as a wink of that side's eye. It is the only way on iPhones without face tracking.
- Tracks: three CC0 tracks composed for the game by `Tools/compose_tracks.py` («Орбита» 88 BPM, «Звёздная пыль» 104, «Метеоритный дождь» 124, about 1–1.5 min). The script writes the `.m4a` files into `SpantherGaze/Resources` and `tracks.json`: tempo, first beat and an accent list (beat, strength 1–3) from the score, which the notes follow. To use another song, put the file in Resources and give its tempo and first beat in `tracks.json`; without accents the notes follow a fixed pattern on the beats. `RhythmTests.testBundledTracks` checks the bundled tracks.
- CSV rows: `rhythm_start`, `note_hit` and `note_miss` (judgement, timing offset, aim distance, eye, the locked note), `rhythm_end`, `label` and `rhythm_frame` (with the locked note in `locked`: its index, -1 for the start star).

## Unverified on device

- The portrait axis mapping in `Transforms.cameraPlaneToPortrait` and the Vision image orientation `.leftMirrored` are best guesses. Calibration absorbs axis mix-ups, but check them in the debug overlay.
- 60 pt per cm is assumed for cm figures (current iPhones are 60–64).
- Blink thresholds (0.6 closed, 0.35 open, 50–500 ms) are starting values and need tuning on real faces, children's especially.
- Winks: whether ARKit's `eyeBlinkLeft` is the player's left eye, how much the other eye closes during a wink, and the delay from a click to the wink onset. The wink test measures all three.
- The aim adapter's numbers (15 s half-life, 180 pt gate, 300 pt cap, the starting tilt shares 1.0 and 0.5, the meteor label weight) are starting values. Compare the toggle on and off on the same session with `GazeReplay`.
- The rhythm lock's numbers (release at 1.4 hit zones, switch at 0.6, 0.35 s grace) are starting values, and whether players find the notes without a visible aim needs a try on the phone.
- Rhythm mode: the music's start against the camera clock (`AVAudioPlayer.play(atTime:)` minus the route's output latency; Bluetooth headphones add 0.15–0.25 s), the judging windows and the note density for children.
