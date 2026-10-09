# SPANTHER web prototype

Eye-controlled meteor game that runs in a phone browser. Look at a meteor and hold your gaze until it bursts. Small meteors need 0.5 s, medium about 1.0 s, large 1.6 s (dwell grows linearly with radius).

## Files

- `index.html` is the whole game (canvas, calibration, gaze math, RU/EN text).
- `vendor/` holds MediaPipe Tasks Vision 0.10.14 (Face Landmarker, iris points 468 to 477) so nothing loads from a CDN except fonts.

## Run it

The camera only works on `https://` or `http://localhost`.

- **On your PC with a webcam:** open a terminal in this folder, run `npx serve .` (or `python -m http.server 8000`) and open the printed `localhost` address in Chrome.
- **On your phone:** the page must be served over https. The quickest way is to drag this `web` folder onto https://app.netlify.com/drop and open the link it gives you on the phone. GitHub Pages works too.
- **No camera:** choose "Play with finger or mouse". Holding a finger (or hovering the mouse) on a meteor counts as looking at it, with the same dwell timing.

## How eye mode works

1. Face Landmarker runs on each video frame (GPU delegate, CPU fallback).
2. Features: iris position inside each eye relative to the eye corners and lids, plus head yaw, pitch and position.
3. Calibration: 9 dots, about 0.9 s of samples each, then a ridge regression maps features to screen position.
4. Check: 4 new dots measure the average miss and jitter. The hit zone around each meteor grows with that measured error.
5. A One Euro filter smooths the gaze point. If the face is lost for 0.8 s the game freezes until you look back.

Tap DBG during play to see tracking FPS, ms per frame, iris features, head angles, calibration error and each meteor's dwell progress.

## Tuning (top of the script in index.html)

- `DWELL_MIN` / `DWELL_MAX`: dwell for the smallest and largest meteor.
- `SIZES`: meteor radius as a share of the screen, and points.
- `GRACE` / `DRAIN`: how long the gaze may slip off before progress drains, and how fast.
