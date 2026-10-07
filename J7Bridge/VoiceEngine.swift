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
    private var audioSessionPrepared = false

    var onAMRPacket: ((Data) -> Void)?
    var onStatus: ((String) -> Void)?

    /// True only when both the VoiceEngine state and AVAudioEngine are actually running.
    /// AppModel uses this to avoid treating a stale `isRunning` flag as live audio.
    var isActuallyRunning: Bool {
        stateLock.lock()
        let running = isRunning && audioEngine.isRunning
        stateLock.unlock()
        return running
    }

    private let codec = AMRCodecAdapter()

    // All RX decode work is deliberately kept off the CoreBluetooth/SwiftUI
    // main queue. This is the most important latency fix on iPhone: a burst of
    // 20 ms BLE packets can no longer monopolize the UI queue while AMR decode
    // and AVAudioPlayerNode scheduling happen synchronously.
    private let rxQueue = DispatchQueue(
        label: "com.ugur.callshare.voice.rx",
        qos: .userInitiated
    )
    private let stateLock = NSLock()

    // This is a second bounded queue used only to prevent GCD itself from
    // accumulating thousands of RX blocks when AMR decode is temporarily
    // slower than the 20 ms packet arrival rate. Oldest frames are discarded
    // so latency stays bounded instead of turning into delayed speech.
    private var rxWorkQueue: [(Data, UInt64)] = []
    private let maxRXWorkFrames = 20         // 400 ms @ 20 ms/frame
    private var rxWorkerScheduled = false

    // R5: K7 may start streaming immediately after VOICE_OPEN while CallKit
    // is still activating the local audio graph. Keep only five 20 ms AMR frames
    // during that startup race; this prevents stale multi-second catch-up.
    private var preStartRXFrames: [(Data, UInt64)] = []
    private let maxPreStartRXFrames = 5      // ~100 ms @ 20 ms/frame

    // R5: a busy main queue must not turn microphone frames into an old backlog.
    // One pending slot always forwards the newest AMR frame.
    private let txDispatchLock = NSLock()
    private var pendingTXFrame: (Data, UInt64)?
    private var txDispatchScheduled = false

    private var acceptsRX = false
    private var sessionGeneration: UInt64 = 0

    // Playback is also bounded. If the phone receives an abnormal burst, we
    // reset the player backlog instead of turning that burst into seconds of
    // delayed speech.
    private var playbackGeneration: UInt64 = 0
    private var scheduledPlaybackFrames = 0
    private let maxScheduledPlaybackFrames = 10 // 200 ms

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

        // R3: changing speaker route must NOT rebuild/deactivate the CallKit
        // audio session while a live call is running. Use the AVAudioSession
        // port override only; the microphone/input side stays owned by the
        // same active PlayAndRecord session.
        guard isRunning else { return }

        do {
            try audioSession.overrideOutputAudioPort(enabled ? .speaker : .none)
            reportStatus("[AUDIO] speaker route = \(enabled ? "SPEAKER" : "DEFAULT")")
            NSLog("[CALLSHARE_AUDIO_R3] overrideOutputAudioPort=\(enabled ? "speaker" : "none") route=\(routeDescription())")
        } catch {
            reportStatus("[AUDIO] speaker route ERROR: \(error.localizedDescription)")
            NSLog("[CALLSHARE_AUDIO_R3] overrideOutputAudioPort ERROR \(error)")
        }
    }

    func setMuted(_ value: Bool) {
        stateLock.lock()
        muted = value
        stateLock.unlock()
        reportStatus(value ? "MUTED" : "UNMUTED")
    }

    /// Start accepting GSM AMR for a fresh call. This is separate from
    /// start()/stop(): CallKit audio can be temporarily inactive while the
    /// GSM call itself is still alive, so queued RX belongs to the call session,
    /// not to the audio-engine running state.
    func beginCallSession() {
        rxQueue.sync { }

        stateLock.lock()
        sessionGeneration &+= 1
        acceptsRX = true
        isRunning = false
        converter = nil
        rxWorkQueue.removeAll(keepingCapacity: true)
        rxWorkerScheduled = false
        preStartRXFrames.removeAll(keepingCapacity: true)
        cancelPendingTX()
        playbackGeneration &+= 1
        scheduledPlaybackFrames = 0
        txFrames = 0
        rxFrames = 0
        droppedRx = 0
        invalidRx = 0
        pcmAccumulator.removeAll(keepingCapacity: true)
        stateLock.unlock()

        playerNode.stop()
        playerNode.reset()
        audioEngine.stop()
        audioEngine.reset()
        codec.reset()
        audioSessionPrepared = false

        reportStatus("CALL SESSION READY")
    }

    /// Permanently invalidate the current call's RX data. Old BLE packets that
    /// arrive after hangup can therefore never leak into the next call.
    func endCallSession() {
        stateLock.lock()
        sessionGeneration &+= 1
        acceptsRX = false
        isRunning = false
        converter = nil
        rxWorkQueue.removeAll(keepingCapacity: true)
        preStartRXFrames.removeAll(keepingCapacity: true)
        cancelPendingTX()
        playbackGeneration &+= 1
        scheduledPlaybackFrames = 0
        pcmAccumulator.removeAll(keepingCapacity: true)
        stateLock.unlock()

        // Wait for an already-running RX decode block to observe the new
        // generation before tearing down the player graph.
        rxQueue.sync { }

        playerNode.stop()
        playerNode.reset()
        audioEngine.stop()
        audioEngine.reset()
        codec.reset()
        audioSessionPrepared = false

        reportStatus("CALL SESSION INVALIDATED / RX QUEUE CLEARED")
    }

    /// Prepare the CallKit-owned audio session before CallKit activates it.
    /// We deliberately do NOT call setActive(true) here.
    func prepareForCallAudio() {
        NSLog("[CALLSHARE_AUDIO_R1] prepareForCallAudio ENTER")
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: sessionOptions()
            )
            try audioSession.setPreferredSampleRate(8_000)
            try audioSession.setPreferredIOBufferDuration(0.01)
            audioSessionPrepared = true

            NSLog("[CALLSHARE_AUDIO_R1] PREPARED category=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue)")
            NSLog("[CALLSHARE_AUDIO_R1] preferred sampleRate=\(audioSession.sampleRate) ioBuffer=\(audioSession.ioBufferDuration)")
        } catch {
            audioSessionPrepared = false
            NSLog("[CALLSHARE_AUDIO_R1] PREPARE ERROR \(error)")
            reportStatus("[AUDIO] session prepare ERROR: \(error.localizedDescription)")
        }
    }

    /// CallKit activates AVAudioSession first. This method then opens the
    /// microphone and starts the playback graph using the same 8 kHz mono
    /// PCM boundary used by AMR-NB.
    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        let runningAndEngineAlive = isRunning && audioEngine.isRunning
        if isRunning && !audioEngine.isRunning {
            isRunning = false
        }
        stateLock.unlock()

        guard !runningAndEngineAlive else { return true }

        NSLog("[J7BRIDGE_DIAG] VoiceEngine.start ENTER")

        do {
            if !audioSessionPrepared {
                // Fallback for development/test paths that start VoiceEngine directly.
                prepareForCallAudio()
            }

            reportStatus("[VOICE] starting; route=\(routeDescription())")
            NSLog("[CALLSHARE_AUDIO_R1] START route=\(routeDescription())")
            NSLog("[CALLSHARE_AUDIO_R1] START sampleRate=\(audioSession.sampleRate) input=\(audioSession.inputNumberOfChannels) output=\(audioSession.outputNumberOfChannels)")

            guard codec.isReady else {
                throw NSError(
                    domain: "J7Bridge.AMR",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "AMR encoder/decoder failed to initialize"]
                )
            }

            // A decoder/encoder state belongs to one GSM call only.
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

            playerNode.stop()
            playerNode.reset()
            stateLock.lock()
            playbackGeneration &+= 1
            scheduledPlaybackFrames = 0
            txFrames = 0
            rxFrames = 0
            droppedRx = 0
            invalidRx = 0
            pcmAccumulator.removeAll(keepingCapacity: true)
            stateLock.unlock()

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

            stateLock.lock()
            isRunning = true
            stateLock.unlock()

            // Mark running before engine start so the first callback cannot be
            // rejected solely because the engine is transitioning to running.
            let engineStartUptime = ProcessInfo.processInfo.systemUptime
            audioEngine.prepare()
            NSLog("[CALLSHARE_AUDIO_R1] engine prepared; engineRunning=\(audioEngine.isRunning)")
            try audioEngine.start()
            let engineStartMs = Int((ProcessInfo.processInfo.systemUptime - engineStartUptime) * 1000.0)
            NSLog("[CALLSHARE_AUDIO_R1] engine.start SUCCESS isRunning=\(audioEngine.isRunning) costMs=\(engineStartMs)")
            playerNode.play()
            NSLog("[CALLSHARE_AUDIO_R1] playerNode.play isPlaying=\(playerNode.isPlaying)")
            flushPreStartRX()
            NSLog("[CALLSHARE_AUDIO_R1] output format=\(audioEngine.outputNode.outputFormat(forBus: 0))")
            NSLog("[CALLSHARE_AUDIO_R1] mixer output format=\(audioEngine.mainMixerNode.outputFormat(forBus: 0))")

            reportStatus(
                String(
                    format: "STARTED / mic %.0f Hz %dch -> AMR-NB 8k / speaker=%@",
                    hardwareFormat.sampleRate,
                    hardwareFormat.channelCount,
                    useSpeaker ? "YES" : "NO"
                )
            )

            return true
        } catch {
            stateLock.lock()
            isRunning = false
            stateLock.unlock()
            inputRemoveTapSafely()
            audioEngine.stop()
            audioEngine.reset()
            playerNode.stop()
            playerNode.reset()
            converter = nil
            reportStatus("ERROR AudioEngine: \(error.localizedDescription)")
            return false
        }
    }

    /// Stop the audio engine without ending the GSM call session. Pending AMR
    /// is retained (bounded) so a short CallKit audio activation gap does not
    /// discard the beginning of the remote speech stream.
    func stop() {
        stateLock.lock()
        let shouldStop = isRunning || audioEngine.isRunning
        isRunning = false
        playbackGeneration &+= 1
        scheduledPlaybackFrames = 0
        converter = nil
        pcmAccumulator.removeAll(keepingCapacity: true)
        stateLock.unlock()

        guard shouldStop else { return }

        inputRemoveTapSafely()
        playerNode.stop()
        playerNode.reset()
        audioEngine.stop()
        audioEngine.reset()
        codec.reset()
        audioSessionPrepared = false
        reportStatus("STOPPED / audio graph reset")
    }

    /// Channel 3 carries one AMR-NB IETF/WFI frame. Incoming BLE callbacks are
    /// immediately handed to a private serial RX queue so decoding/scheduling
    /// never blocks CoreBluetooth's main queue.
    func receiveAMR(_ packet: Data) {
        guard !packet.isEmpty else { return }

        stateLock.lock()
        guard acceptsRX else {
            stateLock.unlock()
            return
        }

        let generation = sessionGeneration

        if !isRunning {
            if preStartRXFrames.count >= maxPreStartRXFrames {
                preStartRXFrames.removeFirst()
                droppedRx += 1
                let dropped = droppedRx
                preStartRXFrames.append((packet, generation))
                stateLock.unlock()
                if dropped == 1 || dropped % 25 == 0 {
                    reportStatus("[AMR] PRESTART RX buffer full; dropped oldest frame")
                }
            } else {
                preStartRXFrames.append((packet, generation))
                let count = preStartRXFrames.count
                stateLock.unlock()
                if count == 1 {
                    reportStatus("[AMR] PRESTART buffered len=\(packet.count)")
                }
            }
            return
        }

        if rxWorkQueue.count >= maxRXWorkFrames {
            rxWorkQueue.removeFirst()
            droppedRx += 1
            let dropped = droppedRx
            if dropped == 1 || dropped % 25 == 0 {
                stateLock.unlock()
                reportStatus("[AMR] RX work queue overflow; dropped oldest frame")
            } else {
                stateLock.unlock()
            }
        } else {
            stateLock.unlock()
        }

        stateLock.lock()
        rxWorkQueue.append((packet, generation))
        let shouldStartWorker = !rxWorkerScheduled
        if shouldStartWorker { rxWorkerScheduled = true }
        stateLock.unlock()

        if shouldStartWorker {
            rxQueue.async { [weak self] in
                self?.drainRXWorkQueue()
            }
        }
    }

    private func flushPreStartRX() {
        stateLock.lock()
        guard !preStartRXFrames.isEmpty else {
            stateLock.unlock()
            return
        }

        let buffered = preStartRXFrames
        preStartRXFrames.removeAll(keepingCapacity: true)
        rxWorkQueue.insert(contentsOf: buffered, at: 0)
        let shouldStartWorker = !rxWorkerScheduled
        if shouldStartWorker { rxWorkerScheduled = true }
        let count = buffered.count
        stateLock.unlock()

        reportStatus("[AMR] PRESTART flush frames=\(count)")
        if shouldStartWorker {
            rxQueue.async { [weak self] in
                self?.drainRXWorkQueue()
            }
        }
    }

    private func drainRXWorkQueue() {
        while true {
            stateLock.lock()
            guard !rxWorkQueue.isEmpty else {
                rxWorkerScheduled = false
                stateLock.unlock()
                return
            }
            let item = rxWorkQueue.removeFirst()
            stateLock.unlock()

            consumeAMR(item.0, generation: item.1)
        }
    }

    private func consumeAMR(_ packet: Data, generation: UInt64) {
        stateLock.lock()
        guard acceptsRX, sessionGeneration == generation else {
            stateLock.unlock()
            return
        }

        stateLock.unlock()

        guard let frameInfo = codec.validateAndLearnMode(packet) else {
            stateLock.lock()
            invalidRx += 1
            let count = invalidRx
            stateLock.unlock()
            if count == 1 || count % 25 == 0 {
                reportStatus("[AMR] RX INVALID frame #\(count) len=\(packet.count)")
            }
            return
        }

        guard let pcm = codec.decode(packet) else {
            reportStatus("[AMR] RX DECODE FAILED len=\(packet.count) ft=\(frameInfo.frameType)")
            return
        }

        stateLock.lock()
        rxFrames += 1
        let frameNumber = rxFrames
        stateLock.unlock()

        if frameNumber == 1 || frameNumber % 25 == 0 {
            reportStatus(
                "[AMR] RX frame #\(frameNumber) len=\(packet.count) ft=\(frameInfo.frameType) mode=\(frameInfo.encoderMode) -> PCM160"
            )
        }

        schedulePlayback(pcm, generation: generation)
    }

    private func sessionOptions() -> AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.allowBluetooth]
        if useSpeaker {
            options.insert(.defaultToSpeaker)
        }
        return options
    }

    private func applySessionCategory() {
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: sessionOptions()
            )
            audioSessionPrepared = true
        } catch {
            NSLog("[CALLSHARE_AUDIO_R1] setCategory ERROR \(error)")
        }
    }

    private func inputRemoveTapSafely() {
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func processPCM(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let running = isRunning
        let activeConverter = converter
        stateLock.unlock()

        guard running, let activeConverter else { return }

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

        activeConverter.convert(to: output, error: &error) { _, status in
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

        var framesToEncode: [[Int16]] = []

        stateLock.lock()
        pcmAccumulator.append(
            contentsOf: UnsafeBufferPointer(
                start: pointer,
                count: Int(buffer.frameLength)
            )
        )

        while pcmAccumulator.count >= 160 {
            framesToEncode.append(Array(pcmAccumulator.prefix(160)))
            pcmAccumulator.removeFirst(160)
        }
        stateLock.unlock()

        for frame in framesToEncode {
            stateLock.lock()
            let currentlyMuted = muted
            let generation = sessionGeneration
            let accepting = acceptsRX
            stateLock.unlock()
            guard accepting else { continue }
            guard !currentlyMuted else { continue }

            guard let amr = codec.encode160(frame) else {
                reportStatus("[AMR] TX ENCODE FAILED mode=\(codec.encoderMode)")
                continue
            }

            stateLock.lock()
            txFrames += 1
            let frameNumber = txFrames
            stateLock.unlock()

            if frameNumber == 1 || frameNumber % 25 == 0 {
                reportStatus("[AMR] TX frame #\(frameNumber) len=\(amr.count) mode=\(codec.encoderMode)")
            }

            // CoreBluetooth work never runs directly on the audio callback.
            // Coalesce the main-queue handoff so startup/UI work cannot create
            // a backlog of old microphone frames.
            enqueueTXFrame(amr, generation: generation)
        }
    }

    private func enqueueTXFrame(_ amr: Data, generation: UInt64) {
        txDispatchLock.lock()
        pendingTXFrame = (amr, generation)
        let shouldSchedule = !txDispatchScheduled
        if shouldSchedule { txDispatchScheduled = true }
        txDispatchLock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.drainTXFrameOnMain()
        }
    }

    private func drainTXFrameOnMain() {
        txDispatchLock.lock()
        guard let pending = pendingTXFrame else {
            txDispatchScheduled = false
            txDispatchLock.unlock()
            return
        }
        pendingTXFrame = nil
        txDispatchScheduled = false
        txDispatchLock.unlock()

        let (amr, generation) = pending
        stateLock.lock()
        let stillCurrent = acceptsRX && sessionGeneration == generation
        stateLock.unlock()
        guard stillCurrent else { return }

        onAMRPacket?(amr)

        txDispatchLock.lock()
        let morePending = pendingTXFrame != nil && !txDispatchScheduled
        if morePending { txDispatchScheduled = true }
        txDispatchLock.unlock()

        if morePending {
            DispatchQueue.main.async { [weak self] in
                self?.drainTXFrameOnMain()
            }
        }
    }

    private func cancelPendingTX() {
        txDispatchLock.lock()
        pendingTXFrame = nil
        txDispatchScheduled = false
        txDispatchLock.unlock()
    }

    private func schedulePlayback(_ pcm: [Int16], generation: UInt64) {
        guard pcm.count == 160 else { return }

        var resetBacklog = false
        var playbackToken: UInt64 = 0

        stateLock.lock()
        guard acceptsRX, sessionGeneration == generation, isRunning, audioEngine.isRunning else {
            stateLock.unlock()
            return
        }

        if scheduledPlaybackFrames >= maxScheduledPlaybackFrames {
            // Drop the old scheduled tail and keep only the newest live frame.
            playbackGeneration &+= 1
            scheduledPlaybackFrames = 0
            resetBacklog = true
        }

        playbackToken = playbackGeneration
        scheduledPlaybackFrames += 1
        stateLock.unlock()

        if resetBacklog {
            playerNode.stop()
            playerNode.reset()
            playerNode.play()
            reportStatus("[AUDIO] playback backlog reset to preserve low latency")
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: pcm8kFormat,
            frameCapacity: 160
        ) else {
            stateLock.lock()
            if playbackToken == playbackGeneration, scheduledPlaybackFrames > 0 {
                scheduledPlaybackFrames -= 1
            }
            stateLock.unlock()
            reportStatus("[AUDIO] could not allocate playback buffer")
            return
        }

        buffer.frameLength = 160

        guard let channel = buffer.int16ChannelData?[0] else {
            stateLock.lock()
            if playbackToken == playbackGeneration, scheduledPlaybackFrames > 0 {
                scheduledPlaybackFrames -= 1
            }
            stateLock.unlock()
            reportStatus("[AUDIO] playback buffer has no Int16 channel")
            return
        }

        pcm.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.assign(from: base, count: pcm.count)
        }

        playerNode.scheduleBuffer(buffer) { [weak self] in
            self?.playbackBufferConsumed(generation: playbackToken)
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func playbackBufferConsumed(generation: UInt64) {
        stateLock.lock()
        if generation == playbackGeneration, scheduledPlaybackFrames > 0 {
            scheduledPlaybackFrames -= 1
        }
        stateLock.unlock()
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
