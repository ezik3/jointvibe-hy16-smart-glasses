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
    @StateObject private var livePreview: LivePreviewController
    @StateObject private var audioCapture: AudioCaptureController
    @StateObject private var downlinkTest: AudioDownlinkTestSender
    @State private var downlinkTestStatus: String = "Idle"
    @StateObject private var jvSpeechTest: JVSpeechTestController
    @StateObject private var glassesSpeakerTest: GlassesSpeakerTestController
    @StateObject private var aiService: OpenRouterAIService
    @StateObject private var voiceStudioTTS: VoiceStudioTTSService
    @StateObject private var latencySession: JVLatencySession
    @StateObject private var conversationController: JVConversationController
    // M0 STEP 1 (approved pass) - same isolated StateObject+log-closure
    // pattern as every other controller above. Wired into
    // conversationController via the SEPARATE, additive configureM0(...)
    // call in .onAppear below - not a change to configure(...) itself.
    @StateObject private var jvGatewayProvider: JointVibeGatewayProvider
    @State private var m0Email: String = ""
    @State private var m0Password: String = ""
    @State private var m0SignInStatus: String = "Not signed in"

    init(scanner: BLEScanner, device: DiscoveredPeripheral) {
        self.scanner = scanner
        self.device = device
        // Routes LivePreviewController's log lines into the same diagnostic
        // Log section BLEScanner already populates - no change to
        // BLEScanner.swift needed since logLines is not private.
        _livePreview = StateObject(wrappedValue: LivePreviewController(log: { message in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            scanner.logLines.append("[\(timestamp)] \(message)")
        }))
        // Same pattern for the audio-capture forensic test (approved pass).
        // AudioCaptureController never touches BLE - scanner.onBLEAudioDataPacket
        // is the one hook that forwards raw 0x0A03 payloads to it. NOT wired
        // here: init() re-runs on every SwiftUI re-render of this view value
        // (this struct is reconstructed by .navigationDestination whenever
        // ContentView's body re-evaluates, which happens on every @Published
        // mutation on scanner - including every single 0x0A03 packet). Only
        // @StateObject's wrapped-value assignment is special-cased to survive
        // that; a closure built from a local variable here would silently
        // rebind onBLEAudioDataPacket to a fresh, never-started, throwaway
        // AudioCaptureController almost every packet, orphaning the real
        // (displayed, started) instance. Wired instead in .onAppear below,
        // against self.audioCapture - the actual persisted instance.
        _audioCapture = StateObject(wrappedValue: AudioCaptureController(log: { message in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            scanner.logLines.append("[\(timestamp)] \(message)")
        }))
        // Phase 0 speaker/downlink test (approved pass) - same isolated
        // pattern. The 8kHz mono Opus format this constructs is the exact
        // one already proven to succeed throughout this session (used
        // identically by AudioCaptureController above) - try! matches the
        // fatalError-on-truly-impossible-failure style used there.
        _downlinkTest = StateObject(wrappedValue: try! AudioDownlinkTestSender(log: { message in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            scanner.logLines.append("[\(timestamp)] \(message)")
        }))
        // JV AI - Speech Test (approved pass) - same isolated pattern as
        // audioCapture/downlinkTest above. Never touches BLE itself; only
        // consumes AVAudioPCMBuffer objects AudioCaptureController's
        // proven decode(chunk:) already produces, via the new
        // onDecodedPCMBuffer hook wired in .onAppear below.
        _jvSpeechTest = StateObject(wrappedValue: JVSpeechTestController(log: { message in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            scanner.logLines.append("[\(timestamp)] \(message)")
        }))
        // TEST GLASSES SPEAKER (approved pass) - same isolated pattern.
        // No BLE hook to wire in .onAppear below - this controller never
        // consumes anything from BLEScanner/AudioCaptureController, it
        // only uses normal iOS audio routing (PATH A).
        _glassesSpeakerTest = StateObject(wrappedValue: GlassesSpeakerTestController(log: { message in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            scanner.logLines.append("[\(timestamp)] \(message)")
        }))
        // JV AI - LLM-in-the-loop (approved pass) - same isolated pattern.
        // Reads config from HY16Probe/Secrets.plist (git-ignored) - never
        // touches BLE/audio/VAD/speaker code itself.
        _aiService = StateObject(wrappedValue: OpenRouterAIService(log: { message in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            scanner.logLines.append("[\(timestamp)] \(message)")
        }))
        // JV AI - VoiceStudio TTS (approved pass) - same isolated pattern.
        // Reads config from HY16Probe/Secrets.plist (git-ignored) - never
        // touches BLE/audio/VAD/LLM code itself.
        _voiceStudioTTS = StateObject(wrappedValue: VoiceStudioTTSService(log: { message in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            scanner.logLines.append("[\(timestamp)] \(message)")
        }))
        // JV AI - end-to-end latency instrumentation (approved pass) -
        // same isolated pattern. Pure measurement/logging; changes
        // nothing about ASR/VAD/LLM/TTS/playback behavior. Hooks wired
        // in .onAppear below, same reasoning as every other hook in this
        // init() - against self.latencySession, the real persisted
        // instance.
        _latencySession = StateObject(wrappedValue: JVLatencySession(log: { message in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            scanner.logLines.append("[\(timestamp)] \(message)")
        }))
        // JV AI - continuous conversation + barge-in (approved pass) -
        // same isolated pattern, log-closure-only init. Dependencies
        // (jvSpeechTest/aiService/voiceStudioTTS/glassesSpeakerTest/
        // latencySession) are wired in .onAppear below via configure(_:),
        // not here - see JVConversationController.swift's own header for
        // why (the established self.xxx-in-.onAppear convention this
        // project already relies on for every cross-controller hook).
        _conversationController = StateObject(wrappedValue: JVConversationController(log: { message in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            scanner.logLines.append("[\(timestamp)] \(message)")
        }))
        // M0 STEP 1 (approved pass) - same isolated pattern. Reads
        // Supabase URL/anon key from HY16Probe/Secrets.plist (git-ignored,
        // see Secrets.plist.example) - never touches BLE/audio/VAD/Kokoro
        // code. auth tokens live only as in-memory properties on this
        // instance - never persisted, never logged in full.
        _jvGatewayProvider = StateObject(wrappedValue: JointVibeGatewayProvider(log: { message in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            scanner.logLines.append("[\(timestamp)] \(message)")
        }))
    }

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
                Section("TEST 0 - Get Supported Features (0x0005, v2.0.17 §1.5)") {
                    Button(action: { scanner.sendGetSupportedFeatures() }) {
                        Text("Get Supported Features")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Read-only capability query - documented request/response, changes no device state. Voice/AI investigation TEST 0: determines whether this unit's firmware reports AI Dialogue and BLE Audio support before any audio code is written.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if let hex = scanner.supportedFeaturesRawHex {
                        Text("Raw response: [\(hex)]")
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if let ai = scanner.supportsAIDialogue {
                        LabeledContent("AI Dialogue (doc offset 12)", value: ai ? "Supported" : "Not supported")
                    }
                    if let ble = scanner.supportsBLEAudio {
                        LabeledContent("BLE Audio (doc offset 14)", value: ble ? "Supported" : "Not supported")
                    }
                }
            }

            if scanner.canSendCommands {
                Section("TEST 1A - AI/BLE Audio Observation") {
                    Text("This app never sends 0x0805, 0x0806, or 0x0A03, and never sends 0x0A02 automatically in response to 0x0805. It only observes and counts whatever the physical glasses choose to transmit on their own (button press or voice wake). 0x0A02 can only be sent manually via the separate TEST 1B controls below.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    LabeledContent("AI Dialogue notifications", value: "\(scanner.aiDialogueTriggerCount)")
                    LabeledContent("Last AI Dialogue state", value: scanner.lastAIDialogueState)
                    LabeledContent("BLE Audio packets received", value: "\(scanner.bleAudioPacketCount)")
                    LabeledContent("BLE Audio bytes received", value: "\(scanner.bleAudioByteCount)")
                    if let len = scanner.lastBLEAudioPayloadLength {
                        LabeledContent("Last BLE Audio payload length", value: "\(len) bytes")
                    }

                    Button(action: { scanner.resetTest1ACounters() }) {
                        Text("Reset TEST 1A/1B Counters")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Text("Resets only these local counters - sends nothing to the HY-16.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if scanner.canSendCommands {
                Section("TEST 1B - Manual Mic Uplink Control (0x0A02, v2.0.17 §11.2)") {
                    Text("MANUAL ONLY. Nothing here fires automatically or in response to 0x0805. First observe a real 0x0805 START above (physically trigger AI Dialogue on the glasses), THEN tap Enable below if you want to test whether the glasses begin sending 0x0A03. Never sends 0x0806 or 0x0A01.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        Button(action: { scanner.sendBLEAudioControl(start: true) }) {
                            Text("Enable 8kHz Mic Uplink")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: { scanner.sendBLEAudioControl(start: false) }) {
                            Text("Disable Mic Uplink")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Sends only 0x0A02 value 1 (8kHz AI-dialogue mic uplink) or value 0 (off) - documented §11.2. Never value 2 (16kHz).")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    LabeledContent("Mic uplink requested", value: scanner.bleAudioUplinkRequested ? "ON (8kHz)" : "OFF")
                    LabeledContent("0x0A02 acknowledged by device", value: scanner.bleAudioControlAckReceived ? "Yes" : "Not yet")
                    Text("Watch the BLE Audio packets/bytes counters in TEST 1A above for any resulting 0x0A03 traffic.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if scanner.canSendCommands {
                Section("Audio Capture/Decode Test (forensic probe - Opus via alta/swift-opus)") {
                    Text("Engineering probe only. Does not touch TEST 1B's proven 0x0A02/0x0A03 BLE behavior - only reads the same decoded payloads via a one-line hook. START sends the existing, unmodified 0x0A02 value 1; STOP sends 0x0A02 value 0. Raw bytes are always saved; a WAV is produced only if the Opus decoder genuinely succeeds.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    LabeledContent("CAPTURE ACTIVE", value: audioCapture.isCaptureActive ? "YES" : "NO")
                    LabeledContent("0x0A03 packets", value: "\(audioCapture.packetCount)")
                    LabeledContent("Encoded bytes", value: "\(audioCapture.encodedByteCount)")
                    LabeledContent("Opus frames", value: "\(audioCapture.opusFrameCount)")
                    LabeledContent("Decoded frames", value: "\(audioCapture.decodedFrameCount)")
                    LabeledContent("Decoded PCM samples", value: "\(audioCapture.decodedSampleCount)")
                    LabeledContent("Decoder errors", value: "\(audioCapture.decoderErrorCount)")
                    LabeledContent("Missing BLE packets", value: "\(audioCapture.missingSequenceCount)")
                    LabeledContent("Last decoder result", value: audioCapture.lastDecoderResult)
                    LabeledContent("Capture duration", value: audioCapture.captureDurationText)

                    HStack(spacing: 12) {
                        Button(action: {
                            audioCapture.startCapture()
                            scanner.sendBLEAudioControl(start: true)
                        }) {
                            Text("START AUDIO CAPTURE")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(audioCapture.isCaptureActive)

                        Button(action: {
                            scanner.sendBLEAudioControl(start: false)
                            audioCapture.stopCapture()
                        }) {
                            Text("STOP AUDIO CAPTURE")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!audioCapture.isCaptureActive)
                    }

                    HStack(spacing: 12) {
                        Button(action: { audioCapture.playLastCapture() }) {
                            Text("PLAY LAST CAPTURE")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(audioCapture.lastWAVCaptureURL == nil)

                        if let wavURL = audioCapture.lastWAVCaptureURL {
                            ShareLink(item: wavURL) {
                                Text("SHARE/SAVE LAST CAPTURE")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Text("SHARE/SAVE LAST CAPTURE")
                                .frame(maxWidth: .infinity)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let rawURL = audioCapture.lastRawCaptureURL {
                        Text("Raw: \(rawURL.lastPathComponent)")
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if let wavURL = audioCapture.lastWAVCaptureURL {
                        Text("WAV: \(wavURL.lastPathComponent)")
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            if scanner.canSendCommands {
                Section("JV AI — SPEECH TEST (forensic ASR probe)") {
                    Text("Proves ONLY that real HY-16 microphone audio can become real text via Apple's Speech framework. Requires the Audio Capture/Decode Test section above to already be active (tap START AUDIO CAPTURE there first, so real 0x0A02/0x0A03 decoding is happening) - this section only taps the already-decoded PCM via a new hook and never sends 0x0A02 itself, never touches BLE, and makes no AI/network calls of its own.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    LabeledContent("ASR State", value: jvSpeechTest.state.description)
                    LabeledContent("AI State", value: conversationController.aiState.description)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("YOU SAID:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(jvSpeechTest.transcript.isEmpty ? "(nothing yet)" : jvSpeechTest.transcript)
                            .font(.body)
                            .textSelection(.enabled)
                    }

                    Text("Continuous conversation mode (approved pass): START begins a conversation that keeps listening through the AI's thinking/speaking phase, so you can interrupt (barge-in) without pressing anything - just start talking. STOP ends the whole conversation.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        Button(action: { conversationController.startContinuousConversation() }) {
                            Text("START SPEECH TEST")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(jvSpeechTest.state != .idle)

                        Button(action: { conversationController.stopContinuousConversation() }) {
                            Text("STOP")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(jvSpeechTest.state != .listening && conversationController.aiState == .idle)
                    }
                }
            }

            // M0 STEP 1 (approved pass) - development-only test UI. Not
            // production Joint Vibe UI - just enough to sign in, verify
            // the session, and toggle which AI provider handleFinalTranscript
            // routes to. Never touches BLE/audio/Kokoro/speaker code.
            Section("JOINT VIBE AI GATEWAY (M0 STEP 1 - development only)") {
                Text("Runtime-only credentials - never stored, never committed. Relaunching the app requires signing in again. Toggling M0 ON routes the NEXT conversation turn to Joint Vibe's ai-gateway instead of OpenRouter; toggling it OFF restores the original, proven behavior exactly.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                LabeledContent("Auth status", value: jvGatewayProvider.authState.description)
                if let sessionID = jvGatewayProvider.lastSessionID {
                    LabeledContent("X-Session-Id", value: sessionID)
                }
                if let intent = jvGatewayProvider.lastIntent {
                    LabeledContent("X-Intent", value: intent)
                }
                if let remaining = jvGatewayProvider.lastRemainingTokens {
                    LabeledContent("X-Remaining-Tokens", value: remaining)
                }

                TextField("Email", text: $m0Email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.emailAddress)
                SecureField("Password", text: $m0Password)

                HStack(spacing: 12) {
                    Button(action: {
                        m0SignInStatus = "Signing in…"
                        jvGatewayProvider.signIn(email: m0Email, password: m0Password) { success in
                            m0SignInStatus = success ? "Signed in" : "Sign-in failed"
                            m0Password = "" // never retained beyond the single request either way
                        }
                    }) {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(m0Email.isEmpty || m0Password.isEmpty)

                    Button(action: {
                        jvGatewayProvider.verifySession { success in
                            m0SignInStatus = success ? "Session verified" : "Session verification FAILED"
                        }
                    }) {
                        Text("Verify Session")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(jvGatewayProvider.authState != .signedIn)
                }
                Text(m0SignInStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: { jvGatewayProvider.prewarm() }) {
                    Text("Pre-warm Gateway")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(jvGatewayProvider.authState != .signedIn)

                Divider()

                Toggle("M0 mode ON (route to Joint Vibe gateway)", isOn: $conversationController.m0ModeEnabled)
                    .disabled(jvGatewayProvider.authState != .signedIn)
                Text("Only selectable once signed in. When OFF, conversation turns use the original, unmodified OpenRouter path exactly as before.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Section("TEST GLASSES SPEAKER (PATH A - normal iOS Bluetooth audio)") {
                Text("Isolated test: iPhone → normal iOS audio system → Bluetooth audio profile → HY-16 speaker. Sends NO CoreBluetooth/BLE command and does not require a BLE connection - only that HY-16 is already Bluetooth-paired/audio-connected at the OS level, the same way Facebook/music audio already reaches it. Not the same thing as the separate, untouched 0x0A03 speaker-downlink experiment below.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                LabeledContent("State", value: glassesSpeakerTest.state.description)
                LabeledContent("Current output name", value: glassesSpeakerTest.currentOutputPortName)
                LabeledContent("Current output type", value: glassesSpeakerTest.currentOutputPortType)

                Button(action: { glassesSpeakerTest.testSpeaker() }) {
                    Text("TEST GLASSES SPEAKER")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(glassesSpeakerTest.state == .speaking)
            }

            if scanner.canSendCommands {
                Section("PHASE 0 - Speaker Downlink Test (temporary)") {
                    Text("Forensic test ONLY - does not touch the proven mic-capture path above. Synthesizes \"Joint Vibe test.\" on-device, encodes it to the same Opus/8kHz-mono/40-byte-frame shape the mic path decodes, and sends it APP->DEVICE as 0x0A03 (documented bidirectional, doc §11.3 / 图3-6-1). Sends no 0x0806. Physically listen to the glasses after tapping.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    LabeledContent("Status", value: downlinkTestStatus)

                    Button(action: {
                        downlinkTestStatus = "Synthesizing..."
                        downlinkTest.prepareTestPhrasePayloads { result in
                            switch result {
                            case .success(let payloads):
                                downlinkTestStatus = "Sending \(payloads.count) packet(s)..."
                                scanner.sendDownlinkTestAudio(payloads: payloads)
                                downlinkTestStatus = "Sent \(payloads.count) packet(s) - listen to the glasses"
                            case .failure(let error):
                                downlinkTestStatus = "FAILED: \(error.localizedDescription)"
                            }
                        }
                    }) {
                        Text("SEND SPEAKER TEST AUDIO")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
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

            if scanner.canSendCommands {
                Section("Live Preview Test (0x090A + RTSP - controlled proof-of-concept)") {
                    HStack(spacing: 12) {
                        Button(action: { scanner.sendVideoPreviewControl(start: true) }) {
                            Text("Start Live Preview")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: {
                            scanner.sendVideoPreviewControl(start: false)
                            livePreview.stop()
                        }) {
                            Text("Stop Live Preview")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Sends only 0x090A value 1 (start) or value 0 (stop) - Video Preview Control. When the device's real 0x0908 notify arrives, its address (never a hardcoded one) is opened with an RTSP player.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if let address = scanner.previewAddress {
                        LabeledContent("0x0908 address (ASCII)", value: address)
                    }
                    if let hex = scanner.previewAddressRawHex {
                        Text("0x0908 raw payload (hex): \(hex)")
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if scanner.isPreviewRequested && !scanner.previewResponseReceived {
                        Text("Waiting for device response…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("LIVE CAMERA PREVIEW")
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                        VLCPlayerView(controller: livePreview)
                            .frame(height: 220)
                            .background(Color.black)
                            .cornerRadius(8)
                        Text("Status: \(livePreview.status.label)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let url = livePreview.currentURLString {
                            Text("Playing from: \(url)")
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                        }
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

            Section("Log settings") {
                Toggle("Verbose 0x0A03 packet logging (forensic)", isOn: $scanner.verboseAudioPacketLogging)
                Text("OFF (default) suppresses the RAW RX/DECODED RX hex dump for routine, CRC-valid mic-audio packets only - all other commands and any CRC error are always logged either way. Turn ON to restore full forensic packet-level logging.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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
            // Audio-capture forensic test hook (approved pass) - wired here,
            // not in init(), specifically because .onAppear only fires when
            // this view value actually appears/reappears, not on every
            // re-render. self.audioCapture always resolves to the one true
            // @StateObject-persisted instance, so repeated firings just
            // re-point the closure at the same correct object - harmless.
            scanner.onBLEAudioDataPacket = { [weak audioCapture] payload, sequence in
                audioCapture?.processIncoming0xA03(payload: payload, sequence: sequence)
            }
            // JV AI - Speech Test hook (approved pass) - same .onAppear
            // reasoning as above: wired here, not init(), against
            // self.audioCapture/self.jvSpeechTest, the real persisted
            // instances. A no-op inside JVSpeechTestController unless a
            // speech test is actively listening.
            audioCapture.onDecodedPCMBuffer = { [weak jvSpeechTest] buffer in
                jvSpeechTest?.receivePCMBuffer(buffer)
            }
            // JV AI - continuous conversation + barge-in (approved pass) -
            // wired here for the same .onAppear reason as every hook
            // above: against self.xxx, the real persisted instances. This
            // ONE call replaces the previous ad-hoc onFinalTranscript/
            // onLatencyCheckpoint closure chain that used to live directly
            // in this .onAppear block - that logic (routing a successful
            // LLM reply through VoiceStudio TTS first, falling back to
            // Apple TTS speak(_:) on failure, and recording every
            // JVLatencyTracker checkpoint) is now inside
            // JVConversationController, unchanged in substance, plus the
            // new barge-in/continuous-listening/turn-generation behavior
            // this milestone adds. The older, separate "JVPipeline:" ad-
            // hoc timer (a simpler predecessor added before
            // JVLatencyTracker/JVLatencySession existed) is retired here -
            // its job is now done more completely by the still-fully-
            // intact "=== JV LATENCY BREAKDOWN ===" instrumentation
            // (JVLatencyTracker.swift, unchanged this pass), not lost.
            conversationController.configure(
                jvSpeechTest: jvSpeechTest,
                aiService: aiService,
                voiceStudioTTS: voiceStudioTTS,
                glassesSpeakerTest: glassesSpeakerTest,
                latencySession: latencySession
            )
            // M0 STEP 1 (approved pass) - SEPARATE, additive call, same
            // .onAppear reasoning as configure(...) above. Does not alter
            // configure(...)'s own behavior in any way.
            conversationController.configureM0(jvGatewayProvider: jvGatewayProvider)
        }
        .onDisappear {
            scanner.disconnect()
            livePreview.stop()
        }
        .onChange(of: scanner.previewAddress) { newAddress in
            // Only open the player if we're mid a user-initiated "start"
            // (isPreviewRequested) - never on stale leftover state, and
            // never with anything but the address the device just reported.
            guard scanner.isPreviewRequested, let newAddress else { return }
            livePreview.start(urlString: newAddress)
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
