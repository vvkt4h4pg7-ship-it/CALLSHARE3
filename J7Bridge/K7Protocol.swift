import Foundation
import CoreBluetooth

enum K7Protocol {
    static let service = CBUUID(string: "0783B03E-8535-B5A0-7140-A304D2495CB7")
    static let rx = CBUUID(string: "0783B03E-8535-B5A0-7140-A304D2495CB8")
    static let flow = CBUUID(string: "0783B03E-8535-B5A0-7140-A304D2495CB9")
    static let tx = CBUUID(string: "0783B03E-8535-B5A0-7140-A304D2495CBA")

    // Commands/events recovered from the supplied IKOS K7 source.
    static let cmdDevCheck: UInt8 = 0x01
    static let cmdMakeCall: UInt8 = 0x02
    static let cmdDTMF: UInt8 = 0x03
    static let cmdHangup: UInt8 = 0x04
    static let cmdAnswer: UInt8 = 0x05
    static let cmdReadBattery: UInt8 = 0x09
    static let cmdFirmwareVersion: UInt8 = 0x12
    static let cmdCodecSel: UInt8 = 0x13
    static let cmdHoldCall: UInt8 = 0x0E
    static let cmdRetrieveCall: UInt8 = 0x0F
    static let cmdSetSpeechVolume: UInt8 = 0x1A
    static let cmdVibratorEnable: UInt8 = 0x30
    static let cmdVibratorCheck: UInt8 = 0x31
    static let cmdIMEIInfo: UInt8 = 0x71
    static let cmdGetCurrentCall: UInt8 = 0xA8

    static let evtDevCheck: UInt8 = 0x01
    static let evtDTMF: UInt8 = 0x02
    static let evtMakeCall: UInt8 = 0x03
    static let evtHangup: UInt8 = 0x04
    static let evtAnswer: UInt8 = 0x05
    static let evtReadBattery: UInt8 = 0x09
    static let evtReceiveCall: UInt8 = 0x0A
    static let evtReceiveCallEnd: UInt8 = 0x0B
    static let evtHoldCall: UInt8 = 0x13
    static let evtRetrieveCall: UInt8 = 0x14
    static let evtFirmwareVersion: UInt8 = 0x16
    static let evtIMEIInfo: UInt8 = 0x71
    static let evtVoiceOpen: UInt8 = 0x0F
    static let evtVoiceClose: UInt8 = 0x10

    static func makeCallPayload(number: String, simId: UInt8) -> Data {
        var data = Data([cmdMakeCall, simId])
        data.append(contentsOf: number.data(using: .utf16LittleEndian) ?? Data())
        return data
    }

    static func dtmfPayload(_ value: UInt8) -> Data {
        Data([cmdDTMF, value])
    }

    static func wrapControl(_ payload: Data) -> Data {
        let lengthField = payload.isEmpty ? 0 : UInt8((payload.count - 1) & 0xFF)
        let checksum = UInt8((~(0x12 + Int(lengthField))) & 0xFF)
        var out = Data([0xC0])
        appendEscaped(&out, 0x12)
        appendEscaped(&out, lengthField)
        appendEscaped(&out, checksum)
        for byte in payload { appendEscaped(&out, byte) }
        out.append(0xC0)
        return out
    }

    /// Channel-3 audio framing used by the working Android/K7 transport.
    /// A normal AMR-NB speech frame is 13...32 bytes including its ToC byte;
    /// the complete BLE frame therefore remains comfortably below the BLE MTU.
    static func wrapAudio(_ payload: Data) -> Data {
        let length = payload.count
        let h0 = UInt8(((length & 0x0F) << 4) | 0x03)
        let h1 = UInt8((length >> 4) & 0xFF)
        let checksum = UInt8((-Int(h0) - Int(h1)) & 0xFF)
        var out = Data([0xC0])
        appendEscaped(&out, h0)
        appendEscaped(&out, h1)
        appendEscaped(&out, checksum)
        for byte in payload { appendEscaped(&out, byte) }
        out.append(0xC0)
        return out
    }

    static func parse(_ raw: Data) -> (channel: Int, payload: Data)? {
        guard raw.count >= 4 else { return nil }
        var bytes = Array(raw)
        if bytes.first == 0xC0 {
            guard bytes.last == 0xC0 else { return nil }
            bytes.removeFirst()
            bytes.removeLast()
        }
        bytes = unescape(bytes)
        guard bytes.count >= 3 else { return nil }

        if bytes[0] == 0x12 {
            let length = Int(bytes[1]) + 1
            let checksum = UInt8((~(Int(bytes[0]) + Int(bytes[1]))) & 0xFF)
            guard bytes[2] == checksum, length == bytes.count - 3 else { return nil }
            return (2, Data(bytes[3..<bytes.count]))
        }

        let h0 = bytes[0]
        let h1 = bytes[1]
        let checksum = bytes[2]
        let length = Int(h0 >> 4) | (Int(h1) << 4)
        guard ((Int(h0) + Int(h1) + Int(checksum)) & 0xFF) == 0 else { return nil }
        guard length == bytes.count - 3, (h0 & 0x0F) == 3 else { return nil }
        return (3, Data(bytes[3..<bytes.count]))
    }

    /// Incremental C0-delimited parser. CoreBluetooth normally delivers one
    /// characteristic value per callback, but this also handles a frame split
    /// across callbacks or multiple frames delivered back-to-back. Escaping is
    /// preserved until a complete frame is available.
    final class StreamParser {
        private var buffer: [UInt8] = []
        private let maximumBufferedBytes = 8_192

        func reset() {
            buffer.removeAll(keepingCapacity: true)
        }

        func feed(_ data: Data) -> [(channel: Int, payload: Data)] {
            guard !data.isEmpty else { return [] }
            buffer.append(contentsOf: data)

            if buffer.count > maximumBufferedBytes {
                // A malformed stream must not be allowed to grow without bound.
                // Keep only the tail, which may still contain a new delimiter.
                buffer = Array(buffer.suffix(256))
            }

            var result: [(channel: Int, payload: Data)] = []

            while !buffer.isEmpty {
                guard let start = buffer.firstIndex(of: 0xC0) else {
                    buffer.removeAll(keepingCapacity: true)
                    break
                }

                if start > 0 {
                    buffer.removeFirst(start)
                }

                guard buffer.count >= 2 else { break }
                guard let end = buffer.dropFirst().firstIndex(of: 0xC0) else {
                    break
                }

                let frame = Data(buffer[0...end])
                buffer.removeFirst(end + 1)

                if let parsed = K7Protocol.parse(frame) {
                    result.append(parsed)
                }
                // Empty C0/C0 boundaries and invalid frames are deliberately
                // consumed so they cannot poison the next valid frame.
            }

            return result
        }
    }

    static func decodeIncomingNumber(_ payload: Data) -> String {
        guard payload.count > 2 else { return "" }
        let raw = Data(payload.dropFirst(2))
        return String(data: raw, encoding: .utf16LittleEndian)?
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func decodeASCIIBlock(_ payload: Data, offset: Int) -> String {
        guard payload.count > offset else { return "" }
        return String(data: Data(payload.dropFirst(offset)), encoding: .ascii)?
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func appendEscaped(_ out: inout Data, _ value: UInt8) {
        switch value {
        case 0xC0: out.append(contentsOf: [0xDB, 0xDC])
        case 0xDB: out.append(contentsOf: [0xDB, 0xDD])
        default: out.append(value)
        }
    }

    private static func unescape(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            if input[index] == 0xDB, index + 1 < input.count {
                switch input[index + 1] {
                case 0xDC:
                    output.append(0xC0)
                    index += 2
                    continue
                case 0xDD:
                    output.append(0xDB)
                    index += 2
                    continue
                default:
                    break
                }
            }
            output.append(input[index])
            index += 1
        }
        return output
    }
}
