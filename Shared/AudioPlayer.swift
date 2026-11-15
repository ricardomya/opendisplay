import AVFoundation
import Foundation

/// Plays the pv 4 `ODAU` PCM frames the Windows sender routes from windows on
/// this display. 48 kHz stereo signed 16-bit little-endian, 20 ms per frame.
///
/// Kept in Shared so the Mac targets still compile; the audio session setup is
/// iOS-only. A sender that never sends audio leaves this dormant.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 48_000,
                                       channels: 2,
                                       interleaved: true)!
    private let lock = NSLock()
    private var pendingFrames = 0
    private var started = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(pcm: Data) {
        let frames = pcm.count / 4                 // 2 channels × 2 bytes
        guard frames > 0 else { return }
        startIfNeeded()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(dst, base, pcm.count)
            }
        }

        lock.lock()
        pendingFrames += frames
        let backlog = pendingFrames
        lock.unlock()

        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.pendingFrames = max(0, self.pendingFrames - frames)
            self.lock.unlock()
        }

        // A stalled link can deliver a burst; drop the queue rather than let
        // latency grow without bound. 300 ms is well past normal jitter.
        if backlog > 48_000 * 3 / 10 {
            player.stop()
            lock.lock()
            pendingFrames = 0
            lock.unlock()
            player.play()
        }
    }

    private func startIfNeeded() {
        if started && engine.isRunning { return }
        if !started {
            started = true
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            #endif
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                Log.info("audio: engine start failed: \(error)")
                return
            }
        }
        player.play()
    }

    func stop() {
        guard started else { return }
        player.stop()
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        started = false
        lock.lock()
        pendingFrames = 0
        lock.unlock()
    }
}
