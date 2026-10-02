# Protocol source notes — final merge

The supplied IKOS K7 Android source remains the authority for BLE protocol values and frame formats.

## GATT

- Service `0783B03E-8535-B5A0-7140-A304D2495CB7`
- RX `0783B03E-8535-B5A0-7140-A304D2495CB8`
- FLOW `0783B03E-8535-B5A0-7140-A304D2495CB9`
- TX `0783B03E-8535-B5A0-7140-A304D2495CBA`
- CCCD `00002902-0000-1000-8000-00805F9B34FB`

## Control

Header/channel byte `0x12`.
Control frame is C0-delimited with length/checksum and C0/DB escaping.

## Call

- `0x02` make call: `[02, simId, UTF-16LE(number)]`
- `0x03` DTMF opcode
- `0x04` hangup
- `0x05` answer/active event
- `0x0A` incoming call: `[0A, simId, UTF-16LE(number)]`
- `0x0B` call end
- `0x0F` voice open
- `0x10` voice close

## Audio

Channel 3. The Android source captures 8 kHz mono 16-bit PCM, frames 160 samples and encodes AMR-NB.

The iOS project now includes an iOS-compatible OpenCORE AMR-NB encoder/decoder boundary. Live speech still depends on the peer delivering/accepting the verified channel-3 AMR frames.
