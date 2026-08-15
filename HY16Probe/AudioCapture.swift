//
//  AudioCapture.swift
//  HY16Probe
//
//  Forensic audio-capture/decode test (approved pass). Isolated from
//  BLEScanner.swift, same reasoning as LivePreviewPlayer.swift being
//  kept separate - this file owns ONLY local capture state, PCM
//  accumulation, and Opus decode via alta/swift-opus (pinned commit,
//  see project.yml). It NEVER touches BLE directly: no CoreBluetooth
//  import, no write/notify code, no knowledge of characteristics/UUIDs.
//  The proven 0x0A02 send (sendBLEAudioControl(start:)) and the proven
//  0x0A03 counting/logging in BLEScanner.swift are UNCHANGED - this
//  file is fed raw 0x0A03 payloads via one new, minimal hook call from
//  BLEScanner's existing decode case, nothing more.
//
//  Evidence-based decoder configuration (not guessed): 8000 Hz, mono,
//  16-bit - matching the protocol doc's stated parameters for 0x0A02
//  value 1 (8kHz mode, the value TEST 1B has proven working), and
//  independently cross-validated via real libopus 1.2.1 TOC-byte
//  decoding in a prior forensic pass (see conversation history).
//
//  On a decode error for a single 40-byte chunk, this file logs the
//  error and continues to the NEXT chunk/packet - it does not abort
//  the whole capture, and it never tries a different frame-boundary
//  interpretation automatically. That would be "inventing another
//  interpretation," which was explicitly ruled out - any framing
//  investigation after a failed physical test happens manually, using
//  the preserved raw capture file, not automatically in this code.
//

import Foundation
import AVFoundation
import Opus

final class AudioCaptureController: ObservableObject {

    // MARK: Published diagnostic state - mirrors the requested UI exactly.

    @Published var isCaptureActive: Bool = false
    @Published var packetCount: Int = 0
    @Published var encodedByteCount: Int = 0
    @Published var opusFrameCount: Int = 0
    @Published var decodedFrameCount: Int = 0
    @Published var decodedSampleCount: Int = 0
    @Published var decoderErrorCount: Int = 0
    @Published var missingSequenceCount: Int = 0
    @Published var lastDecoderResult: String = "(none yet)"
    @Published var captureDurationText: String = "0.0s"
    @Published var lastRawCaptureURL: URL?
    @Published var lastWAVCaptureURL: URL?

    // MARK: Private capture state

    private let log: (String) -> Void
    private let audioFormat: AVAudioFormat
    private var decoder: Opus.Decoder?
    private var lastSequence: UInt8?
    private var rawCaptureBuffer = Data()
    private var accumulatedSamples: [Int16] = []
    private var captureStartDate: Date?
    private var durationTimer: Timer?

    init(log: @escaping (String) -> Void) {
        self.log = log
        // Evidence-based, not guessed: doc-documented 8kHz mic-uplink
        // mode (0x0A02 value 1, already proven), mono, 16-bit.
        guard let format = AVAudioFormat(opusPCMFormat: .int16, sampleRate: 8000, channels: 1) else {
            fatalError("AudioCapture: could not construct the documented 8kHz mono Opus PCM format")
        }
        self.audioFormat = format
    }

    // MARK: Start/Stop - local capture state ONLY. Sending the actual
    // 0x0A02 ON/OFF command remains the caller's responsibility, via the
    // existing, unmodified BLEScanner.sendBLEAudioControl(start:) - this
    // class never touches BLE.

    func startCapture() {
        packetCount = 0
        encodedByteCount = 0
        opusFrameCount = 0
        decodedFrameCount = 0
        decodedSampleCount = 0
        decoderErrorCount = 0
        missingSequenceCount = 0
        lastDecoderResult = "(none yet)"
        lastRawCaptureURL = nil
        lastWAVCaptureURL = nil
        lastSequence = nil
        rawCaptureBuffer = Data()
        accumulatedSamples = []

        do {
            decoder = try Opus.Decoder(format: audioFormat)
        } catch {
            log("AudioCapture: FAILED to create Opus decoder (8kHz mono): \(error)")
            decoder = nil
        }

        captureStartDate = Date()
        isCaptureActive = true
        captureDurationText = "0.0s"
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let start = self.captureStartDate else { return }
            self.captureDurationText = String(format: "%.1fs", Date().timeIntervalSince(start))
        }
        log("AudioCapture: capture started (decoder ready=\(decoder != nil))")
    }

    /// Finalizes the capture: always saves the raw bytes; saves a WAV
    /// ONLY if at least one chunk genuinely decoded. Never fabricates a
    /// WAV from undecoded/partially-decoded data.
    func stopCapture() {
        isCaptureActive = false
        durationTimer?.invalidate()
        durationTimer = nil

        let rawURL = saveRawCapture()
        lastRawCaptureURL = rawURL
        log("AudioCapture: raw capture saved (\(rawCaptureBuffer.count) bytes) -> \(rawURL?.path ?? "FAILED TO SAVE")")

        if decodedFrameCount > 0, !accumulatedSamples.isEmpty {
            let wavURL = saveWAV()
            lastWAVCaptureURL = wavURL
            log("AudioCapture: WAV saved (\(accumulatedSamples.count) samples, \(decodedFrameCount)/\(opusFrameCount) chunks decoded) -> \(wavURL?.path ?? "FAILED TO SAVE")")
        } else {
            lastWAVCaptureURL = nil
            log("AudioCapture: NO WAV created - decoding did not genuinely succeed (\(decodedFrameCount)/\(opusFrameCount) chunks decoded, \(decoderErrorCount) errors). Raw capture preserved for manual re-analysis.")
        }
    }

    // MARK: Called from BLEScanner's existing, unmodified 0x0A03 decode
    // case - one new hook call, nothing about the existing counting/
    // logging there changes. Only processes while a capture is active.

    func processIncoming0xA03(payload: [UInt8], sequence: UInt8) {
        guard isCaptureActive else { return }

        // Sequence-gap detection (doc §-generic Sequence Number field,
        // 0-255 wrapping, per the frame format every command uses).
        if let last = lastSequence {
            let expected = last &+ 1
            if sequence != expected {
                missingSequenceCount += 1
                log("AudioCapture: sequence gap - expected \(expected), got \(sequence) (missing/out-of-order count now \(missingSequenceCount))")
            }
        }
        lastSequence = sequence

        packetCount += 1
        rawCaptureBuffer.append(contentsOf: payload)

        guard !payload.isEmpty else {
            log("AudioCapture: packet #\(packetCount) had an empty payload - skipped")
            return
        }
        // Doc offset 6 = payload[0] = flow-control/send-interval byte,
        // not audio data (established and proven in TEST 1A/1B).
        let audioBytes = Array(payload.dropFirst())
        encodedByteCount += audioBytes.count

        // Split into 40-byte candidate Opus packets, per the documented
        // "packet content is always a multiple of 40 bytes" rule -
        // numerically proven against real captured data in prior
        // forensic work. Any trailing partial chunk is logged, not fed
        // to the decoder (never invent a shorter frame boundary).
        let chunkSize = 40
        var offset = 0
        while offset + chunkSize <= audioBytes.count {
            let chunk = Data(audioBytes[offset..<(offset + chunkSize)])
            decode(chunk: chunk)
            offset += chunkSize
        }
        if offset < audioBytes.count {
            log("AudioCapture: packet #\(packetCount) had \(audioBytes.count - offset) trailing bytes that don't form a full 40-byte chunk - not decoded, preserved in raw capture only")
        }
    }

    private func decode(chunk: Data) {
        opusFrameCount += 1
        guard let decoder else {
            lastDecoderResult = "ERROR: no decoder available"
            decoderErrorCount += 1
            return
        }
        do {
            let buffer = try decoder.decode(chunk)
            let frameLength = Int(buffer.frameLength)
            if frameLength > 0, let channelData = buffer.int16ChannelData {
                let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
                accumulatedSamples.append(contentsOf: samples)
            }
            decodedFrameCount += 1
            decodedSampleCount += frameLength
            lastDecoderResult = "OK (\(frameLength) samples)"
        } catch {
            decoderErrorCount += 1
            lastDecoderResult = "ERROR: \(error)"
            log("AudioCapture: Opus decode FAILED for chunk (opusFrame #\(opusFrameCount)): \(error) - preserving raw data, not trying an alternate framing")
        }
    }

    // MARK: File output

    private func saveRawCapture() -> URL? {
        let filename = "hy16_audio_raw_\(timestampString()).bin"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try rawCaptureBuffer.write(to: url, options: .atomic)
            return url
        } catch {
            log("AudioCapture: failed to write raw capture file: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveWAV() -> URL? {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(accumulatedSamples.count)) else {
            log("AudioCapture: could not allocate final PCM buffer for WAV export")
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(accumulatedSamples.count)
        if let channelData = pcmBuffer.int16ChannelData {
            accumulatedSamples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: accumulatedSamples.count)
            }
        }

        let filename = "hy16_audio_\(timestampString()).wav"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            // File type is inferred from the .wav path extension. commonFormat/
            // interleaved must be passed explicitly and match audioFormat exactly -
            // AVAudioFile's default processingFormat is Float32/interleaved
            // regardless of what `settings` describes for the on-disk format, which
            // does not match our Int16/non-interleaved mono pcmBuffer and crashes
            // write(from:) with an uncatchable format-mismatch exception.
            let file = try AVAudioFile(forWriting: url, settings: audioFormat.settings, commonFormat: audioFormat.commonFormat, interleaved: audioFormat.isInterleaved)
            try file.write(from: pcmBuffer)
            return url
        } catch {
            log("AudioCapture: failed to write WAV file: \(error.localizedDescription)")
            return nil
        }
    }

    private func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: Playback - simple AVAudioPlayer, no new permission needed.

    private var player: AVAudioPlayer?

    func playLastCapture() {
        guard let url = lastWAVCaptureURL else {
            log("AudioCapture: no decoded WAV available to play")
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
            log("AudioCapture: playing \(url.lastPathComponent)")
        } catch {
            log("AudioCapture: playback failed: \(error.localizedDescription)")
        }
    }
}
