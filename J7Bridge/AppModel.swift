import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var bleStatus = "Disconnected"
    @Published var deviceName = "-"
    @Published var callStatus = "IDLE"
    @Published var number = ""
    @Published var callerName = ""
    @Published var voiceStatus = "CLOSED"
    @Published var dialString = ""
    @Published var logs: [String] = []
    @Published var battery = "-"
    @Published var firmware = "-"
    @Published var imei = "-"
    @Published var isMuted = false
    @Published private(set) var callStartedAt: Date?

    @Published var autoConnect: Bool {
        didSet {
            UserDefaults.standard.set(autoConnect, forKey: "j7bridge.autoConnect")
            ble.autoReconnect = autoConnect
        }
    }
    @Published var resolveCallerNames: Bool {
        didSet { UserDefaults.standard.set(resolveCallerNames, forKey: "j7bridge.resolveCallerNames") }
    }
    @Published var missedCallNotifications: Bool {
        didSet { UserDefaults.standard.set(missedCallNotifications, forKey: "j7bridge.missedCallNotifications") }
    }
    @Published var speakerDefault: Bool {
        didSet {
            UserDefaults.standard.set(speakerDefault, forKey: "j7bridge.speakerDefault")
            voice.setSpeakerDefault(speakerDefault)
        }
    }
    @Published var simSlot: Int {
        didSet { UserDefaults.standard.set(simSlot, forKey: "j7bridge.simSlot") }
    }

    let ble: BLEManager
    let callKit: CallKitManager
    let voice: VoiceEngine
    let contacts: ContactsManager
    let history: CallHistoryStore
    let notifications = NotificationManager()

    private var currentDirection: CallDirection?
    private var currentContactName: String?
    private var callAudioActive = false
    private var remoteVoiceOpen = false

    /// Monotonically increasing CallShare session token. Every new call gets a
    /// new token; asynchronous CallKit completions capture their token so an
    /// old completion can never tear down a newer call.
    private var callSessionID: UInt64 = 0
    private var historyWrittenForSession: UInt64?

    init() {
        autoConnect = UserDefaults.standard.object(forKey: "j7bridge.autoConnect") as? Bool ?? true
        resolveCallerNames = UserDefaults.standard.object(forKey: "j7bridge.resolveCallerNames") as? Bool ?? true
        missedCallNotifications = UserDefaults.standard.object(forKey: "j7bridge.missedCallNotifications") as? Bool ?? true
        speakerDefault = UserDefaults.standard.object(forKey: "j7bridge.speakerDefault") as? Bool ?? true
        simSlot = UserDefaults.standard.object(forKey: "j7bridge.simSlot") as? Int ?? 0

        ble = BLEManager()
        callKit = CallKitManager()
        voice = VoiceEngine()
        contacts = ContactsManager()
        history = CallHistoryStore()

        ble.autoReconnect = autoConnect
        voice.setSpeakerDefault(speakerDefault)

        ble.onLog = { [weak self] line in self?.log(line) }
        ble.onStatus = { [weak self] status in self?.bleStatus = status }
        ble.onDevice = { [weak self] name in self?.deviceName = name ?? "IKOS K7" }
        ble.onControlPayload = { [weak self] payload in self?.handleControl(payload) }
        ble.onAudioPayload = { [weak self] payload in self?.voice.receiveAMR(payload) }

        callKit.onLog = { [weak self] line in self?.log(line) }
        callKit.onReset = { [weak self] in
            self?.abortCallSession(reason: "CallKit provider reset", sendHangup: true)
        }

        callKit.onStart = { [weak self] number in
            self?.beginOutgoing(number)
        }
        callKit.onAnswer = { [weak self] in
            guard let self else { return }
            guard self.callStatus != "IDLE" else {
                self.log("[CALLKIT] ANSWER ignored; no active CallShare session")
                return
            }

            if self.callStatus == "RINGING" || self.callStatus == "DIALING" {
                self.ble.sendAnswer()
                self.log("[CALLKIT] ANSWER -> K7 05")
            } else {
                // K7 may already have acknowledged the answer before this
                // CallKit callback reaches the app. Do not send a second 05.
                self.log("[CALLKIT] ANSWER already confirmed state=\(self.callStatus)")
            }
        }
        callKit.onEnd = { [weak self] in
            self?.endFromCallKit()
        }
        callKit.onMute = { [weak self] muted in
            self?.isMuted = muted
            self?.voice.setMuted(muted)
        }
        callKit.onDTMF = { [weak self] digits in
            self?.sendDTMFString(digits)
        }
        callKit.onPrepareAudio = { [weak self] in
            self?.voice.prepareForCallAudio()
        }
        callKit.onAudioActivated = { [weak self] in
            guard let self else { return }
            guard self.callStatus != "IDLE" else {
                self.log("[CALLKIT] audio ACT ignored state=IDLE")
                return
            }

            // Do not require ACTIVE here. CallKit can activate the shared
            // audio session a little before the K7 0x05 answer event reaches
            // us. Latch the activation; evtAnswer/ACTIVE will call
            // maybeStartVoice() again and consume the latch.
            self.callAudioActive = true
            self.log("[CALLKIT] audio ACT latched state=\(self.callStatus)")
            self.maybeStartVoice()
        }
        callKit.onAudioDeactivated = { [weak self] in
            guard let self else { return }
            guard self.callStatus != "IDLE" else {
                self.log("[CALLKIT] audio DEACT ignored state=IDLE")
                return
            }

            // A transient deactivation is allowed during an active CallKit
            // UUID. Stop the audio engine but keep the GSM call session and
            // its generation alive so the next didActivate can restart it.
            self.callAudioActive = false
            if self.callStatus == "ACTIVE" {
                self.voice.stop()
            } else {
                self.log("[CALLKIT] audio DEACT latched false state=\(self.callStatus)")
            }
        }

        voice.onAMRPacket = { [weak self] packet in
            self?.ble.sendAudio(packet)
        }
        voice.onStatus = { [weak self] status in
            self?.voiceStatus = status
            self?.log("[VOICE] \(status)")
        }
    }

    func start() {
        ble.startScan()
        if contacts.authorization == .authorized { contacts.load() }
    }

    func answerTest() {
        // Development helper deliberately kept out of the final UI.
        ble.sendAnswer()
    }

    func makeCall() {
        let cleaned = dialString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        // Do not create a second CallShare session here. CallKit's
        // CXStartCallAction callback is the single owner of outgoing session
        // creation; this removes a real double-initialization race.
        callKit.startOutgoing(number: cleaned) { [weak self] accepted in
            guard let self else { return }
            if !accepted {
                self.log("[CALLKIT] outgoing transaction failed; session not started")
            } else {
                self.log("[CALLKIT] outgoing transaction accepted")
            }
        }
    }

    func endCall() { callKit.endCurrentCall() }

    func tapDialpad(_ digit: String) {
        if callStatus == "ACTIVE" {
            sendDTMFString(digit)
        } else {
            dialString.append(digit)
        }
    }

    func backspaceDialpad() {
        guard callStatus != "ACTIVE", !dialString.isEmpty else { return }
        dialString.removeLast()
    }

    func requestContacts() {
        contacts.requestAccessAndLoad()
    }

    func clearHistory() { history.clear() }

    func requestDeviceInfo() {
        ble.requestDeviceCheck()
        ble.requestBattery()
        ble.requestFirmware()
        ble.requestIMEI()
    }

    func sendDTMFString(_ digits: String) {
        for character in digits {
            switch character {
            case "0"..."9", "*", "#":
                ble.sendDTMF(UInt8(String(character).utf8.first!))
            default:
                break
            }
        }
    }

    func handleControl(_ payload: Data) {
        guard let op = payload.first else { return }

        switch op {
        case K7Protocol.evtReceiveCall:
            handleIncoming(payload)

        case K7Protocol.evtAnswer:
            guard callStatus == "RINGING" || callStatus == "DIALING" else {
                log("[CALL] stale ANSWER EVENT ignored state=\(callStatus)")
                return
            }

            callStatus = "ACTIVE"
            log("[CALL] ANSWER EVENT / ACTIVE")
            callKit.fulfillAnswerIfNeeded()
            beginCallIfNeeded(direction: currentDirection ?? .incoming)
            remoteVoiceOpen = false
            ble.sendVoiceOpen()
            maybeStartVoice()

        case K7Protocol.evtReceiveCallEnd:
            guard callStatus != "IDLE" else {
                log("[CALL] stale END EVENT ignored state=IDLE")
                return
            }
            handleRemoteEnd()

        case K7Protocol.evtVoiceOpen:
            guard callStatus == "ACTIVE" else {
                log("[VOICE] stale OPEN ignored state=\(callStatus)")
                return
            }
            remoteVoiceOpen = true
            log("[VOICE] OPEN EVENT")
            maybeStartVoice()

        case K7Protocol.evtVoiceClose:
            // Ignore a close that belongs to an already-closed voice session.
            guard remoteVoiceOpen else {
                log("[VOICE] stale CLOSE ignored")
                return
            }
            remoteVoiceOpen = false
            log("[VOICE] CLOSE EVENT")
            voice.stop()

        case K7Protocol.evtMakeCall:
            guard callStatus == "DIALING" || callStatus == "ACTIVE" else {
                log("[CALL] stale MAKE_CALL EVENT ignored state=\(callStatus)")
                return
            }
            log("[CALL] MAKE_CALL EVENT \(K7Protocol.hex(payload))")
            callKit.reportOutgoingConnecting()

        case K7Protocol.evtReadBattery:
            if payload.count >= 5 { battery = String(payload[4]) }
            log("[K7] BATTERY \(battery)")

        case K7Protocol.evtFirmwareVersion:
            firmware = K7Protocol.decodeASCIIBlock(payload, offset: 1)
            log("[K7] FIRMWARE \(firmware)")

        case K7Protocol.evtIMEIInfo:
            imei = K7Protocol.decodeASCIIBlock(payload, offset: 3)
            log("[K7] IMEI \(imei)")

        default:
            log("[RX] CONTROL \(String(format: "%02X", op)) \(K7Protocol.hex(payload))")
        }
    }

    private func handleIncoming(_ payload: Data) {
        guard callStatus == "IDLE" else {
            log("[CALL] duplicate/stale incoming ignored state=\(callStatus)")
            return
        }

        // Clean anything left by a previous CallKit transaction without ever
        // touching the live GATT connection.
        ble.clearPendingAudio()
        callKit.prepareForNewCall()
        voice.beginCallSession()

        callSessionID &+= 1
        historyWrittenForSession = nil
        let sessionID = callSessionID

        let incomingNumber = K7Protocol.decodeIncomingNumber(payload)
        let name = resolveCallerNames ? contacts.resolveName(for: incomingNumber) : nil
        number = incomingNumber
        callerName = name ?? ""
        currentContactName = name
        currentDirection = .incoming
        callStartedAt = Date()
        callAudioActive = false
        remoteVoiceOpen = false
        isMuted = false
        callStatus = "RINGING"
        log("[CALL] SESSION BEGIN #\(sessionID) INCOMING \(name.map { "\($0) / " } ?? "")\(incomingNumber)")

        callKit.reportIncoming(number: incomingNumber, callerName: name) { [weak self] accepted in
            guard let self else { return }
            guard self.callSessionID == sessionID else {
                self.log("[CALLKIT] stale incoming completion ignored session=\(sessionID)")
                return
            }

            if accepted {
                self.log("[CALLKIT] incoming completion OK session=\(sessionID)")
            } else {
                // A CallKit report failure must not leave AppModel stuck in
                // RINGING. That stale RINGING state was enough to make the
                // next real GSM incoming event look like a duplicate and get
                // discarded. Tear down the whole session immediately.
                self.log("[CALLKIT] incoming completion FAILED -> RESET session=\(sessionID)")
                self.abortCallSession(reason: "CallKit incoming report failed", sendHangup: true)
            }
        }
    }

    private func beginOutgoing(_ outgoingNumber: String) {
        // CallKit Start action is the single point where an outgoing session
        // is created. A stale prior session is cleared here without touching
        // the GATT transport.
        if callStatus != "IDLE" {
            abortCallSession(reason: "replacing stale outgoing state", sendHangup: true)
        }

        ble.clearPendingAudio()
        callKit.prepareForNewCall()
        voice.beginCallSession()

        callSessionID &+= 1
        historyWrittenForSession = nil
        let sessionID = callSessionID

        number = outgoingNumber
        callerName = contacts.resolveName(for: outgoingNumber) ?? ""
        currentContactName = callerName.isEmpty ? nil : callerName
        dialString = ""
        currentDirection = .outgoing
        callStartedAt = Date()
        callAudioActive = false
        remoteVoiceOpen = false
        isMuted = false
        callStatus = "DIALING"

        log("[CALL] SESSION BEGIN #\(sessionID) OUTGOING \(outgoingNumber)")
        ble.sendMakeCall(number: outgoingNumber, simId: UInt8(simSlot))
    }

    private func beginCall(number: String, direction: CallDirection, name: String?) {
        // Retained for source compatibility with older project revisions.
        // New outgoing calls are initialized through beginOutgoing().
        self.number = number
        currentDirection = direction
        currentContactName = name
        callStartedAt = Date()
        callAudioActive = false
        remoteVoiceOpen = false
        if direction == .outgoing { callStatus = "DIALING" }
    }

    private func beginCallIfNeeded(direction: CallDirection) {
        if callStartedAt == nil { callStartedAt = Date() }
        currentDirection = direction
        if direction == .incoming && callerName.isEmpty {
            callerName = currentContactName ?? ""
        }
    }

    private func maybeStartVoice() {
        guard callStatus == "ACTIVE" else {
            log("[VOICE] WAIT call not ACTIVE state=\(callStatus)")
            return
        }

        guard remoteVoiceOpen else {
            log("[VOICE] WAIT remote VOICE_OPEN")
            return
        }

        guard callAudioActive else {
            log("[VOICE] WAIT CallKit audio activation")
            return
        }

        log("[VOICE] START gate satisfied -> VoiceEngine.start()")
        voice.start()
    }

    private func endFromCallKit() {
        finishCall(sendHangup: true, remoteEnd: false, reason: "CallKit END")
    }

    private func handleRemoteEnd() {
        let wasRinging = callStatus == "RINGING"
        let direction = wasRinging ? CallDirection.missed : (currentDirection ?? .incoming)
        finishCall(
            sendHangup: false,
            remoteEnd: true,
            reason: "K7 END EVENT",
            historyDirectionOverride: direction
        )
    }

    /// Single idempotent call teardown path. Both CallKit and K7 remote-end
    /// events can converge here; only the first active session writes history.
    private func finishCall(
        sendHangup: Bool,
        remoteEnd: Bool,
        reason: String,
        historyDirectionOverride: CallDirection? = nil
    ) {
        guard callStatus != "IDLE" || callStartedAt != nil || currentDirection != nil else {
            log("[CALL] teardown ignored; already IDLE")
            return
        }

        let direction = historyDirectionOverride ?? currentDirection ?? .outgoing
        let wasRinging = callStatus == "RINGING"

        if sendHangup {
            ble.sendHangup()
        }

        // Always terminate voice transport and clear pending TX frames. This
        // prevents uplink AMR from one call being delivered into the next.
        ble.sendVoiceClose()
        remoteVoiceOpen = false
        callAudioActive = false
        voice.stop()
        voice.endCallSession()
        isMuted = false

        writeHistoryOnce(direction: wasRinging ? .missed : direction)

        callStartedAt = nil
        currentDirection = nil
        currentContactName = nil
        number = ""
        callerName = ""
        dialString = ""
        callStatus = "IDLE"

        if remoteEnd {
            callKit.reportRemoteEnd()
        } else {
            callKit.clearCurrentCall()
        }

        log("[CALL] SESSION END / RESET reason=\(reason) -> IDLE")
    }

    private func abortCallSession(reason: String, sendHangup: Bool) {
        guard callStatus != "IDLE" || callStartedAt != nil || currentDirection != nil else {
            callKit.prepareForNewCall()
            voice.endCallSession()
            ble.clearPendingAudio()
            return
        }

        if sendHangup { ble.sendHangup() }
        ble.sendVoiceClose()
        remoteVoiceOpen = false
        callAudioActive = false
        voice.stop()
        voice.endCallSession()
        isMuted = false
        callStartedAt = nil
        currentDirection = nil
        currentContactName = nil
        number = ""
        callerName = ""
        dialString = ""
        callStatus = "IDLE"
        historyWrittenForSession = nil
        callKit.clearCurrentCall()
        ble.clearPendingAudio()
        log("[CALL] ABORT / RESET reason=\(reason) -> IDLE")
    }

    private func writeHistoryOnce(direction: CallDirection) {
        guard historyWrittenForSession != callSessionID else { return }
        historyWrittenForSession = callSessionID

        let duration = callStartedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        guard !number.isEmpty else { return }

        history.add(
            number: number,
            name: currentContactName,
            direction: direction,
            duration: duration
        )

        if direction == .missed, missedCallNotifications {
            notifications.sendMissedCall(number: number, name: currentContactName)
        }
    }

    func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logs.append("[\(stamp)] \(line)")
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }
}
