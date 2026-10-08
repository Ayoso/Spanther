# SPANTHER

Eye-controlled iPhone game for attention training (kids 6–10). Meteors fly at Earth; look at one and hold your gaze until it bursts. Bigger meteors need a longer look (0.5 / 0.8 / 1.2 / 2.0 s).

## Run it on an iPhone (for whoever has the Mac)

You need a Mac with **Xcode 16 or newer**, the iPhone (iPhone XS/XR or newer: face tracking needs a TrueDepth camera or an A12 chip) and a USB cable. A free Apple ID is enough.

1. `git clone https://github.com/Ayoso/Spanther.git` and open `SpantherGaze/SpantherGaze.xcodeproj`.
   If Xcode can't open the project file, run `brew install xcodegen && cd SpantherGaze && xcodegen generate` and open the generated project.
2. Click the **SpantherGaze** project → target **SpantherGaze** → **Signing & Capabilities**: tick *Automatically manage signing*, pick your **Team** (Xcode → Settings → Accounts to add an Apple ID). If it complains about the bundle id, change `com.spanther.SpantherGaze` to something unique like `com.<yourname>.spanther`.
3. Plug in the iPhone, unlock it, tap **Trust**. On iOS 16+ turn on Settings → Privacy & Security → **Developer Mode** and restart.
4. Pick the iPhone as the run destination at the top of Xcode and press **Run** (⌘R).
5. First launch on the phone: Settings → General → VPN & Device Management → trust the developer, then open SPANTHER and allow the camera.

With a free Apple ID the app runs for 7 days; press Run again to renew. The game cannot run in the Simulator with eye tracking (ARKit face tracking needs a real device); "Играть пальцем" works there.

This is the first time the app target meets a real Xcode: if the build shows errors, send a screenshot or the error text back.

Unit tests for the gaze math and game rules: `cd SpantherGaze/GazeCore && swift test`.

## Folders

- `SpantherGaze/` – the app (SwiftUI, SpriteKit, ARKit). Its README explains the gaze pipeline; SIDELOAD.md is the no-Mac route (GitHub Actions + Sideloadly).
- `docs/` – balance and eye-tracking notes. Gameplay numbers live in `SpantherGaze/SpantherGaze/Resources/balance.json`.
- `CLAUDE.md` – project rules and stages.
