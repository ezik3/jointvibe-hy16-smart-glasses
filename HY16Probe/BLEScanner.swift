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
//  As of the approved "Take Photo" test plus Pass 1 of media import, this
//  file writes EXACTLY TWO documented commands, both scoped to the
//  verified physical HY-16 characteristics (HY16Protocol.swift), and
//  subscribes to exactly ONE notify characteristic:
//    - peripheral.setNotifyValue(true, for:) on the verified READ/NOTIFY
//      characteristic only, so responses can be observed and logged.
//    - peripheral.writeValue(...) from sendTakePhoto() - ONLY the
//      documented 0x0D01 / value-8 (Take Photo) frame.
//    - peripheral.writeValue(...) from sendWifiApControl(on:) - ONLY the
//      documented 0x090B WiFi-AP-on/off frame.
//  No other command, value, OTA, delete, or reset logic exists anywhere
//  in this file. Sending only ever happens from an explicit user tap on
//  a button (see ContentView.swift) - nothing here fires automatically.
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
//  Connection only ever happens when the user explicitly taps a device in
//  the UI (see ContentView.swift). Nothing here auto-connects.
//

import Foundation
import CoreBluetooth
import UIKit // UIImage only, for displaying a downloaded photo (Pass 2a). No Photos framework.
import Photos // Add-only asset creation (Pass 2b) - only requestAuthorization(for: .addOnly) and PHAssetChangeRequest.creationRequestForAsset(from:) are used; no read access.

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

    // MARK: Take Photo (the one approved command)
    //
    // Sends ONLY the documented 0x0D01 / value-8 (Take Photo) request to
    // the verified write characteristic. This is the only method in this
    // class that calls writeValue.

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
        default:
            break
        }
    }
}
