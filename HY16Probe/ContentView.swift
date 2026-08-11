//
//  ContentView.swift
//  HY16Probe
//
//  UI only. Scanning starts only when the user taps "Scan for Glasses".
//  Connecting starts only when the user taps a discovered device.
//  Nothing in this file calls writeValue or sends any command.
//

import SwiftUI
import CoreBluetooth
import AVKit // VideoPlayer only, for displaying a downloaded MP4. No capture/recording APIs used.

private let byteCountFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f
}()

struct ContentView: View {
    @StateObject private var scanner = BLEScanner()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {

                Button(action: toggleScan) {
                    Text(scanner.isScanning ? "Stop Scanning" : "Scan for Glasses")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(scanner.isScanning ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }
                .padding(.horizontal)
                .padding(.top, 12)

                Text(scanner.bluetoothStateDescription)
                    .font(.footnote)
                    .foregroundColor(.secondary)

                if scanner.sortedDevices.isEmpty {
                    Spacer()
                    Text(scanner.isScanning ? "Scanning for nearby Bluetooth devices…" : "No devices yet. Tap \"Scan for Glasses\".")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                } else {
                    List(scanner.sortedDevices) { device in
                        NavigationLink(value: device.id) {
                            DeviceRow(device: device)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("HY16Probe")
            .navigationDestination(for: UUID.self) { id in
                if let device = scanner.discovered[id] {
                    DeviceDetailView(scanner: scanner, device: device)
                }
            }
        }
    }

    private func toggleScan() {
        if scanner.isScanning {
            scanner.stopScan()
        } else {
            scanner.startScan()
        }
    }
}

// MARK: - Device row (scan results list)

struct DeviceRow: View {
    let device: DiscoveredPeripheral

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if device.isHY16 {
                        Image(systemName: "eyeglasses")
                            .foregroundColor(.green)
                    }
                    Text(device.name)
                        .font(.headline)
                        .foregroundColor(device.isHY16 ? .green : .primary)
                }
                Text(device.id.uuidString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("\(device.rssi) dBm")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Device detail (connect + enumerate services/characteristics)

struct DeviceDetailView: View {
    @ObservedObject var scanner: BLEScanner
    let device: DiscoveredPeripheral

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Name", value: device.name)
                LabeledContent("Identifier", value: device.id.uuidString)
                LabeledContent("Status", value: scanner.connectionState)
            }

            if scanner.canSendCommands {
                Section("Commands (documented, v2.0.17 §14.1)") {
                    Button(action: { scanner.sendTakePhoto() }) {
                        Text("Take Photo")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Sends only 0x0D01 value 8 (Take Photo), the documented Device Control command.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        Button(action: { scanner.sendVideoControl(start: true) }) {
                            Text("Start Video")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: { scanner.sendVideoControl(start: false) }) {
                            Text("Stop Video")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Sends only 0x0D01 value 9 (start) or value 10 (stop) - Video Recording. Watch the Log below for the 0x0D02 status notify.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if scanner.canSendCommands {
                Section("Media WiFi (Pass 1, v2.0.17 §10.11)") {
                    Button(action: { scanner.sendWifiApControl(on: !scanner.wifiApRequested) }) {
                        Text(scanner.wifiApRequested ? "Disable Media WiFi" : "Enable Media WiFi")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if let ssid = scanner.wifiSSID {
                        LabeledContent("SSID", value: ssid)
                    }
                    if let password = scanner.wifiPassword {
                        LabeledContent("Password", value: password)
                    }
                    if let ip = scanner.wifiIP {
                        LabeledContent("Glasses IP", value: ip)
                    }
                    if scanner.wifiSSID != nil && !scanner.wifiConnected {
                        Text("Now join \"\(scanner.wifiSSID ?? "")\" manually in iPhone Settings → Wi-Fi, then come back here and tap Fetch File List.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let urlString = scanner.fileListURLString {
                        Text("File-list API: \(urlString)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Button(action: { scanner.fetchFileListRaw() }) {
                            if scanner.isFetchingFileList {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Fetch File List (raw)")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(scanner.isFetchingFileList)
                    }

                    if let raw = scanner.fileListRawResponse {
                        Text("Raw response:")
                            .font(.caption2.bold())
                        Text(raw)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            if !scanner.fileList.isEmpty {
                Section("Media Files (tap one to download, read-only GET)") {
                    ForEach(scanner.fileList) { file in
                        Button(action: {
                            switch file.mediaKind {
                            case .photo: scanner.downloadPhoto(file)
                            case .video: scanner.downloadVideo(file)
                            case .unknown: break
                            }
                        }) {
                            HStack {
                                Image(systemName: file.mediaKind == .video ? "video.fill" : "photo.fill")
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Text(byteCountFormatter.string(fromByteCount: Int64(file.size)))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if scanner.downloadedImageFile?.id == file.id || scanner.downloadedVideoFile?.id == file.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                        }
                        .disabled(scanner.isDownloadingPhoto || scanner.isDownloadingVideo || file.mediaKind == .unknown)
                    }

                    if scanner.isDownloadingPhoto {
                        HStack {
                            ProgressView()
                            Text("Downloading photo…")
                                .foregroundColor(.secondary)
                        }
                    }
                    if scanner.isDownloadingVideo {
                        HStack {
                            ProgressView()
                            Text("Downloading video…")
                                .foregroundColor(.secondary)
                        }
                    }

                    if let error = scanner.downloadError {
                        Text("Download error: \(error)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if let image = scanner.downloadedImage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(scanner.downloadedImageFile?.name ?? "")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .cornerRadius(8)

                            Button(action: { scanner.savePhotoToLibrary() }) {
                                if scanner.isSavingPhoto {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("Save to Photos")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(scanner.isSavingPhoto)

                            if let result = scanner.saveResultMessage {
                                Text(result)
                                    .font(.caption)
                                    .foregroundColor(result.hasPrefix("Saved") ? .green : .red)
                            }
                        }
                    }

                    if let player = scanner.videoPlayer {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(scanner.downloadedVideoFile?.name ?? "")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            VideoPlayer(player: player)
                                .frame(height: 220)
                                .cornerRadius(8)
                        }
                    }
                }
            }

            if scanner.services.isEmpty {
                Section {
                    Text(scanner.connectionState.hasPrefix("Connected")
                         ? "Discovering services…"
                         : "Waiting to connect…")
                        .foregroundColor(.secondary)
                }
            }

            ForEach(scanner.services) { service in
                Section {
                    ForEach(service.characteristics) { characteristic in
                        CharacteristicRow(characteristic: characteristic)
                    }
                } header: {
                    Text(serviceHeader(service))
                }
            }

            if !scanner.logLines.isEmpty {
                Section("Log") {
                    ForEach(Array(scanner.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
            }
        }
        .navigationTitle("Device Detail")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Connection happens here because the user tapped this device
            // from the list on the previous screen - never automatically.
            if scanner.connectedPeripheralID != device.id {
                scanner.connect(to: device)
            }
        }
        .onDisappear {
            scanner.disconnect()
        }
    }

    private func serviceHeader(_ service: ServiceInfo) -> String {
        let label = service.knownLabel ?? "UNKNOWN service"
        return "\(service.uuid)\n\(label)"
    }
}

// MARK: - Characteristic row

struct CharacteristicRow: View {
    let characteristic: CharacteristicInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(characteristic.uuid)
                .font(.system(size: 12, design: .monospaced))
            Text(characteristic.knownLabel ?? "UNKNOWN characteristic")
                .font(.caption2)
                .foregroundColor(characteristic.knownLabel != nil ? .green : .secondary)
            HStack(spacing: 8) {
                capabilityBadge("READ", characteristic.canRead)
                capabilityBadge("WRITE", characteristic.canWrite)
                capabilityBadge("WRITE-NR", characteristic.canWriteWithoutResponse)
                capabilityBadge("NOTIFY", characteristic.canNotify)
                capabilityBadge("INDICATE", characteristic.canIndicate)
            }
        }
        .padding(.vertical, 4)
    }

    private func capabilityBadge(_ label: String, _ isSupported: Bool) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isSupported ? Color.blue.opacity(0.2) : Color.gray.opacity(0.1))
            .foregroundColor(isSupported ? .blue : .gray)
            .cornerRadius(6)
    }
}

#Preview {
    ContentView()
}
