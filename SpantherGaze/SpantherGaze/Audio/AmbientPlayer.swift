import AVFoundation

/// The calm music of the meteor game: plays GazeCore's `AmbientPad` through AVAudioEngine. The pad fades in and
/// out by itself, sample by sample; this class only starts the engine when music is asked for and pauses it once
/// the pad has gone silent. All of it runs on its own queue, never on the main thread (CLAUDE.md rule 4), and the
/// pad's samples are made on the audio thread.
final class AmbientPlayer {
    private let queue = DispatchQueue(label: "spanther.ambient", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var pad: AmbientPad?
    private var wanted = false
    private var pause: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var rate = 0.0
    /// What happened at the last start, for the debug line: "playing", "no output", "other audio", "failed".
    private var state = "off"

    init() {
        let center = NotificationCenter.default
        // A call or an alarm stops the engine; when it is over the music comes back if it is still wanted.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.queue.async { self?.resume() }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        engine?.stop()
    }

    /// True: fade in (starting the engine if needed). False: fade out, then pause the engine. Any thread.
    func setPlaying(_ on: Bool) {
        queue.async { [weak self] in self?.apply(on) }
    }

    private func apply(_ on: Bool) {
        guard on != wanted else { return }
        wanted = on
        pause?.cancel()
        pause = nil
        if on {
            resume()
        } else {
            pad?.setPlaying(false)
            // The pad needs `fadeOutSec` to reach silence; the engine keeps pulling until then.
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.wanted else { return }
                self.engine?.pause()
            }
            pause = work
            queue.asyncAfter(deadline: .now() + AmbientPad.fadeOutSec + 0.5, execute: work)
        }
    }

    private func resume() {
        guard wanted else { return }
        if engine == nil { build() }
        guard let engine, let pad else { return }
        if !engine.isRunning {
            try? AVAudioSession.sharedInstance().setActive(true)
            do {
                try engine.start()
            } catch {
                state = "failed"
                return
            }
        }
        state = "playing"
        pad.setPlaying(true)
    }

    /// Makes the engine: the pad as a source node into the main mixer, at the output's own sample rate.
    private func build() {
        let session = AVAudioSession.sharedInstance()
        // The player's own music from another app stays as it is: no pad over it.
        if session.isOtherAudioPlaying {
            state = "other audio"
            return
        }
        // Playback, like the rhythm tracks and the wink test's clicks, so it sounds with the ring switch off.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        let engine = AVAudioEngine()
        // Without an output (a Simulator on a machine with no sound card) connecting a node would raise an
        // exception Swift cannot catch, so the format is checked first.
        let out = engine.outputNode.outputFormat(forBus: 0)
        guard out.sampleRate >= 8000, out.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: out.sampleRate, channels: 2) else {
            state = "no output"
            return
        }
        let pad = AmbientPad(sampleRate: out.sampleRate)
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count > 0, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            pad.render(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        // When the output changes (headphones, a speaker) the engine stops by itself: build a new one.
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                self.engine?.stop()
                self.engine = nil
                self.pad = nil
                self.resume()
            }
        })
        self.engine = engine
        self.pad = pad
        rate = out.sampleRate
    }

    /// One line for the debug file of the Simulator run: what the engine did and how much sound the pad made.
    func debugLine() -> String {
        queue.sync {
            let frames = pad?.renderedFrames ?? 0
            let peak = pad?.peak ?? 0
            return String(format: "ambient %@, %.0f Hz, %ld frames, peak %.3f", state, rate, frames, Double(peak))
        }
    }
}
