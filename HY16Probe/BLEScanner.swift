//
//  BLEScanner.swift
//  HY16Probe
//
//  Bluetooth LE controller.
//
//  Discovery/connect surface is unchanged from the original read-only
//  build:
//    - CBCentralManager.scanForPeripherals(withServices:options:)
//    - CBCentralManager.stopScan()
//    - CBCentralManager.connect(_:options:)
//    - CBCentralManager.cancelPeripheralConnection(_:)
//    - CBPeripheral.discoverServices(nil)
//    - CBPeripheral.discoverCharacteristics(nil, for:)
//
//  As of the approved TEST 1B pass (voice/AI transport investigation),
//  this file writes EXACTLY SIX documented commands, all scoped to the
//  verified physical HY-16 characteristics (HY16Protocol.swift), and
//  subscribes to exactly ONE notify characteristic:
//    - peripheral.setNotifyValue(true, for:) on the verified READ/NOTIFY
//      characteristic only, so responses can be observed and logged.
//    - peripheral.writeValue(...) from sendTakePhoto() - ONLY the
//      documented 0x0D01 / value-8 (Take Photo) frame.
//    - peripheral.writeValue(...) from sendVideoControl(start:) - ONLY
//      the documented 0x0D01 / value-9 (start) or value-10 (stop) frame.
//    - peripheral.writeValue(...) from sendWifiApControl(on:) - ONLY the
//      documented 0x090B WiFi-AP-on/off frame.
//    - peripheral.writeValue(...) from sendVideoPreviewControl(start:) -
//      ONLY the documented 0x090A / value-1 (start) or value-0 (stop)
//      Video Preview Control frame. The device's 0x0908 response
//      (Real-time Video API) is DEV->APP only - this file never sends
//      it, only decodes and logs whatever address string the physical
//      glasses report, verbatim, with no guessed/hardcoded RTSP URL or
//      port anywhere.
//    - peripheral.writeValue(...) from sendGetSupportedFeatures() - ONLY
//      the documented 0x0005 request (empty payload). A read-only
//      capability query, sends no other command, changes no device
//      state. Response decode logs every documented feature bit,
//      particularly AI Dialogue (doc offset 12) and BLE Audio (doc
//      offset 14) support.
//  TEST 1A (voice/AI transport investigation, pure observation pass)
//  added ZERO new send methods. It only teaches didUpdateValueFor(_:)
//  to decode and log two DEV->APP notify command IDs the physical
//  glasses already emit on their own when AI Dialogue is triggered FROM
//  THE GLASSES (button or voice wake) - 0x0805 (AI Dialogue trigger)
//  and 0x0A03 (BLE Audio data).
//    - peripheral.writeValue(...) from sendBLEAudioControl(start:) -
//      ONLY the documented 0x0A02 / value-1 (8kHz AI-dialogue mic
//      uplink) or value-0 (off) request. This is the ONLY new command
//      TEST 1B adds - called EXCLUSIVELY from an explicit user tap on
//      "Enable 8kHz Mic Uplink" / "Disable Mic Uplink" in
//      ContentView.swift. Critically: receiving 0x0805 (AI Dialogue
//      Trigger) NEVER calls this method - there is no automatic
//      response to 0x0805 anywhere in this file. Value 2 (16kHz) is
//      never sent.
//  No other command, value, OTA, delete, or reset logic exists anywhere
//  in this file. In particular: no 0x0806 (AI Dialogue link establish -
//  deliberately not implemented this pass, per the explicit TEST 1B
//  scope), no 0x0A01 (Get Call Status - also not implemented this
//  pass), no 0x0918-0x091B (WiFi P2P), no 0x091D/0x091E/0x0921/0x0922
//  (video duration/resolution config), no RTSP client/player of any
//  kind (no
//  MobileVLCKit, no FFmpeg, no AVPlayer pointed at a network stream -
//  the existing AVPlayer usage in this file is strictly for local
//  downloaded-MP4-file playback, added in a prior pass, and is
//  untouched here), no Opus decode, no PCM conversion, no audio
//  playback, no Speech framework, no AVSpeechSynthesizer. Sending only
//  ever happens from an explicit user tap on a button (see
//  ContentView.swift) - nothing here fires automatically.
//
//  Pass 1 also adds a single read-only HTTP GET (fetchFileListRaw) to
//  whatever URL the glasses themselves report via 0x090E, now extended
//  (Pass 2a) to also decode that response using the CONFIRMED real JSON
//  schema (Models.swift: GlassFileListResponse/GlassFile) into `fileList`.
//
//  Pass 2a adds exactly one more network method, downloadPhoto(_:), which
//  performs exactly one GET (never DELETE/POST/PUT) for exactly one file
//  the user explicitly tapped, and decodes it with UIImage(data:) for
//  on-screen display. There is no bulk/automatic download anywhere.
//
//  Pass 2b adds exactly one Photos-library method, savePhotoToLibrary(),
//  which saves ONLY the currently-displayed downloadedImage, ONLY when
//  explicitly called from the "Save to Photos" button tap. It requests
//  the narrowest possible authorization (.addOnly, never .readWrite) and
//  uses only PHAssetChangeRequest.creationRequestForAsset(from:) - there
//  is no PHAsset fetch/enumerate anywhere, so the existing photo library
//  is never read.
//
//  The video pass adds exactly one more network method, downloadVideo(_:),
//  parallel to (but not modifying) downloadPhoto(_:). It performs exactly
//  one GET for exactly one file the user explicitly tapped, using the
//  file's own "url" field verbatim (never a hardcoded path), writes the
//  bytes to a local temp file, and hands it to AVPlayer for playback.
//  Media type (photo vs video) is decided by file extension only
//  (Models.swift: GlassFile.mediaKind), never by HTTP Content-Type - the
//  physical HY-16 is confirmed to send "application/octet-stream" for a
//  real MP4. No RTSP, no WiFi P2P, no video config commands anywhere.
//
//  Connection only ever happens when the user explicitly taps a device in
//  the UI (see ContentView.swift). Nothing here auto-connects.
//

import Foundation
import CoreBluetooth
import UIKit // UIImage only, for displaying a downloaded photo (Pass 2a). No Photos framework.
import Photos // Add-only asset creation (Pass 2b) - only requestAuthorization(for: .addOnly) and PHAssetChangeRequest.creationRequestForAsset(from:) are used; no read access.
import AVFoundation // AVPlayer/AVURLAsset only, for local MP4 playback (video pass). No recording/capture APIs used.

final class BLEScanner: NSObject, ObservableObject {

    // MARK: Published state for the UI

    @Published var isScanning: Bool = false
    @Published var bluetoothStateDescription: String = "Bluetooth state unknown"
    @Published var discovered: [UUID: DiscoveredPeripheral] = [:]
    @Published var sortedDevices: [DiscoveredPeripheral] = []

    @Published var connectionState: String = "Not connected"
    @Published var connectedPeripheralID: UUID?
    @Published var services: [ServiceInfo] = []
    @Published var logLines: [String] = []

    /// True once both the verified write characteristic and the verified
    /// notify characteristic have been discovered on the connected
    /// peripheral. The "Take Photo" button is gated on this.
    @Published var canSendCommands: Bool = false

    // MARK: Media WiFi state (Pass 1) - populated only from real notify
    // frames the glasses send after 0x090B/on is requested. Nothing here
    // is guessed or auto-filled.

    @Published var wifiApRequested: Bool = false
    @Published var wifiConnected: Bool = false
    @Published var wifiSSID: String?
    @Published var wifiPassword: String?
    @Published var wifiIP: String?
    @Published var fileListURLString: String?
    @Published var isFetchingFileList: Bool = false
    @Published var fileListRawResponse: String?
    @Published var fileList: [GlassFile] = []

    // MARK: Single-photo download state (Pass 2a) - populated only by an
    // explicit tap on one file via downloadPhoto(_:). No bulk download,
    // no auto-download, no Photos-library code anywhere in this class.

    @Published var isDownloadingPhoto: Bool = false
    @Published var downloadedImage: UIImage?
    @Published var downloadedImageFile: GlassFile?
    @Published var downloadError: String?

    // MARK: Single-video download/playback state - populated only by an
    // explicit tap on one .mp4 file via downloadVideo(_:). No bulk
    // download, no auto-download, no upload anywhere.

    @Published var isDownloadingVideo: Bool = false
    @Published var videoPlayer: AVPlayer?
    @Published var downloadedVideoFile: GlassFile?

    // MARK: Live preview test state (0x090A/0x0908) - ANALYSIS TEST PASS.
    // Populated only by explicit taps on "Start Live Preview"/"Stop Live
    // Preview". previewAddress/previewAddressRawHex hold EXACTLY what the
    // physical glasses reported via the 0x0908 notify, decoded verbatim -
    // never a guessed or hardcoded rtsp:// URL. No RTSP client/player
    // exists anywhere in this codebase yet.

    @Published var isPreviewRequested: Bool = false
    @Published var previewResponseReceived: Bool = false
    @Published var previewAddress: String?
    @Published var previewAddressRawHex: String?

    // MARK: Get Supported Features test state (0x0005) - TEST 0 for the
    // voice/AI investigation. Populated only by an explicit tap on "Get
    // Supported Features". Read-only capability query - sends no other
    // command, changes no device state.

    @Published var supportedFeaturesRawHex: String?
    @Published var supportsAIDialogue: Bool?
    @Published var supportsBLEAudio: Bool?

    // MARK: TEST 1A state (0x0805/0x0A03) - PURE OBSERVATION. Populated
    // only by real notify frames the glasses choose to emit on their own
    // (triggered from the physical device, not by this app). This app
    // never sends 0x0805, 0x0806, or 0x0A03 - see TEST 1B below for the
    // one manual, explicit-tap exception (0x0A02). resetTest1ACounters()
    // below only clears these local counters - it sends nothing to the
    // device.

    @Published var aiDialogueTriggerCount: Int = 0
    @Published var lastAIDialogueState: String = "Not observed"
    @Published var bleAudioPacketCount: Int = 0
    @Published var bleAudioByteCount: Int = 0
    @Published var lastBLEAudioPayloadLength: Int?

    // MARK: TEST 1B state (0x0A02) - MANUAL ONLY. sendBLEAudioControl(_:)
    // below is called ONLY from an explicit user tap on "Enable 8kHz Mic
    // Uplink" / "Disable Mic Uplink" - NEVER automatically, and NEVER as
    // a reaction to receiving 0x0805. Reuses the exact same
    // bleAudioPacketCount/bleAudioByteCount/lastBLEAudioPayloadLength
    // counters from TEST 1A above to observe any resulting 0x0A03
    // traffic - no separate counters needed.

    @Published var bleAudioUplinkRequested: Bool = false
    @Published var bleAudioControlAckReceived: Bool = false

    // MARK: Audio-capture forensic test hook (approved pass). Optional
    // closure, set by ContentView to AudioCaptureController's
    // processIncoming0xA03(payload:sequence:). BLEScanner has NO
    // knowledge of Opus/AVFoundation/capture state - it only forwards
    // the exact same decoded payload the 0x0A03 case below already
    // counts/logs, unmodified, alongside the frame's sequence byte. Nil
    // (never set) is a no-op - existing TEST 1A/1B behavior is
    // unaffected whether or not this is wired up.
    var onBLEAudioDataPacket: (([UInt8], UInt8) -> Void)?

    // MARK: Save-to-Photos state (Pass 2b) - populated only by an explicit
    // tap on the "Save to Photos" button via savePhotoToLibrary(). Saves
    // only the currently-displayed downloadedImage - never a loop, never
    // automatic.

    @Published var isSavingPhoto: Bool = false
    @Published var saveResultMessage: String?

    // MARK: Private

    private var centralManager: CBCentralManager!
    private var activePeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var nextSequenceNumber: UInt8 = 0

    override init() {
        super.init()
        // queue: nil => delegate callbacks arrive on the main queue, so it's
        // safe to update @Published properties directly from them.
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: Scanning (read-only)

    func startScan() {
        guard centralManager.state == .poweredOn else {
            log("Cannot scan - Bluetooth is not powered on (state=\(describe(centralManager.state)))")
            return
        }
        discovered.removeAll()
        sortedDevices.removeAll()
        log("scanForPeripherals(withServices: nil) - scanning for ALL nearby BLE peripherals")
        centralManager.scanForPeripherals(withServices: nil, options: nil)
        isScanning = true
    }

    func stopScan() {
        centralManager.stopScan()
        isScanning = false
        log("Scan stopped")
    }

    // MARK: Connection (only ever called from an explicit user tap in the UI)

    func connect(to device: DiscoveredPeripheral) {
        if isScanning {
            stopScan()
        }
        activePeripheral = device.peripheral
        device.peripheral.delegate = self
        services = []
        connectionState = "Connecting..."
        log("connect() -> \(device.name) [\(device.id.uuidString)] (user-initiated tap)")
        centralManager.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        guard let peripheral = activePeripheral else { return }
        log("cancelPeripheralConnection() -> \(peripheral.identifier.uuidString)")
        centralManager.cancelPeripheralConnection(peripheral)
    }

    // MARK: Take Photo (0x0D01 / value 8 - documented, physically proven)
    //
    // Sends ONLY the documented 0x0D01 / value-8 (Take Photo) request to
    // the verified write characteristic.

    func sendTakePhoto() {
        guard let peripheral = activePeripheral, let writeChar = writeCharacteristic else {
            log("sendTakePhoto() ABORTED - not connected or write characteristic not found yet")
            return
        }
        let seq = nextSequenceNumber
        let frame = HY16Protocol.buildTakePhotoFrame(sequence: seq)
        let data = Data(frame)

        log("RAW TX: \(HY16Protocol.hexString(frame))")
        log("DECODED TX: 0x0D01 REQUEST seq=\(seq) — Device Control: Take Photo (value 8)")
        log("  write type: .withoutResponse (matches Hyper's real traffic - 11/11 captured writes to this handle were ATT \"Write Command\", never \"Write Request\")")

        peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
        nextSequenceNumber = nextSequenceNumber &+ 1
    }

    // MARK: Start/Stop Video Recording (0x0D01 / values 9 and 10 - documented,
    // same command family and frame shape as the already-proven Take Photo)
    //
    // Sends ONLY the documented 0x0D01 / value-9 (start) or value-10 (stop)
    // request to the verified write characteristic. No other value, no
    // resolution/duration config command, no RTSP/preview command.

    func sendVideoControl(start: Bool) {
        guard let peripheral = activePeripheral, let writeChar = writeCharacteristic else {
            log("sendVideoControl() ABORTED - not connected or write characteristic not found yet")
            return
        }
        let seq = nextSequenceNumber
        let frame = HY16Protocol.buildVideoControlFrame(start: start, sequence: seq)
        let data = Data(frame)

        let valueDescription = start ? "Start Video Recording (value 9)" : "Stop Video Recording (value 10)"
        log("RAW TX: \(HY16Protocol.hexString(frame))")
        log("DECODED TX: 0x0D01 REQUEST seq=\(seq) — Device Control: \(valueDescription)")
        log("  write type: .withoutResponse (same pattern as Take Photo, matches Hyper's real captured traffic for this handle)")

        peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
        nextSequenceNumber = nextSequenceNumber &+ 1
    }

    // MARK: WiFi AP control (Pass 1 of media import - approved)
    //
    // Sends ONLY the documented 0x090B WiFi AP Control request (on/off).
    // Same write characteristic, same write-without-response type,
    // matching Hyper's real captured traffic for this handle.

    func sendWifiApControl(on: Bool) {
        guard let peripheral = activePeripheral, let writeChar = writeCharacteristic else {
            log("sendWifiApControl() ABORTED - not connected or write characteristic not found yet")
            return
        }
        let seq = nextSequenceNumber
        let frame = HY16Protocol.buildWifiApControlFrame(on: on, sequence: seq)
        let data = Data(frame)

        log("RAW TX: \(HY16Protocol.hexString(frame))")
        log("DECODED TX: 0x090B REQUEST seq=\(seq) — WiFi AP Control: \(on ? "turn ON" : "turn OFF")")

        peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
        nextSequenceNumber = nextSequenceNumber &+ 1
        wifiApRequested = on
        if !on {
            // Closing the AP - clear the session's WiFi state so the UI
            // doesn't show stale credentials/URLs from a prior session.
            wifiConnected = false
            wifiSSID = nil
            wifiPassword = nil
            wifiIP = nil
            fileListURLString = nil
            fileListRawResponse = nil
        }
    }

    // MARK: Video Preview Control (0x090A - documented, approved TEST pass)
    //
    // Sends ONLY the documented 0x090A / value-1 (start) or value-0 (stop)
    // Video Preview Control request to the verified write characteristic.
    // Per the protocol doc + APP flow diagram, once the device opens
    // preview it sends 0x0908 (Real-time Video API) as an unsolicited
    // NOTIFY carrying an address string - decoded and logged verbatim in
    // didUpdateValueFor(_:), never guessed or hardcoded here. No RTSP
    // client/player is created anywhere - this method only sends the BLE
    // control frame and clears/tracks state so the UI can show exactly
    // what the physical device reported.

    func sendVideoPreviewControl(start: Bool) {
        guard let peripheral = activePeripheral, let writeChar = writeCharacteristic else {
            log("sendVideoPreviewControl() ABORTED - not connected or write characteristic not found yet")
            return
        }
        let seq = nextSequenceNumber
        let frame = HY16Protocol.buildVideoPreviewControlFrame(start: start, sequence: seq)
        let data = Data(frame)

        let valueDescription = start ? "Start Video Preview (value 1)" : "Stop Video Preview (value 0)"
        log("RAW TX: \(HY16Protocol.hexString(frame))")
        log("DECODED TX: 0x090A REQUEST seq=\(seq) — Video Preview Control: \(valueDescription)")
        log("  write type: .withoutResponse (same pattern as the other three proven commands on this handle)")

        peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
        nextSequenceNumber = nextSequenceNumber &+ 1
        isPreviewRequested = start
        if start {
            previewResponseReceived = false
            previewAddress = nil
            previewAddressRawHex = nil
        }
    }

    // MARK: Get Supported Features (0x0005 - TEST 0, approved investigation
    // pass for the voice/AI transport question)
    //
    // Sends ONLY the documented 0x0005 request (empty payload, per the
    // doc's "数据长度，0 表示无数据" - data length 0 = no data). Read-only
    // capability query - changes no device state, sends no other command.
    // Response decode/logging happens in didUpdateValueFor(_:) below.

    func sendGetSupportedFeatures() {
        guard let peripheral = activePeripheral, let writeChar = writeCharacteristic else {
            log("sendGetSupportedFeatures() ABORTED - not connected or write characteristic not found yet")
            return
        }
        let seq = nextSequenceNumber
        let frame = HY16Protocol.buildGetSupportedFeaturesFrame(sequence: seq)
        let data = Data(frame)

        log("RAW TX: \(HY16Protocol.hexString(frame))")
        log("DECODED TX: 0x0005 REQUEST seq=\(seq) — Get Supported Features")
        log("  write type: .withoutResponse (same pattern as the other proven commands on this handle)")

        peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
        nextSequenceNumber = nextSequenceNumber &+ 1
    }

    // MARK: TEST 1A/1B - reset local diagnostic counters ONLY. Sends
    // NOTHING to the device - this is a local UI/state reset, not a BLE
    // command.

    func resetTest1ACounters() {
        aiDialogueTriggerCount = 0
        lastAIDialogueState = "Not observed"
        bleAudioPacketCount = 0
        bleAudioByteCount = 0
        lastBLEAudioPayloadLength = nil
        bleAudioUplinkRequested = false
        bleAudioControlAckReceived = false
        log("TEST 1A/1B: local diagnostic counters reset (nothing sent to device)")
    }

    // MARK: BLE Audio Control (0x0A02, doc §11.2) - TEST 1B, MANUAL ONLY.
    //
    // Sends ONLY the documented 0x0A02 request: value 1 (8kHz AI-dialogue
    // mic uplink) or value 0 (off). Never sends value 2 (16kHz - not
    // tested this pass). Called ONLY from an explicit user tap on
    // "Enable 8kHz Mic Uplink" / "Disable Mic Uplink" in ContentView -
    // NEVER automatically, and NEVER as a reaction to receiving 0x0805
    // (didUpdateValueFor's 0x0805 case below does not call this). No
    // 0x0806 or 0x0A01 is sent anywhere in this file.

    func sendBLEAudioControl(start: Bool) {
        guard let peripheral = activePeripheral, let writeChar = writeCharacteristic else {
            log("sendBLEAudioControl() ABORTED - not connected or write characteristic not found yet")
            return
        }
        let seq = nextSequenceNumber
        let value = start ? HY16Protocol.bleAudioAIDialogue8kHz : HY16Protocol.bleAudioOff
        let frame = HY16Protocol.buildBLEAudioControlFrame(value: value, sequence: seq)
        let data = Data(frame)

        let valueDescription = start ? "AI Dialogue mic uplink, 8kHz (value 1)" : "off (value 0)"
        log("RAW TX: \(HY16Protocol.hexString(frame))")
        log("DECODED TX: 0x0A02 REQUEST seq=\(seq) — BLE Audio Control: \(valueDescription)")
        log("  write type: .withoutResponse (same pattern as the other proven commands on this handle)")

        peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
        nextSequenceNumber = nextSequenceNumber &+ 1
        bleAudioUplinkRequested = start
        bleAudioControlAckReceived = false
    }

    // MARK: File list (Pass 1 - read-only GET, raw text only, no parsing yet)
    //
    // Fetches whatever http://192.168.96.1/api/glass/file-list actually
    // returns and logs/stores it as raw text. Deliberately does NOT parse
    // a guessed JSON shape, and does NOT download or delete anything -
    // that's Pass 2, after we've seen a real response.
    //
    // This requires the iPhone to already be manually joined to the
    // glasses' WiFi network (e.g. via Settings) - this method does not
    // join WiFi itself.

    func fetchFileListRaw() {
        guard let urlString = fileListURLString, let url = URL(string: urlString) else {
            log("fetchFileListRaw() ABORTED - no file-list URL received from the glasses yet")
            return
        }
        isFetchingFileList = true
        log("HTTP GET \(urlString)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFetchingFileList = false
                if let error {
                    self.log("HTTP GET failed: \(error.localizedDescription)")
                    self.fileListRawResponse = "ERROR: \(error.localizedDescription)"
                    return
                }
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(non-UTF8 body, \(data?.count ?? 0) bytes)"
                self.log("HTTP response: status=\(statusCode) bytes=\(data?.count ?? 0)")
                self.log("RAW BODY: \(bodyText)")
                self.fileListRawResponse = "status \(statusCode):\n\(bodyText)"

                // Pass 2a: parse the confirmed JSON schema on top of the
                // raw-text log above. If it doesn't decode, the raw text
                // logged above is still there to inspect - nothing crashes.
                guard let data else { return }
                do {
                    let decoded = try JSONDecoder().decode(GlassFileListResponse.self, from: data)
                    self.fileList = decoded.files
                    self.log("Parsed file list: \(decoded.files.count) file(s)")
                } catch {
                    self.log("JSON decode failed: \(error.localizedDescription)")
                }
            }
        }
        task.resume()
    }

    // MARK: Single photo download (Pass 2a - one explicit-tap GET only)
    //
    // Builds the download URL from the already-confirmed fileListURLString
    // (scheme+host+port) plus this file's own "url" field, does exactly
    // one GET, requires HTTP 200, logs Content-Type + byte count (soft
    // check only), then hands the bytes to UIImage(data:) - which fails
    // safely (returns nil) if they aren't a valid image. No DELETE, no
    // POST, no PUT, no Photos-library code anywhere in this method.

    func downloadPhoto(_ file: GlassFile) {
        guard let baseString = fileListURLString,
              let base = URL(string: baseString),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            log("downloadPhoto() ABORTED - no known base URL yet")
            return
        }
        components.path = file.url
        components.query = nil
        guard let url = components.url else {
            log("downloadPhoto() ABORTED - could not build URL for \(file.url)")
            return
        }

        isDownloadingPhoto = true
        downloadError = nil
        log("HTTP GET \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDownloadingPhoto = false

                if let error {
                    self.log("Photo GET failed: \(error.localizedDescription)")
                    self.downloadError = error.localizedDescription
                    return
                }
                let httpResponse = response as? HTTPURLResponse
                let statusCode = httpResponse?.statusCode ?? -1
                let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "(none)"
                let byteCount = data?.count ?? 0
                self.log("Photo HTTP response: status=\(statusCode) Content-Type=\(contentType) bytes=\(byteCount)")

                guard statusCode == 200 else {
                    self.log("Photo download ABORTED - status was not 200")
                    self.downloadError = "HTTP \(statusCode)"
                    return
                }
                if !contentType.lowercased().hasPrefix("image/") {
                    self.log("WARNING: Content-Type does not start with \"image/\" - attempting to decode anyway")
                }

                guard let data, let image = UIImage(data: data) else {
                    self.log("Photo download FAILED - bytes did not decode as a valid image")
                    self.downloadError = "Downloaded \(byteCount) bytes but they were not a valid image"
                    return
                }
                self.log("Photo decoded successfully: \(file.name) (\(byteCount) bytes)")
                self.downloadedImage = image
                self.downloadedImageFile = file
            }
        }
        task.resume()
    }

    // MARK: Single video download + local playback (one explicit-tap GET only)
    //
    // Builds the download URL the exact same way downloadPhoto(_:) does
    // (fileListURLString's scheme/host/port + this file's own "url" field
    // - never a hardcoded "/channel0/" or any other guessed path), does
    // exactly one GET, requires HTTP 200. Content-Type is logged only,
    // never gated on - the physical HY-16 is confirmed to send
    // "application/octet-stream" for a real MP4, so Content-Type cannot
    // be used to validate video content. The JSON-reported `size` is
    // logged alongside the actual downloaded byte count but is NOT used
    // to reject the download - a real physical test showed these can
    // legitimately differ. On success, the bytes are written to a local
    // temporary file (original filename, never re-encoded/modified) and
    // handed to AVPlayer for in-app playback. No DELETE, no POST, no PUT,
    // no upload, no bulk/automatic download anywhere in this method.

    func downloadVideo(_ file: GlassFile) {
        guard let baseString = fileListURLString,
              let base = URL(string: baseString),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            log("downloadVideo() ABORTED - no known base URL yet")
            return
        }
        components.path = file.url
        components.query = nil
        guard let url = components.url else {
            log("downloadVideo() ABORTED - could not build URL for \(file.url)")
            return
        }

        isDownloadingVideo = true
        downloadError = nil
        log("HTTP GET \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60 // videos are much larger than photos

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDownloadingVideo = false

                if let error {
                    self.log("Video GET failed: \(error.localizedDescription)")
                    self.downloadError = error.localizedDescription
                    return
                }
                let httpResponse = response as? HTTPURLResponse
                let statusCode = httpResponse?.statusCode ?? -1
                let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "(none)"
                let byteCount = data?.count ?? 0
                self.log("Video HTTP response: status=\(statusCode) Content-Type=\(contentType) bytes=\(byteCount)")
                self.log("  JSON-reported size=\(file.size) bytes, actual downloaded=\(byteCount) bytes (size mismatch is NOT treated as an error - logged for investigation only)")

                guard statusCode == 200 else {
                    self.log("Video download ABORTED - status was not 200")
                    self.downloadError = "HTTP \(statusCode)"
                    return
                }
                // Content-Type deliberately NOT gated on - confirmed the
                // real device sends "application/octet-stream" for MP4s.

                guard let data, !data.isEmpty else {
                    self.log("Video download FAILED - no data received")
                    self.downloadError = "No data received"
                    return
                }

                let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
                do {
                    try data.write(to: destinationURL, options: .atomic)
                    self.log("Wrote \(byteCount) bytes to local file: \(destinationURL.path)")
                } catch {
                    self.log("Video FAILED to write local file: \(error.localizedDescription)")
                    self.downloadError = "Could not save video locally: \(error.localizedDescription)"
                    return
                }

                let player = AVPlayer(url: destinationURL)
                self.log("AVPlayer preparation: player created for local file \(destinationURL.lastPathComponent)")

                self.videoPlayer = player
                self.downloadedVideoFile = file
            }
        }
        task.resume()
    }

    // MARK: Save to Photos (Pass 2b - one explicit-tap save only)
    //
    // Saves ONLY the currently-displayed downloadedImage, ONLY when this
    // method is called (from the "Save to Photos" button tap). Requests
    // the narrowest possible authorization level (.addOnly, never
    // .readWrite) and uses only the asset-creation API - there is no
    // PHAsset fetch/enumerate anywhere in this method or anywhere else in
    // this file, so the existing photo library is never read.

    func savePhotoToLibrary() {
        guard let image = downloadedImage else {
            log("savePhotoToLibrary() ABORTED - no downloaded image to save")
            return
        }
        isSavingPhoto = true
        saveResultMessage = nil
        log("Requesting Photos add-only authorization…")

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.log("Photos authorization status: \(status.rawValue)")
                guard status == .authorized || status == .limited else {
                    self.isSavingPhoto = false
                    self.saveResultMessage = "Photos permission not granted"
                    self.log("Save ABORTED - Photos permission not granted (status: \(status.rawValue))")
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }, completionHandler: { success, error in
                    DispatchQueue.main.async {
                        self.isSavingPhoto = false
                        if success {
                            self.saveResultMessage = "Saved to Photos"
                            self.log("Photo saved to Photos library successfully")
                        } else {
                            let msg = error?.localizedDescription ?? "unknown error"
                            self.saveResultMessage = "Save failed: \(msg)"
                            self.log("Photo save FAILED: \(msg)")
                        }
                    }
                })
            }
        }
    }

    // MARK: Logging

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)"
        #if DEBUG
        print(line)
        #endif
        logLines.append(line)
    }

    private func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEScanner: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothStateDescription = "Bluetooth: \(describe(central.state))"
        log("centralManagerDidUpdateState -> \(describe(central.state))")
    }

    func centralManager(_ central: CBCentralManager,
                         didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any],
                         rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? "(unnamed device)"
        let upperName = name.uppercased()
        let isHY16 = upperName.contains("HY-16") || upperName.contains("HY16")

        let entry = DiscoveredPeripheral(
            id: peripheral.identifier,
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue,
            isHY16: isHY16,
            lastSeen: Date()
        )
        discovered[peripheral.identifier] = entry
        sortedDevices = Array(discovered.values).sorted { lhs, rhs in
            if lhs.isHY16 != rhs.isHY16 { return lhs.isHY16 && !rhs.isHY16 }
            return lhs.rssi > rhs.rssi
        }

        if isHY16 {
            log("MATCH: possible HY-16 device found: \(name) [\(peripheral.identifier.uuidString)] RSSI=\(RSSI)")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = "Connected to \(peripheral.name ?? "device")"
        connectedPeripheralID = peripheral.identifier
        writeCharacteristic = nil
        notifyCharacteristic = nil
        canSendCommands = false
        nextSequenceNumber = 0
        log("didConnect -> \(peripheral.identifier.uuidString). Calling discoverServices(nil).")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = "Connection failed: \(error?.localizedDescription ?? "unknown error")"
        log("didFailToConnect -> \(peripheral.identifier.uuidString): \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionState = "Disconnected"
        connectedPeripheralID = nil
        activePeripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        canSendCommands = false
        log("didDisconnectPeripheral -> \(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "none")")
    }
}

// MARK: - CBPeripheralDelegate

extension BLEScanner: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("didDiscoverServices ERROR: \(error.localizedDescription)")
            return
        }
        guard let discoveredServices = peripheral.services else {
            log("didDiscoverServices -> no services returned")
            return
        }
        log("didDiscoverServices -> found \(discoveredServices.count) service(s)")

        for service in discoveredServices {
            let label = KnownUUIDs.label(for: service.uuid)
            let info = ServiceInfo(uuid: service.uuid.uuidString, knownLabel: label)
            services.append(info)
            log("  Service \(service.uuid.uuidString)" + (label != nil ? " [\(label!)]" : " [UNKNOWN]"))

            // Discovery only - never a write.
            log("  -> discoverCharacteristics(nil, for: \(service.uuid.uuidString))")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("didDiscoverCharacteristics ERROR for \(service.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        guard let characteristics = service.characteristics else { return }
        guard let serviceIndex = services.firstIndex(where: { $0.uuid == service.uuid.uuidString }) else { return }

        for characteristic in characteristics {
            let props = characteristic.properties
            let label = KnownUUIDs.label(for: characteristic.uuid)
            let info = CharacteristicInfo(
                uuid: characteristic.uuid.uuidString,
                canRead: props.contains(.read),
                canWrite: props.contains(.write),
                canWriteWithoutResponse: props.contains(.writeWithoutResponse),
                canNotify: props.contains(.notify),
                canIndicate: props.contains(.indicate),
                knownLabel: label
            )
            services[serviceIndex].characteristics.append(info)

            log("    Char \(info.uuid)" + (label != nil ? " [\(label!)]" : " [UNKNOWN]")
                + " read=\(info.canRead) write=\(info.canWrite) writeNoResp=\(info.canWriteWithoutResponse)"
                + " notify=\(info.canNotify) indicate=\(info.canIndicate)")

            // Capture the two verified HY-16 characteristics only. Nothing
            // is written here - this just remembers *where* a future,
            // explicit, user-initiated write/subscribe would go.
            if characteristic.uuid.isEqual(HY16Protocol.writeCharacteristicUUID) {
                writeCharacteristic = characteristic
                log("    -> matched verified WRITE characteristic")
            } else if characteristic.uuid.isEqual(HY16Protocol.notifyCharacteristicUUID) {
                notifyCharacteristic = characteristic
                log("    -> matched verified READ/NOTIFY characteristic. Subscribing (setNotifyValue) so responses can be observed.")
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        canSendCommands = (writeCharacteristic != nil && notifyCharacteristic != nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("didWriteValueFor \(characteristic.uuid.uuidString) ERROR: \(error.localizedDescription)")
        } else {
            log("didWriteValueFor \(characteristic.uuid.uuidString) -> write acknowledged by peripheral")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("didUpdateValueFor \(characteristic.uuid.uuidString) ERROR: \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        log("RAW RX: \(HY16Protocol.hexString(bytes))")

        guard let frame = HY16Protocol.decodeFrame(bytes) else {
            log("DECODED RX: could not parse as an A5 frame")
            return
        }
        let name = HY16Protocol.commandName(frame.cmdID)
        let typeName = HY16Protocol.typeName(frame.type)
        let crcNote = frame.crcValid ? "CRC OK" : "CRC MISMATCH"
        log("DECODED RX: 0x\(String(format: "%04X", frame.cmdID)) \(typeName) — \(name) seq=\(frame.sequence) payload=[\(HY16Protocol.hexString(frame.payload))] (\(crcNote))")

        if frame.cmdID == 0x0905, frame.payload.count >= 2 {
            let count = UInt16(frame.payload[0]) | (UInt16(frame.payload[1]) << 8)
            log("  -> pending (not-yet-imported) file count is now \(count)")
        }

        // Pass 1 WiFi/media-import notify parsing. Read-only - this just
        // stores what the glasses themselves reported, nothing is inferred.
        switch frame.cmdID {
        case 0x0904: // Report Connection Status (doc page 46)
            guard !frame.payload.isEmpty else { break }
            let connected = frame.payload[0] == 1
            wifiConnected = connected
            if connected, frame.payload.count >= 5 {
                let ip = "\(frame.payload[1]).\(frame.payload[2]).\(frame.payload[3]).\(frame.payload[4])"
                wifiIP = ip
                if frame.payload.count > 5 {
                    let ssid = HY16Protocol.asciiString(Array(frame.payload[5...]))
                    wifiSSID = ssid
                    log("  -> connected, IP=\(ip), SSID=\(ssid)")
                } else {
                    log("  -> connected, IP=\(ip)")
                }
            } else {
                log("  -> not connected")
            }
        case 0x090C: // Report AP SSID
            wifiSSID = HY16Protocol.asciiString(frame.payload)
            log("  -> AP SSID = \(wifiSSID ?? "")")
        case 0x090D: // Report AP Password
            wifiPassword = HY16Protocol.asciiString(frame.payload)
            log("  -> AP password = \(wifiPassword ?? "")")
        case 0x090E: // Report WiFi Operation API URL
            fileListURLString = HY16Protocol.asciiString(frame.payload)
            log("  -> file-operations API URL = \(fileListURLString ?? "")")
        case 0x090A: // Video Preview Control response (ack)
            previewResponseReceived = true
            log("  -> Video Preview Control acknowledged by device")
        case 0x0908: // Real-time Video API - address string, decoded verbatim, never guessed
            let ascii = HY16Protocol.asciiString(frame.payload)
            let hex = HY16Protocol.hexString(frame.payload)
            previewAddress = ascii
            previewAddressRawHex = hex
            log("  -> LIVE PREVIEW ADDRESS reported by device (verbatim): ascii=\"\(ascii)\" hex=[\(hex)]")
        case 0x0005: // Get Supported Features response (doc §1.5)
            // Doc's documented "Offset(Bytes)" column is relative to the
            // START OF THE DATA SECTION (cmd_id+type+seq+len+payload), not
            // to the payload alone - decodeFrame() already strips that
            // 6-byte header before exposing `payload`, so every documented
            // field offset needs 6 subtracted to index into `payload`.
            // Bounds-checked per field since older/different firmware
            // could report a shorter payload than the full 13 fields.
            supportedFeaturesRawHex = HY16Protocol.hexString(frame.payload)
            log("  -> Get Supported Features RAW payload: [\(supportedFeaturesRawHex ?? "")] (\(frame.payload.count) bytes)")

            func featureBit(docOffset: Int, name: String) -> Bool? {
                let payloadIndex = docOffset - 6
                guard payloadIndex >= 0, payloadIndex < frame.payload.count else {
                    log("  -> \(name) (doc offset \(docOffset)): not present in this response (payload too short)")
                    return nil
                }
                let supported = frame.payload[payloadIndex] == 1
                log("  -> \(name) (doc offset \(docOffset), payload[\(payloadIndex)]=\(frame.payload[payloadIndex])): \(supported ? "SUPPORTED" : "not supported")")
                return supported
            }

            _ = featureBit(docOffset: 6, name: "Noise reduction / 降噪")
            _ = featureBit(docOffset: 7, name: "Wear detection switch / 佩戴检测开关")
            _ = featureBit(docOffset: 8, name: "Game mode / 游戏模式")
            _ = featureBit(docOffset: 9, name: "EQ audio effects / EQ音效")
            _ = featureBit(docOffset: 10, name: "Button settings / 按键设置")
            _ = featureBit(docOffset: 11, name: "Find device / 设备查找")
            supportsAIDialogue = featureBit(docOffset: 12, name: "AI Dialogue / AI对话")
            _ = featureBit(docOffset: 13, name: "WiFi glasses feature / WIFI眼镜功能")
            supportsBLEAudio = featureBit(docOffset: 14, name: "BLE Audio / BLE音频")
            _ = featureBit(docOffset: 15, name: "OTA upgrade / OTA升级")
            _ = featureBit(docOffset: 16, name: "Device control / 设备控制")
            _ = featureBit(docOffset: 17, name: "Local recording / 本地录音")
            _ = featureBit(docOffset: 18, name: "Voice wake / 语音唤醒")
        case 0x0A02: // BLE Audio Control response (doc §11.2) - empty-payload ack.
            // TEST 1B - only ever reached after this app's own explicit,
            // manual sendBLEAudioControl(_:) call. Logs the ack; does NOT
            // trigger anything further automatically.
            bleAudioControlAckReceived = true
            log("  -> BLE Audio Control acknowledged by device (CRC \(frame.crcValid ? "OK" : "MISMATCH"))")
        case 0x0805: // AI Dialogue Trigger (doc §9.5) - DEVICE->APP NOTIFY.
            // TEST 1A PURE OBSERVATION - this app never sends 0x0805.
            // Payload (doc offset 6): 0x01=start, 0x00=stop.
            aiDialogueTriggerCount += 1
            let stateDescription: String
            if frame.payload.first == 0x01 {
                stateDescription = "START"
            } else if frame.payload.first == 0x00 {
                stateDescription = "STOP"
            } else {
                stateDescription = "UNKNOWN(\(HY16Protocol.hexString(frame.payload)))"
            }
            lastAIDialogueState = stateDescription
            log("========================================")
            log("AI DIALOGUE TRIGGER RECEIVED")
            log("0x0805 = \(stateDescription)")
            log("cumulative 0x0805 notifications received: \(aiDialogueTriggerCount)")
            log("========================================")
        case 0x0A03: // BLE Audio Data (doc §11.3) - DEVICE->APP here.
            // TEST 1A PURE OBSERVATION - this app never sends 0x0A02,
            // 0x0A03, or 0x0806, and never activates microphone uplink.
            // No Opus decode, no PCM, no playback - count/log only. Doc
            // offset 6 (payload[0]) is a flow-control/send-interval byte,
            // not audio data; the rest is the documented Opus payload
            // (always a multiple of 40 bytes per the spec).
            bleAudioPacketCount += 1
            let audioDataByteCount = max(0, frame.payload.count - 1)
            bleAudioByteCount += audioDataByteCount
            lastBLEAudioPayloadLength = frame.payload.count

            if bleAudioPacketCount <= 5 {
                // Full detail for the first several packets.
                let flowControlByte = frame.payload.first.map { "\($0)" } ?? "(empty payload)"
                log("BLE AUDIO DATA packet #\(bleAudioPacketCount): decoded payload length=\(frame.payload.count) bytes, flow-control byte=\(flowControlByte), audio-data bytes=\(audioDataByteCount), cumulative audio-data bytes=\(bleAudioByteCount)")
            } else if bleAudioPacketCount % 20 == 0 {
                // Periodic summary thereafter, so rapid packet arrival
                // can't flood the log/UI - still proves continuous
                // traffic via the running counters.
                log("BLE AUDIO DATA summary: \(bleAudioPacketCount) packets received so far, \(bleAudioByteCount) cumulative audio-data bytes")
            }

            // Audio-capture forensic test hook (approved pass) - forwards
            // the same decoded payload/sequence to AudioCaptureController
            // when wired up. A no-op when nil, which is the case for every
            // proven TEST 1A/1B behavior above.
            onBLEAudioDataPacket?(frame.payload, frame.sequence)
        default:
            break
        }
    }
}
