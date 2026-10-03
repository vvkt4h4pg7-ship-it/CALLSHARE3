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

        callKit.onLog = { [weak self] line in
            self?.log(line)
        }

        callKit.onStart = { [weak self] number in self?.beginOutgoing(number) }
        callKit.onAnswer = { [weak self] in
            guard let self else { return }
            self.ble.sendAnswer()
            self.log("[CALLKIT] ANSWER -> K7 05")
        }
        callKit.onEnd = { [weak self] in self?.endFromCallKit() }
        callKit.onMute = { [weak self] muted in
            self?.isMuted = muted
            self?.voice.setMuted(muted)
        }
        callKit.onDTMF = { [weak self] digits in
            self?.sendDTMFString(digits)
        }
        callKit.onAudioActivated = { [weak self] in
            self?.callAudioActive = true
            self?.maybeStartVoice()
        }
        callKit.onAudioDeactivated = { [weak self] in
            self?.callAudioActive = false
            self?.voice.stop()
        }

        voice.onAMRPacket = { [weak self] packet in self?.ble.sendAudio(packet) }
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
        beginCall(number: cleaned, direction: .outgoing, name: contacts.resolveName(for: cleaned))
        callKit.startOutgoing(number: cleaned)
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
                // The supplied K7 source exposes the DTMF opcode and a second
                // parameter byte, but does not document the value mapping.
                // ASCII is used here as the least-assumptive terminal encoding.
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
            callStatus = "ACTIVE"
            log("[CALL] ANSWER EVENT / ACTIVE")
            callKit.fulfillAnswerIfNeeded()
            beginCallIfNeeded(direction: currentDirection ?? .incoming)
            remoteVoiceOpen = false
            ble.sendVoiceOpen()

        case K7Protocol.evtReceiveCallEnd:
            handleRemoteEnd()

        case K7Protocol.evtVoiceOpen:
            remoteVoiceOpen = true
            log("[VOICE] OPEN EVENT")
            maybeStartVoice()

        case K7Protocol.evtVoiceClose:
            remoteVoiceOpen = false
            log("[VOICE] CLOSE EVENT")
            voice.stop()

        case K7Protocol.evtMakeCall:
            callStatus = "DIALING"
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
        guard callStatus == "IDLE" || callStatus == "ENDED" else {
            log("[CALL] duplicate incoming ignored")
            return
        }
        let incomingNumber = K7Protocol.decodeIncomingNumber(payload)
        let name = resolveCallerNames ? contacts.resolveName(for: incomingNumber) : nil
        number = incomingNumber
        callerName = name ?? ""
        currentContactName = name
        currentDirection = .incoming
        callStartedAt = Date()
        callAudioActive = false
        remoteVoiceOpen = false
        callStatus = "RINGING"
        log("[CALL] INCOMING \(name.map { "\($0) / " } ?? "")\(incomingNumber)")
        callKit.reportIncoming(number: incomingNumber, callerName: name)
    }

    private func beginOutgoing(_ outgoingNumber: String) {
        number = outgoingNumber
        callerName = contacts.resolveName(for: outgoingNumber) ?? ""
        currentContactName = callerName.isEmpty ? nil : callerName
        dialString = ""
        beginCall(number: outgoingNumber, direction: .outgoing, name: currentContactName)
        ble.sendMakeCall(number: outgoingNumber, simId: UInt8(simSlot))
        callStatus = "DIALING"
    }

    private func beginCall(number: String, direction: CallDirection, name: String?) {
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
        if direction == .incoming && callerName.isEmpty { callerName = currentContactName ?? "" }
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
        ble.sendHangup()
        remoteVoiceOpen = false
        voice.stop()
        finishHistory(direction: currentDirection ?? .outgoing)
        callStatus = "ENDED"
        callKit.clearCurrentCall()
    }

    private func handleRemoteEnd() {
        let wasRinging = callStatus == "RINGING"
        let direction = currentDirection ?? .incoming
        remoteVoiceOpen = false
        voice.stop()
        finishHistory(direction: wasRinging ? .missed : direction)
        callStatus = "ENDED"
        log("[CALL] END EVENT")
        callKit.reportRemoteEnd()
    }

    private func finishHistory(direction: CallDirection) {
        let duration = callStartedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        if !number.isEmpty {
            history.add(number: number, name: currentContactName, direction: direction, duration: duration)
            if direction == .missed, missedCallNotifications {
                notifications.sendMissedCall(number: number, name: currentContactName)
            }
        }
        callStartedAt = nil
        currentDirection = nil
        currentContactName = nil
        callAudioActive = false
    }

    func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logs.append("[\(stamp)] \(line)")
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }
}
