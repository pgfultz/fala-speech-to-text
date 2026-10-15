import AVFoundation
import Accelerate

/// Captures the microphone, reports levels and keeps a 16 kHz mono PCM copy for uploading.
final class AudioRecorder {
    /// Normalized 0...1 loudness, delivered on the audio thread.
    var onLevel: ((Float) -> Void)?
    /// Raw buffers in the input's native format, delivered on the audio thread.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var samples: [Int16] = []
    private let lock = NSLock()
    private(set) var peak: Float = 0

    func start() throws {
        engine = AVAudioEngine() // fresh engine picks up the current default input device
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        converter = AVAudioConverter(from: format, to: target)
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        peak = 0

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let level = Self.level(of: buffer)
            if level > self.peak { self.peak = level }
            self.onLevel?(level)
            self.onBuffer?(buffer)
            self.convert(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capturing and returns the recording as a WAV file.
    @discardableResult
    func stop() -> (wav: Data, seconds: Double) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let pcm = lock.withLock { samples }
        return (Self.wav(pcm, sampleRate: 16_000), Double(pcm.count) / 16_000)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.int16ChannelData else { return }
        let chunk = UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(buffer.frameLength))
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 52) / 42, 0), 1)
    }

    private static func wav(_ pcm: [Int16], sampleRate: Int) -> Data {
        var d = Data(capacity: 44 + pcm.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    enum RecorderError: LocalizedError {
        case noInput
        var errorDescription: String? { "Nenhum microfone disponível" }
    }
}
