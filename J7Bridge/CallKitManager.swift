import Foundation
import CallKit
import AVFoundation

final class CallKitManager: NSObject {
    private let provider: CXProvider
    private var currentUUID: UUID?
    private var answerAction: CXAnswerCallAction?
    private var answerConfirmed = false

    var onStart: ((String) -> Void)?
    var onAnswer: (() -> Void)?
    var onEnd: (() -> Void)?
    var onMute: ((Bool) -> Void)?
    var onDTMF: ((String) -> Void)?
    var onAudioActivated: (() -> Void)?
    var onAudioDeactivated: (() -> Void)?
    var onReset: (() -> Void)?
    var onPrepareAudio: (() -> Void)?
    var onLog: ((String) -> Void)?

    override init() {
        let configuration = CXProviderConfiguration(localizedName: "J7Bridge")
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    /// Clear only CallKit-side bookkeeping before a brand-new CallShare
    /// session. The live GATT connection is intentionally untouched.
    func prepareForNewCall() {
        answerAction = nil
        answerConfirmed = false
        currentUUID = nil
        onLog?("[CALLKIT] prepared for new call")
    }

    func reportIncoming(number: String, callerName: String?, completion: ((Bool) -> Void)? = nil) {
        guard currentUUID == nil else {
            onLog?("[CALLKIT] incoming blocked by stale UUID=\(currentUUID!.uuidString)")
            DispatchQueue.main.async { completion?(false) }
            return
        }

        let uuid = UUID()
        currentUUID = uuid

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        update.localizedCallerName = callerName
        update.hasVideo = false
        update.supportsDTMF = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error {
                    let nsError = error as NSError
                    self.onLog?("[CALLKIT] INCOMING FAILED uuid=\(uuid.uuidString) domain=\(nsError.domain) code=\(nsError.code)")
                    self.onLog?("[CALLKIT] INCOMING FAILED description=\(nsError.localizedDescription)")

                    // Never clear a newer call's UUID because an older CallKit
                    // completion arrived late.
                    if self.currentUUID == uuid {
                        self.currentUUID = nil
                        self.answerAction = nil
                    }
                    completion?(false)
                } else {
                    self.onLog?("[CALLKIT] INCOMING UI REPORTED UUID=\(uuid.uuidString)")
                    completion?(true)
                }
            }
        }
    }

    func startOutgoing(number: String, completion: ((Bool) -> Void)? = nil) {
        guard currentUUID == nil else {
            onLog?("[CALLKIT] outgoing blocked by stale UUID=\(currentUUID!.uuidString)")
            DispatchQueue.main.async { completion?(false) }
            return
        }

        let uuid = UUID()
        currentUUID = uuid
        let handle = CXHandle(type: .phoneNumber, value: number)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = false
        let transaction = CXTransaction(action: action)
        CXCallController().request(transaction) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.onLog?("[CALLKIT] start outgoing failed: \(error.localizedDescription)")
                    if self.currentUUID == uuid {
                        self.currentUUID = nil
                        self.answerAction = nil
                    }
                    completion?(false)
                } else {
                    self.onLog?("[CALLKIT] OUTGOING transaction accepted UUID=\(uuid.uuidString)")
                    completion?(true)
                }
            }
        }
    }

    func endCurrentCall() {
        guard let uuid = currentUUID else {
            onLog?("[CALLKIT] endCurrentCall ignored; no UUID")
            return
        }
        let transaction = CXTransaction(action: CXEndCallAction(call: uuid))
        CXCallController().request(transaction) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.onLog?("[CALLKIT] local end failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func fulfillAnswerIfNeeded() {
        if let action = answerAction {
            action.fulfill()
            answerAction = nil
            answerConfirmed = false
        } else {
            // K7's 0x05 acknowledgement can theoretically race ahead of the
            // CXAnswerCallAction callback. Remember it so the later CallKit
            // action is fulfilled immediately instead of hanging.
            answerConfirmed = true
            onLog?("[CALLKIT] answer confirmed before action; latched")
        }
    }

    func reportOutgoingConnecting() {
        guard let uuid = currentUUID else {
            onLog?("[CALLKIT] reportOutgoingConnecting ignored; no UUID")
            return
        }
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
    }

    func reportOutgoingConnected() {
        guard let uuid = currentUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    func reportRemoteEnd(reason: CXCallEndedReason = .remoteEnded) {
        guard let uuid = currentUUID else {
            answerAction = nil
            onLog?("[CALLKIT] reportRemoteEnd ignored; no current UUID")
            return
        }

        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        currentUUID = nil
        answerAction = nil
        answerConfirmed = false
    }

    func clearCurrentCall() {
        currentUUID = nil
        answerAction = nil
        answerConfirmed = false
        onLog?("[CALLKIT] current call cleared")
    }
}

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        currentUUID = nil
        answerAction = nil
        answerConfirmed = false
        onLog?("[CALLKIT] provider reset")
        // CallKit has lost system-side state. Invalidate the matching CallShare
        // session too, otherwise a future GSM ring can be blocked by stale
        // AppModel state.
        onReset?()
        onAudioDeactivated?()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        if let currentUUID, currentUUID != action.callUUID {
            onLog?("[CALLKIT] stale START action ignored uuid=\(action.callUUID.uuidString)")
            action.fail()
            return
        }
        currentUUID = action.callUUID
        onPrepareAudio?()
        onLog?("[CALLSHARE_AUDIO_R1] PREPARE before CallKit activation (outgoing)")
        reportOutgoingConnecting()
        onLog?("[CALLKIT] START action -> BLE MAKE CALL")
        onStart?(action.handle.value)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard currentUUID == action.callUUID else {
            onLog?("[CALLKIT] stale ANSWER action ignored uuid=\(action.callUUID.uuidString)")
            action.fail()
            return
        }

        answerAction = action
        if answerConfirmed {
            answerAction = nil
            answerConfirmed = false
            action.fulfill()
            onLog?("[CALLKIT] ANSWER action fulfilled from latched K7 05")
            return
        }

        onPrepareAudio?()
        onLog?("[CALLSHARE_AUDIO_R1] PREPARE before CallKit activation (answer)")
        onLog?("[CALLKIT] ANSWER action -> BLE 05; waiting for K7 05")
        onAnswer?()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard currentUUID == action.callUUID else {
            onLog?("[CALLKIT] stale END action ignored uuid=\(action.callUUID.uuidString)")
            action.fulfill()
            return
        }

        onLog?("[CALLKIT] END action -> AppModel cleanup")
        onEnd?()
        action.fulfill()
        currentUUID = nil
        answerAction = nil
        answerConfirmed = false
        // AppModel.finishCall() is authoritative for VoiceEngine teardown.
        // Avoid the previous duplicate onAudioDeactivated() call here.
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fail()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        onMute?(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        onDTMF?(action.digits)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        onLog?("[CALLSHARE_AUDIO_R1] didActivate CALLED")
        onLog?("[CALLSHARE_AUDIO_R1] session category=\(audioSession.category.rawValue)")
        onLog?("[CALLSHARE_AUDIO_R1] session mode=\(audioSession.mode.rawValue)")
        onLog?("[CALLSHARE_AUDIO_R1] sampleRate=\(audioSession.sampleRate)")
        onLog?("[CALLSHARE_AUDIO_R1] inputChannels=\(audioSession.inputNumberOfChannels)")
        onLog?("[CALLSHARE_AUDIO_R1] outputChannels=\(audioSession.outputNumberOfChannels)")
        onLog?("[CALLSHARE_AUDIO_R1] ioBuffer=\(audioSession.ioBufferDuration)")
        let route = audioSession.currentRoute
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        onLog?("[CALLSHARE_AUDIO_R1] route IN[\(inputs)] OUT[\(outputs)]")
        onLog?("[CALLKIT] audio session ACT")
        onAudioActivated?()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        onLog?("[CALLSHARE_AUDIO_R1] didDeactivate CALLED")
        onLog?("[CALLKIT] audio session DEACT")

        // CallKit may deactivate/re-activate the audio session around route or
        // interruption changes while the call UUID is still alive. Do not tear
        // down VoiceEngine on that transient deactivation; wait for the next
        // didActivate. A real call end clears currentUUID first.
        if currentUUID == nil {
            onAudioDeactivated?()
        } else {
            onLog?("[CALLKIT] transient DEACT ignored; call UUID still alive")
        }
    }
}
