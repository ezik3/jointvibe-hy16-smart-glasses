# HY-16 Protocol Notes

This document covers **only what this project has independently, physically
verified** against a real HY-16 unit, plus a small set of items the
manufacturer documents that this project has *not yet* physically
confirmed (marked explicitly below). It does not reproduce the
manufacturer's own protocol documents or SDK content — see
`vendor-reference/README.md` for where that material actually lives.
Command purposes/IDs listed here are our own factual technical notes
about *observed device behavior*, derived from source code comments in
this repository (`HY16Protocol.swift`, `BLEScanner.swift`,
`KnownUUIDs.swift`) written during development.

## Transport

- Standard BLE GATT, custom framing on top: an `A5`-prefixed frame with a
  CRC16 checksum (see `HY16Protocol.swift` for the exact frame layout).
- Commands are 16-bit IDs (e.g. `0x0805`).

## BLE UUIDs — PROVEN ON PHYSICAL HY-16

Confirmed by direct connection to a real HY-16 unit, cross-checked
against the manufacturer's own protocol document version 2.0.17 (page 8):

| UUID | Role |
|---|---|
| `01000100-0000-2000-8000-009078563412` | HY-16 primary BLE service |
| `03000300-0000-2000-8000-009278563412` | WRITE characteristic |
| `02000200-0000-2000-8000-009178563412` | READ/NOTIFY characteristic |

Note the `...-0000-2000-8000-...` family — the HY-16 uses this, **not**
the generic BES SDK's `...-0000-1000-8000-...` family (also present in
`KnownUUIDs.swift`, included there only as a reference for static
analysis of the manufacturer's generic SDK — those `1000`-family UUIDs
have not been observed on the physical HY-16 itself).

## Commands — PROVEN ON PHYSICAL HY-16

All of the following have been directly observed and/or successfully
sent/received against real hardware, in the order first proven
(see git history for the exact commit that first demonstrated each):

| Command | Direction | Purpose | Notes |
|---|---|---|---|
| `0x0D01` (value 8) | APP→DEVICE | Take Photo | |
| `0x0D01` (value 9 / 10) | APP→DEVICE | Start / Stop video recording | Same command family/frame shape as take-photo |
| `0x0D02` | DEVICE→APP notify | Local video recording status | |
| `0x0005` | APP→DEVICE request/response | Get Supported Features | Read-only capability query; used to confirm AI Dialogue / BLE Audio support before any audio code was written |
| `0x0805` | DEVICE→APP notify | AI Dialogue Trigger | App only **observes** this — never sends it. Fired by a physical button press or voice-wake on the glasses themselves |
| `0x0A02` | APP→DEVICE request/response | BLE Audio (mic uplink) Control | Value `1` = enable 8kHz mic uplink, `0` = disable. Manual-only in this app; never sent automatically in response to `0x0805` |
| `0x0A03` | DEVICE→APP notify | BLE Audio Data (mic uplink, Opus-encoded) | The actual microphone audio stream once `0x0A02` uplink is enabled |
| `0x090B` | APP→DEVICE | WiFi AP Control (on/off) | Pass 1 of media import |
| `0x0917`, `0x0904`, `0x090C`, `0x090D`, `0x090E`, `0x0916` | DEVICE→APP notify (various) | AP MAC / connection status / SSID / password / file-list API URL / file count | Part of the WiFi media-import flow |
| `0x090A` | APP→DEVICE | Video Preview Control (start=1/stop=0) | |
| `0x0908` | DEVICE→APP notify | Real-time Video API (RTSP address) | Sent by the device once preview is opened; app connects to the reported RTSP address, does not construct it |
| `0x0905` | DEVICE→APP notify | Pending file count update | |

### `0x0A03` also has a documented downlink (APP→DEVICE) direction

The manufacturer's protocol document describes `0x0A03` as bidirectional
— DEVICE→APP for the mic uplink above, and also APP→DEVICE (NOTIFY, not
request/response) for sending synthesized speaker audio *to* the
glasses ("AI说话中" / "AI speaking" state). This app built and tested a
downlink sender (`AudioDownlinkTest.swift`) that encodes text to the same
Opus/8kHz-mono/40-byte-frame shape the uplink decodes and sends it as
`0x0A03` APP→DEVICE. **This is a separate, isolated forensic
test path — it is NOT what the proven AI-conversation pipeline actually
uses for playback.** The proven pipeline plays AI replies through the
iPhone's normal Bluetooth-audio route (`GlassesSpeakerTestController`,
`AVAudioPlayer`/`AVAudioSession`), not this BLE downlink. Whether the
`0x0A03` downlink path is reliable enough to replace that Bluetooth-audio
route has not been conclusively determined.

## Milestones proven, in order (see git history for exact commits)

1. HY-16 photo pipeline: BLE take-photo → WiFi media import → HTTP
   file-list/download → Photos save.
2. MP4 video download and in-app playback.
3. Continuous RTSP live video+audio preview via VLCKit 4.0.0-a23.
4. AI Dialogue + BLE Audio + Voice Wake capability confirmed via `0x0005`
   feature query.
5. `0x0805` AI Dialogue Trigger and `0x0A03` BLE Audio Data observed
   (device-initiated, passive observation only).
6. HY-16 BLE mic uplink capture and Opus decode to audible WAV (`0x0A02`
   manual control + real `0x0A03` decode).
7. Full continuous AI conversation loop (this repository's baseline tag)
   — see `docs/AI_CONVERSATION_PIPELINE.md`.

## DOCUMENTED BY MANUFACTURER BUT NOT YET PHYSICALLY VERIFIED

Named in `HY16Protocol.swift`'s own comments as explicitly out of scope
so far — listed here for completeness, not because we have any
independent confirmation of their behavior:

- `0x0806` (AI Dialogue link/control — related to `0x0805` but not
  implemented or tested).
- `0x0A01` (Get Call Status — not defined in this codebase at all).
- Device Control values 11/12 (audio recording — not implemented).
- WiFi P2P (`0x0918`-`0x091B`).
- Video duration/resolution configuration (`0x091D`/`0x091E`/`0x0921`/`0x0922`).
- All OTA, delete, and reset commands.

Do not assume any of the above works as documented without physically
testing it first — everything in the "PROVEN" section above earned that
label through actual hardware testing, not by reading the manufacturer's
documentation alone.
