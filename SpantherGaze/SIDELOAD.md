# Put SpantherGaze on an iPhone without a Mac

A GitHub Actions macOS runner compiles the app (no signing), and Sideloadly on Windows signs it with your free Apple ID and installs it over USB. Nothing here needs the paid Apple Developer Program.

## 1. Get the unsigned .ipa

1. The code lives in the GitHub repo `Ayoso/Spanther`. Every push to `main` runs **iOS build** (`.github/workflows/ios.yml`): GazeCore unit tests, then an unsigned Release build for iPhone.
2. Open the repo on GitHub → **Actions** → the latest green **iOS build** run → **Artifacts** → download `SpantherGaze-unsigned-ipa` and unzip it. You get `SpantherGaze-unsigned.ipa`.
   You can also start a build by hand with **Run workflow**.

## 2. Install with Sideloadly (Windows)

1. Install iTunes and iCloud **from apple.com** (the web installers, not the Microsoft Store versions), then Sideloadly from sideloadly.io.
2. Connect the iPhone by USB, unlock it and tap **Trust**.
3. In Sideloadly drag in `SpantherGaze-unsigned.ipa`, type your Apple ID and press **Start**. Use a spare Apple ID if you prefer.
4. On the iPhone: Settings → Privacy & Security → **Developer Mode** → on, restart (iOS 16+ asks for this once).
5. Settings → General → VPN & Device Management → your Apple ID → **Trust**.
6. Open SPANTHER and allow the camera.

## Limits of the free route

- The app stops opening after **7 days**; re-run Sideloadly to refresh it (Sideloadly can auto-refresh while the PC is on).
- A free Apple ID can have **3** sideloaded apps at once and 10 new app IDs per week.
- For testers beyond your own phone (TestFlight), you need the paid Apple Developer Program.
