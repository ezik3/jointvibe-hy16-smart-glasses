//
//  AudioDownlinkTest.swift
//  HY16Probe
//
//  Phase 0 speaker/downlink forensic test (approved pass) ONLY. Proves or
//  disproves whether the HY-16 firmware honors the documented APP->DEVICE
//  direction of 0x0A03 (protocol doc §11.3, headed "APP<->DEVICE") by
//  synthesizing one fixed test phrase, encoding it into the same Opus/
//  8kHz-mono/40-byte-frame shape our proven receive path already decodes,
//  and handing the resulting payloads to BLEScanner to send.
//
//  Completely isolated: no CoreBluetooth import, no knowledge of BLE UUIDs/
//  characteristics/CRC/sequencing, no STT, no LLM, no general TTS service,
//  no 0x0806. Does not touch AudioCaptureController, BLEScanner's proven
//  receive path, or anything from the protected mic-capture milestone
//  (commit d8eabb5 / tag hy16-ble-mic-audio-capture-proven-v1).
//
//  FRAMING DECISIONS - documented here, not hidden, since the public
//  alta/swift-opus Encoder API (inspected directly from source this pass)
//  does not expose libopus's CBR/bitrate/VBR controls the way the
//  observed device uplink stream appears to use:
//
//  1. Each 20ms/160-sample PCM chunk is Opus-encoded with the encoder's
//     default (VBR) settings - swift-opus's Opus.Encoder has no
//     opus_encoder_ctl exposure to force CBR, so an exact byte-for-byte
//     match to the device's own CBR+padding pattern is not achievable
//     through this package's public API.
//  2. The encoded output (almost always well under 40 bytes for narrowband
//     speech) is zero-padded up to exactly 40 bytes per frame slot. This
//     is not a guess: our own proven receive path (AudioCaptureController)
//     already decodes real captured device frames that are themselves
//     "real Opus payload + trailing zero bytes" within a fixed 40-byte
//     slice, via a plain decoder.decode(chunk) call with chunk.count==40 -
//     physically proven to work. This mirrors that exact, already-tested
//     tolerance symmetrically for encode.
//  3. Five 40-byte frames are batched per outer 0x0A03 payload (200 bytes
//     audio data + 1 flow-control byte = 201, exactly matching every
//     uplink packet shape physically observed and proven). The flow-
//     control byte value itself (10) reuses the one value ever observed
//     from the device, for the same reason - not invented.
//  4. If a single 20ms encode ever exceeds 40 bytes, that frame is logged
//     loudly and dropped (replaced with silence) rather than silently
//     truncated/corrupted - consistent with this project's "never
//     silently assume" rule.
//
//  This is a deliberate, evidence-grounded judgment call bridging a real
//  API gap, not a guess about protocol framing itself - flagged here in
//  full so it can be reconsidered if the physical test result warrants it.
//

import Foundation
import AVFoundation
import Opus

final class AudioDownlinkTestSender: ObservableObject {

    enum TestError: Error, LocalizedError {
        case formatUnavailable
        case alreadyRunning
        case synthesisProducedNoAudio

        var errorDescription: String? {
            switch self {
            case .formatUnavailable: return "Could not construct the 8kHz mono Opus PCM format"
            case .alreadyRunning: return "A downlink test synthesis is already in progress"
            case .synthesisProducedNoAudio: return "Speech synthesis produced zero audio samples"
            }
        }
    }

    // Reuses the exact same documented/proven values as the receive path -
    // not new constants invented for this file.
    private static let sampleRate: Double = 8000
    private static let samplesPerFrame = 160          // 20ms @ 8kHz mono
    private static let framesPerPacket = 5            // matches every proven uplink packet (200 bytes = 5x40)
    private static let bytesPerEncodedFrame = 40       // matches every proven uplink frame slot
    private static let flowControlByteValue: UInt8 = 10 // the one value ever observed from the device

    private let log: (String) -> Void
    private let audioFormat: AVAudioFormat
    private let encoder: Opus.Encoder
    private let synthesizer = AVSpeechSynthesizer()

    private var converter: AVAudioConverter?
    private var accumulatedSamples: [Int16] = []
    private var isRunning = false

    init(log: @escaping (String) -> Void) throws {
        self.log = log
        guard let format = AVAudioFormat(opusPCMFormat: .int16, sampleRate: Self.sampleRate, channels: 1) else {
            throw TestError.formatUnavailable
        }
        self.audioFormat = format
        // .voip: this is an encoder-side tuning hint only (bitrate/
        // complexity allocation), not part of the Opus bitstream a decoder
        // needs to match - chosen because the test content is speech at
        // 8kHz, not because any evidence requires it.
        self.encoder = try Opus.Encoder(format: format, application: .voip)
    }

    /// Synthesizes the fixed test phrase and produces ready-to-send 0x0A03
    /// downlink payloads (flow-control byte + up to 200 bytes of Opus
    /// audio data each). Does not touch BLE - the caller sends these via
    /// BLEScanner.sendDownlinkTestAudio(payloads:).
    func prepareTestPhrasePayloads(completion: @escaping (Result<[[UInt8]], Error>) -> Void) {
        guard !isRunning else {
            completion(.failure(TestError.alreadyRunning))
            return
        }
        isRunning = true
        converter = nil
        accumulatedSamples = []

        let phrase = "Joint Vibe test."
        log("AudioDownlinkTest: synthesizing test phrase: \"\(phrase)\"")
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        synthesizer.write(utterance) { [weak self] buffer in
            guard let self else { return }
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                self.log("AudioDownlinkTest: synthesizer returned a non-PCM buffer - ignored")
                return
            }
            if pcmBuffer.frameLength == 0 {
                // Documented Apple signal for "synthesis complete."
                self.finishSynthesis(completion: completion)
                return
            }
            self.appendConvertedSamples(from: pcmBuffer)
        }
    }

    private func appendConvertedSamples(from sourceBuffer: AVAudioPCMBuffer) {
        if converter == nil {
            converter = AVAudioConverter(from: sourceBuffer.format, to: audioFormat)
            log("AudioDownlinkTest: synthesizer format \(sourceBuffer.format) -> target \(audioFormat)")
        }
        guard let converter else {
            log("AudioDownlinkTest: could not create AVAudioConverter for the synthesizer's output format")
            return
        }
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: sourceBuffer.frameLength) else {
            log("AudioDownlinkTest: could not allocate conversion output buffer")
            return
        }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if status == .error {
            log("AudioDownlinkTest: sample-rate conversion FAILED: \(error?.localizedDescription ?? "unknown error")")
            return
        }
        guard outBuffer.frameLength > 0, let channelData = outBuffer.int16ChannelData else { return }
        let samples = UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength))
        accumulatedSamples.append(contentsOf: samples)
    }

    private func finishSynthesis(completion: @escaping (Result<[[UInt8]], Error>) -> Void) {
        isRunning = false
        let sampleCount = accumulatedSamples.count
        log("AudioDownlinkTest: synthesis complete - \(sampleCount) PCM samples at 8kHz mono (\(String(format: "%.2f", Double(sampleCount) / Self.sampleRate))s)")

        guard sampleCount > 0 else {
            DispatchQueue.main.async { completion(.failure(TestError.synthesisProducedNoAudio)) }
            return
        }

        // Pad to a whole number of 20ms frames, then pad further to a
        // whole number of 5-frame (100ms) outer packets, using silence -
        // never a short/irregular final packet, so every payload sent
        // matches the proven uplink shape exactly.
        var samples = accumulatedSamples
        let remainderInFrame = samples.count % Self.samplesPerFrame
        if remainderInFrame != 0 {
            samples.append(contentsOf: repeatElement(0, count: Self.samplesPerFrame - remainderInFrame))
        }
        var frameCount = samples.count / Self.samplesPerFrame
        let remainderInPacket = frameCount % Self.framesPerPacket
        if remainderInPacket != 0 {
            let framesToAdd = Self.framesPerPacket - remainderInPacket
            samples.append(contentsOf: repeatElement(0, count: framesToAdd * Self.samplesPerFrame))
            frameCount += framesToAdd
        }

        var encodedFrames: [[UInt8]] = []
        encodedFrames.reserveCapacity(frameCount)
        for frameIndex in 0..<frameCount {
            let start = frameIndex * Self.samplesPerFrame
            let frameSamples = Array(samples[start..<(start + Self.samplesPerFrame)])
            encodedFrames.append(encodeFrame(frameSamples, frameIndex: frameIndex))
        }

        var payloads: [[UInt8]] = []
        var index = 0
        while index < encodedFrames.count {
            let batch = encodedFrames[index..<min(index + Self.framesPerPacket, encodedFrames.count)]
            var payload: [UInt8] = [Self.flowControlByteValue]
            for frame in batch { payload.append(contentsOf: frame) }
            payloads.append(payload)
            index += Self.framesPerPacket
        }

        log("AudioDownlinkTest: encoded \(frameCount) Opus frames into \(payloads.count) downlink packet(s)")
        DispatchQueue.main.async { completion(.success(payloads)) }
    }

    /// Encodes one 160-sample (20ms) PCM chunk to exactly 40 bytes,
    /// zero-padding any unused tail. See file header for why this is the
    /// evidence-grounded choice given swift-opus's public API surface.
    private func encodeFrame(_ samples: [Int16], frameIndex: Int) -> [UInt8] {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(Self.samplesPerFrame)) else {
            log("AudioDownlinkTest: could not allocate PCM buffer for frame #\(frameIndex) - sending silence")
            return [UInt8](repeating: 0, count: Self.bytesPerEncodedFrame)
        }
        pcmBuffer.frameLength = AVAudioFrameCount(Self.samplesPerFrame)
        if let channelData = pcmBuffer.int16ChannelData {
            samples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: samples.count)
            }
        }

        var output = Data(count: 400) // generous headroom; actual Opus max is far smaller here
        do {
            let encodedByteCount = try encoder.encode(pcmBuffer, to: &output)
            guard encodedByteCount <= Self.bytesPerEncodedFrame else {
                log("AudioDownlinkTest: frame #\(frameIndex) encoded to \(encodedByteCount) bytes, exceeding the proven 40-byte slot - dropped (sent as silence) rather than corrupting the packet")
                return [UInt8](repeating: 0, count: Self.bytesPerEncodedFrame)
            }
            var bytes = [UInt8](output.prefix(encodedByteCount))
            if bytes.count < Self.bytesPerEncodedFrame {
                bytes.append(contentsOf: repeatElement(0, count: Self.bytesPerEncodedFrame - bytes.count))
            }
            return bytes
        } catch {
            log("AudioDownlinkTest: Opus encode FAILED for frame #\(frameIndex): \(error) - sending silence for this frame")
            return [UInt8](repeating: 0, count: Self.bytesPerEncodedFrame)
        }
    }
}
