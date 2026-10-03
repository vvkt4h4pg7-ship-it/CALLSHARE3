import Foundation
import AVFoundation

// OpenCORE AMR-NB C ABI. The CI build creates libopencore-amrnb.a from
// the supplied OpenCORE sources, so the working Xcode project itself does
// not need PBX source-file churn.
@_silgen_name("Encoder_Interface_init")
private func amrEncoderInit(_ dtx: Int32) -> UnsafeMutableRawPointer?

@_silgen_name("Encoder_Interface_exit")
private func amrEncoderExit(_ state: UnsafeMutableRawPointer?)

@_silgen_name("Encoder_Interface_Encode")
private func amrEncoderEncode(
    _ state: UnsafeMutableRawPointer?,
    _ mode: Int32,
    _ speech: UnsafePointer<Int16>?,
    _ out: UnsafeMutablePointer<UInt8>?,
    _ forceSpeech: Int32
) -> Int32

@_silgen_name("Decoder_Interface_init")
private func amrDecoderInit() -> UnsafeMutableRawPointer?

@_silgen_name("Decoder_Interface_exit")
private func amrDecoderExit(_ state: UnsafeMutableRawPointer?)

@_silgen_name("Decoder_Interface_Decode")
private func amrDecoderDecode(
    _ state: UnsafeMutableRawPointer?,
    _ input: UnsafePointer<UInt8>?,
    _ output: UnsafeMutablePointer<Int16>?,
    _ bfi: Int32
)

final class VoiceEngine: NSObject {
    private let audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private let playerNode = AVAudioPlayerNode()

    private var isRunning = false
    private var converter: AVAudioConverter?
    private var useSpeaker = true
    private var muted = false
    private var playbackConnected = false

    var onAMRPacket: ((Data) -> Void)?
    var onStatus: ((String) -> Void)?

    private let codec = AMRCodecAdapter()
    private var pcmAccumulator: [Int16] = []
    private var txFrames = 0
    private var rxFrames = 0

    // BLE AMR can arrive immediately after VOICE_OPEN, before CallKit has
    // activated the iOS audio session. Keep a short compressed-frame queue
    // instead of silently dropping those first frames.
    private let rxQueueLock = NSLock()
    private var pendingRXFrames: [Data] = []
    private let maxPendingRXFrames = 25

    private lazy var pcm8kFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 8_000,
            channels: 1,
            interleaved: false
        )!
    }()

    func setSpeakerDefault(_ enabled: Bool) {
        useSpeaker = enabled
        if isRunning {
            applySessionCategory()
        }
    }

    func setMuted(_ value: Bool) {
        muted = value
        reportStatus(value ? "MUTED" : "UNMUTED")
    }

    /// CallKit activates the audio session first; this method only configures
    /// the call route, starts microphone capture, and starts the playback graph.
    func start() {
        guard !isRunning else { return }

        do {
            applySessionCategory()

            let input = audioEngine.inputNode
            let hardwareFormat = input.inputFormat(forBus: 0)

            guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
                throw NSError(
                    domain: "J7Bridge.Audio",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No input audio route"]
                )
            }

            if !playbackConnected {
                audioEngine.attach(playerNode)
                audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: pcm8kFormat)
                playbackConnected = true
            }

            converter = AVAudioConverter(from: hardwareFormat, to: pcm8kFormat)

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
                self?.processPCM(buffer)
            }

            txFrames = 0
            rxFrames = 0
            pcmAccumulator.removeAll(keepingCapacity: true)

            audioEngine.prepare()
            try audioEngine.start()
            playerNode.play()

            // Only declare the engine running after AVAudioEngine has actually
            // started. AMR received before this point remains queued below.
            isRunning = true

            reportStatus(
                String(
                    format: "STARTED / mic %.0f Hz %dch -> AMR-NB 8k / speaker=%@",
                    hardwareFormat.sampleRate,
                    hardwareFormat.channelCount,
                    useSpeaker ? "YES" : "NO"
                )
            )

            drainPendingRXFrames()
        } catch {
            isRunning = false
            inputRemoveTapSafely()
            audioEngine.stop()
            playerNode.stop()
            converter = nil
            reportStatus("ERROR \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning || audioEngine.isRunning else { return }

        inputRemoveTapSafely()
        playerNode.stop()
        playerNode.reset()
        audioEngine.stop()
        converter = nil
        pcmAccumulator.removeAll(keepingCapacity: true)
        rxQueueLock.lock()
        let dropped = pendingRXFrames.count
        pendingRXFrames.removeAll(keepingCapacity: true)
        rxQueueLock.unlock()
        isRunning = false
        if dropped > 0 {
            reportStatus("[AMR] RX queue cleared on stop count=\(dropped)")
        }
        reportStatus("CLOSED")
    }

    /// BLE channel 3 carries one AMR-NB frame. OpenCORE's decoder consumes the
    /// IETF octet-aligned AMR frame and produces exactly 160 PCM samples (20 ms).
    func receiveAMR(_ packet: Data) {
        guard !packet.isEmpty else { return }

        // CallKit audio activation and BLE VOICE_OPEN are asynchronous. In the
        // observed trace, the first 14-byte AMR frames arrived before the
        // VoiceEngine was running and were previously dropped here.
        guard isRunning else {
            rxQueueLock.lock()
            if pendingRXFrames.count >= maxPendingRXFrames {
                pendingRXFrames.removeFirst()
            }
            pendingRXFrames.append(packet)
            let count = pendingRXFrames.count
            rxQueueLock.unlock()

            if count == 1 || count % 5 == 0 {
                reportStatus("[AMR] RX queued while engine stopped count=\(count) len=\(packet.count)")
            }
            return
        }

        decodeAndScheduleRX(packet)
    }

    private func decodeAndScheduleRX(_ packet: Data) {
        guard let pcm = codec.decode(packet) else {
            reportStatus("[AMR] RX decode FAILED len=\(packet.count)")
            return
        }

        rxFrames += 1
        if rxFrames == 1 || rxFrames % 25 == 0 {
            reportStatus("[AMR] RX frame #\(rxFrames) len=\(packet.count) -> PCM160")
        }

        schedulePlayback(pcm)
    }

    private func drainPendingRXFrames() {
        rxQueueLock.lock()
        let queued = pendingRXFrames
        pendingRXFrames.removeAll(keepingCapacity: true)
        rxQueueLock.unlock()

        guard !queued.isEmpty else { return }

        reportStatus("[AMR] RX queue drain count=\(queued.count)")
        for packet in queued {
            decodeAndScheduleRX(packet)
        }
    }

    private func applySessionCategory() {
        var options: AVAudioSession.CategoryOptions = [.allowBluetooth]
        if useSpeaker {
            options.insert(.defaultToSpeaker)
        }

        try? audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: options
        )
    }

    private func inputRemoveTapSafely() {
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func processPCM(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let converter else { return }

        let ratio = pcm8kFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * ratio + 64
        )

        guard let output = AVAudioPCMBuffer(
            pcmFormat: pcm8kFormat,
            frameCapacity: capacity
        ) else {
            return
        }

        var error: NSError?
        var supplied = false

        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }

            supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil else {
            reportStatus("[AUDIO] PCM converter error: \(error!.localizedDescription)")
            return
        }

        emit8kFrames(output)
    }

    private func emit8kFrames(_ buffer: AVAudioPCMBuffer) {
        guard let pointer = buffer.int16ChannelData?[0] else {
            reportStatus("[AUDIO] No Int16 channel data")
            return
        }

        pcmAccumulator.append(
            contentsOf: UnsafeBufferPointer(
                start: pointer,
                count: Int(buffer.frameLength)
            )
        )

        while pcmAccumulator.count >= 160 {
            let frame = Array(pcmAccumulator.prefix(160))
            pcmAccumulator.removeFirst(160)

            guard !muted else { continue }
            guard let amr = codec.encode160(frame) else {
                reportStatus("[AMR] TX encode FAILED")
                continue
            }

            txFrames += 1
            if txFrames == 1 || txFrames % 25 == 0 {
                reportStatus("[AMR] TX frame #\(txFrames) len=\(amr.count)")
            }

            // CoreBluetooth work is kept off the realtime audio thread.
            let callback = onAMRPacket
            DispatchQueue.main.async {
                callback?(amr)
            }
        }
    }

    private func schedulePlayback(_ pcm: [Int16]) {
        guard pcm.count == 160 else { return }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: pcm8kFormat,
            frameCapacity: 160
        ) else {
            return
        }

        buffer.frameLength = 160

        guard let channel = buffer.int16ChannelData?[0] else {
            reportStatus("[AUDIO] Playback buffer has no Int16 channel")
            return
        }

        pcm.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.assign(from: base, count: pcm.count)
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)

        if !playerNode.isPlaying && isRunning {
            playerNode.play()
        }
    }

    private func reportStatus(_ value: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(value)
        }
    }
}

final class AMRCodecAdapter {
    // MR122 (12.2 kb/s) produces 32-byte IETF octet-aligned AMR-NB frames
    // and is the highest-rate AMR-NB mode supported by OpenCORE.
    private let encoderMode: Int32 = 7
    private var encoder: UnsafeMutableRawPointer?
    private var decoder: UnsafeMutableRawPointer?

    init() {
        encoder = amrEncoderInit(0)
        decoder = amrDecoderInit()
    }

    deinit {
        if let encoder {
            amrEncoderExit(encoder)
        }

        if let decoder {
            amrDecoderExit(decoder)
        }
    }

    func encode160(_ pcm8k: [Int16]) -> Data? {
        guard pcm8k.count == 160, let encoder else { return nil }

        var output = [UInt8](repeating: 0, count: 64)

        let written: Int32 = pcm8k.withUnsafeBufferPointer { speech in
            output.withUnsafeMutableBufferPointer { out in
                amrEncoderEncode(
                    encoder,
                    encoderMode,
                    speech.baseAddress,
                    out.baseAddress,
                    0
                )
            }
        }

        guard written > 0, Int(written) <= output.count else {
            return nil
        }

        return Data(output.prefix(Int(written)))
    }

    func decode(_ amr: Data) -> [Int16]? {
        guard !amr.isEmpty, let decoder else { return nil }

        var pcm = [Int16](repeating: 0, count: 160)

        let ok = amr.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }

            pcm.withUnsafeMutableBufferPointer { pcmBuffer in
                amrDecoderDecode(
                    decoder,
                    base,
                    pcmBuffer.baseAddress,
                    0
                )
            }
            return true
        }

        return ok ? pcm : nil
    }
}
