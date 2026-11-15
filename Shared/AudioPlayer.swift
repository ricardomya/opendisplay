import AVFoundation
import Foundation

/// Plays the pv 4 `ODAU` PCM frames the Windows sender routes from windows on
/// this display. 48 kHz stereo signed 16-bit little-endian, 20 ms per frame.
///
/// All AVAudioEngine/AVAudioSession work happens on a private serial queue.
/// The receiver's network queue only enqueues a frame and returns, so a slow or
/// blocked audio start can never stall video/control traffic (which is exactly
/// what froze the secondary display in the first build).
final class AudioPlayer {
    private let queue = DispatchQueue(label: "com.opendisplay.audio")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 48_000,
                                       channels: 2,
                                       interleaved: true)!
    private var pendingFrames = 0
    private var started = false
    private var startFailures = 0

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Called from the network queue: hand the frame over, never block it.
    func play(pcm: Data) {
        queue.async { [weak self] in
            self?.playOnQueue(pcm)
        }
    }

    private func playOnQueue(_ pcm: Data) {
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

        pendingFrames += frames
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.pendingFrames = max(0, self.pendingFrames - frames)
            }
        }

        // A stalled link can deliver a burst; drop the queue rather than let
        // latency grow without bound. 300 ms is well past normal jitter.
        if pendingFrames > 48_000 * 3 / 10 {
            player.stop()
            pendingFrames = 0
            player.play()
        }
    }

    private func startIfNeeded() {
        if started && engine.isRunning { return }
        if !started {
            started = true
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                     options: [.defaultToSpeaker])
            try? session.setActive(true)
            #endif
        }
        if !engine.isRunning {
            guard startFailures < 3 else { return }
            do {
                try engine.start()
                Log.info("audio: engine running, 48000 Hz stereo")
            } catch {
                startFailures += 1
                Log.info("audio: engine start failed (\(startFailures)/3): \(error)")
                return
            }
        }
        player.play()
    }

    /// Called from the network queue on disconnect; runs asynchronously.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.started else { return }
            self.player.stop()
            self.engine.stop()
            #if os(iOS)
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            self.started = false
            self.startFailures = 0
            self.pendingFrames = 0
        }
    }
}
