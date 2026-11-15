import AVFoundation
import Foundation

/// Captures this device's microphone and emits 48 kHz mono signed 16-bit PCM
/// blocks for the Windows virtual-microphone bridge (`ODMI` frames).
///
/// The receiver shares one audio session between playback of the computer's
/// sound and this capture: the category is `.playAndRecord` with
/// `.mixWithOthers` so both work together, and AudioPlayer uses the same
/// category.
final class MicSource {
    /// 20 ms blocks at 48 kHz, mono s16, little-endian.
    var onPcm: ((Data) -> Void)?
    /// (running, reason): reason empty on success, "denied"/"unavailable".
    var onState: ((Bool, String) -> Void)?

    private let queue = DispatchQueue(label: "com.opendisplay.mic", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 48_000,
                                       channels: 1,
                                       interleaved: true)!
    private var converter: AVAudioConverter?
    private var running = false

    func start() {
        queue.async { self.startOnQueue() }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func startOnQueue() {
        guard !running else { return }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            startEngine()
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                self.queue.async {
                    if granted {
                        self.startEngine()
                    } else {
                        self.onState?(false, "denied")
                    }
                }
            }
        default:
            onState?(false, "denied")
        }
    }

    private func startEngine() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            Log.info("mic: audio session: \(error)")
            onState?(false, "unavailable")
            return
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            onState?(false, "unavailable")
            return
        }
        converter = AVAudioConverter(from: inputFormat, to: format)

        input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.info("mic: engine start failed: \(error)")
            input.removeTap(onBus: 0)
            onState?(false, "unavailable")
            return
        }
        running = true
        Log.info("mic: capturing \(Int(inputFormat.sampleRate)) Hz \(inputFormat.channelCount) ch")
        onState?(true, "")
    }

    private func stopOnQueue() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        Log.info("mic: stopped")
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard running, let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return
        }
        var supplied = false
        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        converter.convert(to: out, error: &conversionError, withInputFrom: inputBlock)
        if let conversionError {
            _ = conversionError
            return
        }
        guard out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        let data = Data(bytes: samples, count: Int(out.frameLength) * 2)
        onPcm?(data)
    }
}
