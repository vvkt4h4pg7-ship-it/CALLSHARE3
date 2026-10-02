import Foundation
import AVFoundation

// OpenCORE AMR-NB C ABI. The GitHub Actions build links the resulting
// libopencore-amrnb.a into the app without changing the Xcode project file.
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
    private var droppedRx = 0
    private var invalidRx = 0

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

    /// CallKit activates AVAudioSession first. This method then opens the
    /// microphone and starts the playback graph using the same 8 kHz mono
    /// PCM boundary used by AMR-NB.
    func start() {
        guard !isRunning else { return }

        do {
            applySessionCategory()
            try? audioSession.setPreferredSampleRate(8_000)
            try? audioSession.setPreferredIOBufferDuration(0.02)

            reportStatus("[VOICE] starting; route=\(routeDescription())")

            guard codec.isReady else {
                throw NSError(
                    domain: "J7Bridge.AMR",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "AMR encoder/decoder failed to initialize"]
                )
            }

            // Each call gets fresh codec state so encoder prediction and decoder
            // history cannot bleed across GSM calls.
            codec.reset()
            guard codec.isReady else {
                throw NSError(
                    domain: "J7Bridge.AMR",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "AMR codec reset/initialization failed"]
                )
            }
            reportStatus("[AMR] codec READY encoderMode=\(codec.encoderMode)")

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

            playerNode.volume = 1.0
            audioEngine.mainMixerNode.outputVolume = 1.0

            converter = AVAudioConverter(from: hardwareFormat, to: pcm8kFormat)
            guard converter != nil else {
                throw NSError(
                    domain: "J7Bridge.Audio",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Could not create hardware -> 8 kHz converter"]
                )
            }

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
                self?.processPCM(buffer)
            }

            txFrames = 0
            rxFrames = 0
            droppedRx = 0
            invalidRx = 0
            pcmAccumulator.removeAll(keepingCapacity: true)

            // Mark running before engine start so the first callback cannot be
            // rejected solely because the engine is transitioning to running.
            isRunning = true
            audioEngine.prepare()
            try audioEngine.start()
            playerNode.play()

            reportStatus(
                String(
                    format: "OPEN OK / mic %.0f Hz %dch -> AMR-NB 8k / speaker=%@",
                    hardwareFormat.sampleRate,
                    hardwareFormat.channelCount,
                    useSpeaker ? "YES" : "NO"
                )
            )
        } catch {
            isRunning = false
            inputRemoveTapSafely()
            audioEngine.stop()
            playerNode.stop()
            converter = nil
            reportStatus("ERROR AudioEngine: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning || audioEngine.isRunning else { return }

        isRunning = false
        inputRemoveTapSafely()
        playerNode.stop()
        playerNode.reset()
        audioEngine.stop()
        converter = nil
        pcmAccumulator.removeAll(keepingCapacity: true)
        codec.reset()
        reportStatus("CLOSED / codec reset")
    }

    /// Channel 3 carries one AMR-NB IETF/WFI frame. The first byte is the
    /// AMR ToC byte and the decoder returns exactly 160 samples for speech
    /// frames. The received speech mode is remembered so the reverse encoder
    /// uses the same mode instead of assuming MR122 forever.
    func receiveAMR(_ packet: Data) {
        guard !packet.isEmpty else { return }

        guard isRunning else {
            droppedRx += 1
            if droppedRx == 1 || droppedRx % 25 == 0 {
                reportStatus("[AMR] RX dropped while voice engine stopped len=\(packet.count)")
            }
            return
        }

        guard let frameInfo = codec.validateAndLearnMode(packet) else {
            invalidRx += 1
            if invalidRx == 1 || invalidRx % 25 == 0 {
                reportStatus("[AMR] RX INVALID frame #\(invalidRx) len=\(packet.count)")
            }
            return
        }

        guard let pcm = codec.decode(packet) else {
            reportStatus("[AMR] RX DECODE FAILED len=\(packet.count) ft=\(frameInfo.frameType)")
            return
        }

        rxFrames += 1
        if rxFrames == 1 || rxFrames % 25 == 0 {
            reportStatus(
                "[AMR] RX frame #\(rxFrames) len=\(packet.count) ft=\(frameInfo.frameType) " +
                "mode=\(frameInfo.encoderMode) -> PCM160"
            )
        }

        schedulePlayback(pcm)
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
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)

        guard let output = AVAudioPCMBuffer(
            pcmFormat: pcm8kFormat,
            frameCapacity: capacity
        ) else {
            reportStatus("[AUDIO] could not allocate 8 kHz PCM buffer")
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
            reportStatus("[AUDIO] no Int16 channel data")
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
                reportStatus("[AMR] TX ENCODE FAILED mode=\(codec.encoderMode)")
                continue
            }

            txFrames += 1
            if txFrames == 1 || txFrames % 25 == 0 {
                reportStatus("[AMR] TX frame #\(txFrames) len=\(amr.count) mode=\(codec.encoderMode)")
            }

            // CoreBluetooth work never runs directly on the audio callback.
            let callback = onAMRPacket
            DispatchQueue.main.async {
                callback?(amr)
            }
        }
    }

    private func schedulePlayback(_ pcm: [Int16]) {
        guard pcm.count == 160 else { return }
        guard audioEngine.isRunning else { return }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: pcm8kFormat,
            frameCapacity: 160
        ) else {
            reportStatus("[AUDIO] could not allocate playback buffer")
            return
        }

        buffer.frameLength = 160

        guard let channel = buffer.int16ChannelData?[0] else {
            reportStatus("[AUDIO] playback buffer has no Int16 channel")
            return
        }

        pcm.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.assign(from: base, count: pcm.count)
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func routeDescription() -> String {
        let inputs = audioSession.currentRoute.inputs.map {
            "\($0.portType.rawValue):\($0.portName)"
        }.joined(separator: ",")
        let outputs = audioSession.currentRoute.outputs.map {
            "\($0.portType.rawValue):\($0.portName)"
        }.joined(separator: ",")
        return "IN[\(inputs)] OUT[\(outputs)]"
    }

    private func reportStatus(_ value: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(value.replacingOccurrences(of: "\u{1B}[0m", with: ""))
        }
    }
}

final class AMRCodecAdapter {
    // AMR-NB mode numbers 0...7 correspond to the speech modes. Mode is
    // learned from the K7 incoming ToC byte so both directions use the same
    // negotiated speech rate whenever possible.
    private var currentEncoderMode: Int32 = 1

    private var encoder: UnsafeMutableRawPointer?
    private var decoder: UnsafeMutableRawPointer?
    private let lock = NSLock()

    // OpenCORE WFI/IETF frame sizes including the one-byte ToC/frame-type byte.
    private let expectedFrameBytes = [
        13, 14, 16, 18, 20, 21, 27, 32,
         6,  7,  6,  6,  0,  0,  0,  1
    ]

    init() {
        encoder = amrEncoderInit(0)
        decoder = amrDecoderInit()
    }

    deinit {
        lock.lock()
        let oldEncoder = encoder
        let oldDecoder = decoder
        encoder = nil
        decoder = nil
        lock.unlock()

        if let oldEncoder {
            amrEncoderExit(oldEncoder)
        }
        if let oldDecoder {
            amrDecoderExit(oldDecoder)
        }
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return encoder != nil && decoder != nil
    }

    var encoderMode: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return currentEncoderMode
    }

    func reset() {
        lock.lock()
        currentEncoderMode = 1
        let oldEncoder = encoder
        let oldDecoder = decoder
        encoder = nil
        decoder = nil
        lock.unlock()

        if let oldEncoder {
            amrEncoderExit(oldEncoder)
        }
        if let oldDecoder {
            amrDecoderExit(oldDecoder)
        }

        let newEncoder = amrEncoderInit(0)
        let newDecoder = amrDecoderInit()

        lock.lock()
        encoder = newEncoder
        decoder = newDecoder
        lock.unlock()
    }

    func validateAndLearnMode(_ amr: Data) -> (frameType: Int, encoderMode: Int32)? {
        guard let toc = amr.first else { return nil }

        let frameType = Int((toc >> 3) & 0x0F)
        guard frameType >= 0, frameType < expectedFrameBytes.count else { return nil }
        guard expectedFrameBytes[frameType] > 0 else { return nil }
        guard amr.count == expectedFrameBytes[frameType] else { return nil }

        if frameType <= 7 {
            lock.lock()
            currentEncoderMode = Int32(frameType)
            let mode = currentEncoderMode
            lock.unlock()
            return (frameType, mode)
        }

        lock.lock()
        let mode = currentEncoderMode
        lock.unlock()
        return (frameType, mode)
    }

    func encode160(_ pcm8k: [Int16]) -> Data? {
        guard pcm8k.count == 160 else { return nil }

        lock.lock()
        guard let encoder else {
            lock.unlock()
            return nil
        }
        let mode = currentEncoderMode

        var output = [UInt8](repeating: 0, count: 64)
        let written: Int32 = pcm8k.withUnsafeBufferPointer { speech in
            output.withUnsafeMutableBufferPointer { out in
                amrEncoderEncode(
                    encoder,
                    mode,
                    speech.baseAddress,
                    out.baseAddress,
                    0
                )
            }
        }
        lock.unlock()

        guard written > 0, Int(written) <= output.count else { return nil }
        return Data(output.prefix(Int(written)))
    }

    func decode(_ amr: Data) -> [Int16]? {
        guard let toc = amr.first else { return nil }
        let frameType = Int((toc >> 3) & 0x0F)
        guard frameType >= 0, frameType < expectedFrameBytes.count else { return nil }
        guard expectedFrameBytes[frameType] > 0, amr.count == expectedFrameBytes[frameType] else {
            return nil
        }

        lock.lock()
        guard let decoder else {
            lock.unlock()
            return nil
        }

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
        lock.unlock()

        return ok ? pcm : nil
    }
}
