//
//  JVSpeechTestController.swift
//  HY16Probe
//
//  JV AI - Speech Test (approved pass). Proves ONLY: real HY-16
//  microphone audio, already decoded by the proven Opus receive path
//  (AudioCapture.swift), can be turned into real text via Apple's Speech
//  framework. No AI model call, no TTS, no 0x0806, no changes to the
//  Phase 0 speaker/downlink experiment - none of that exists in this
//  file or is referenced by it.
//
//  Completely isolated: no CoreBluetooth import, no knowledge of BLE
//  UUIDs/characteristics/CRC/sequencing, no Opus/swift-opus import. This
//  class receives only the same AVAudioPCMBuffer objects
//  AudioCaptureController's own proven decode(chunk:) already produces,
//  via one new optional hook (AudioCapture.swift's onDecodedPCMBuffer) -
//  it never touches BLEScanner or the Opus decoder itself.
//
//  iPhone's own microphone is NEVER used anywhere in this file - no
//  AVAudioEngine input tap, no AVCaptureDevice, no .record/.playAndRecord
//  audio session category. All audio fed to Speech recognition originates
//  from HY-16 over BLE, already decoded before it reaches this class.
//  Confirmed from the real Speech.framework header
//  (SFSpeechRecognitionRequest.h) that only NSSpeechRecognitionUsageDescription
//  is documented as required for SFSpeechRecognizer.requestAuthorization(_:) -
//  no microphone permission is added anywhere in this pass.
//
//  FORMAT-COMPATIBILITY DECISION (verified against the real SDK header,
//  not assumed): SFSpeechAudioBufferRecognitionRequest.appendAudioPCMBuffer(_:)
//  is documented as requiring "a native format" and exposes a read-only
//  `nativeAudioFormat` hint property. AudioCaptureController's decoded
//  buffers are fixed at 8kHz/Int16/mono/non-interleaved (the proven Opus
//  receive format - see AudioCapture.swift) and are NOT assumed to match
//  whatever nativeAudioFormat reports at runtime. Every buffer is
//  explicitly converted to the recognition request's own nativeAudioFormat
//  via AVAudioConverter before being appended - the same proven
//  single-shot AVAudioConverter pattern already used by
//  AudioDownlinkTest.swift's appendConvertedSamples(from:), reused here
//  rather than inventing a new technique. The proven Opus decoder/format
//  in AudioCapture.swift is never altered.
//
//  requiresOnDeviceRecognition is deliberately left at its default
//  (false) - per explicit instruction, reliability matters more than
//  forcing on-device operation for this first proof.
//
//  AUTOMATIC END-OF-SPEECH DETECTION (approved pass): SFSpeechAudioBuffer-
//  RecognitionRequest has no built-in endpointing (confirmed from the
//  real SFSpeechRecognitionRequest.h header - append/endAudio is the
//  entire lifecycle it documents). Apple's newer DictationTranscriber/
//  SpeechAnalyzer API family does support this, but is
//  @available(iOS 26.0, ...) in this SDK's own .swiftinterface, while
//  this project's deployment target is iOS 16.0 (project.yml) - out of
//  scope for a minimum-additive change. Endpointing is therefore done
//  ourselves via simple PCM RMS energy detection on the same decoded
//  AVAudioPCMBuffer objects already flowing through receivePCMBuffer(_:) -
//  no new permission, no new framework, no third-party VAD library.
//
//  voiceRMSThreshold below is an EXPERIMENTAL STARTING VALUE ONLY, not a
//  proven HY-16 constant - flagged here exactly like this project's other
//  disclosed judgment calls (e.g. AudioDownlinkTest.swift's flow-control
//  byte value). It is expected to need physical tuning; the periodic
//  diagnostic log exists specifically to make that tuning possible.
//

import Foundation
import AVFoundation
import Speech

final class JVSpeechTestController: ObservableObject {

    enum State {
        case idle
        case listening
        case processing

        var description: String {
            switch self {
            case .idle: return "Idle"
            case .listening: return "Listening"
            case .processing: return "Processing"
            }
        }
    }

    @Published var state: State = .idle
    @Published var transcript: String = ""

    // MARK: Closed-loop conversational test hook (approved pass). Optional
    // closure, set by ContentView to GlassesSpeakerTestController.speak(_:).
    // Fired with the final transcript text at the exact same moment
    // result.isFinal is already handled below - no new trigger mechanism,
    // just one more thing that happens at an already-existing event. Nil
    // (never set) is a no-op, so the proven "JV AI - SPEECH TEST" section
    // behaves identically whether or not this is wired up.
    var onFinalTranscript: ((String) -> Void)?

    // MARK: Barge-in hooks (approved pass). Optional closures, set by
    // JVConversationController. onInterimTranscript fires on every
    // NON-final partial result (existing behavior already updates
    // @Published transcript on every partial - this adds a dedicated
    // hook-driven signal alongside that, for barge-in decision-making).
    // onSustainedVoiceDetected fires at the exact moment hasDetectedSpeech
    // flips true below (i.e. genuine, sustained - not a single-buffer
    // spike - voiced audio, reusing the existing 300ms
    // minimumSpeechDurationBeforeAutoStopMs gate rather than inventing a
    // new one). Neither hook changes ASR/VAD behavior in any way - they
    // only report events that already occur.
    var onInterimTranscript: ((String) -> Void)?
    var onSustainedVoiceDetected: (() -> Void)?

    // MARK: Latency instrumentation hook (approved pass). Optional
    // closure, set by ContentView to JVLatencyTracker.record(_:). Fired
    // with a plain checkpoint-name String at moments that already have a
    // log line today - "lastVoicedAudio" (repeatedly, on every voiced
    // buffer - only the LAST call before the endpoint matters),
    // "vadEndpointReached", and "endAudioCalled"/"finalTranscript" below.
    // Nil (never set) is a no-op - changes nothing about ASR/VAD behavior.
    var onLatencyCheckpoint: ((String) -> Void)?

    private let log: (String) -> Void
    private let recognizer: SFSpeechRecognizer?

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var converter: AVAudioConverter?

    // MARK: Automatic end-of-speech (endpoint) detection state - see file
    // header. Reset at the start of every listening session in
    // beginRecognition(with:).
    private var hasDetectedSpeech: Bool = false
    private var consecutiveSilentDurationMs: Double = 0
    private var consecutiveVoicedDurationMs: Double = 0
    private var periodicDiagnosticAccumulatorMs: Double = 0

    // How long continuous silence must last, after real speech has been
    // detected, before we treat the user as finished talking. Changed
    // 1500 -> 900ms (approved pass) as an ISOLATED experiment - no other
    // VAD sensitivity constant (minimumSpeechDurationBeforeAutoStopMs,
    // voiceRMSThreshold) changed at the same time, so any physical result
    // can be attributed to this one variable. Revert by changing this one
    // number back to 1500 if 900ms proves too aggressive.
    private static let silenceEndpointDurationMs: Double = 900
    // How much cumulative voiced audio must be seen before auto-stop is
    // even armed - prevents ambient near-silence right after START from
    // immediately satisfying the silence threshold with an empty
    // transcript, and prevents a single short blip from arming it.
    private static let minimumSpeechDurationBeforeAutoStopMs: Double = 300
    // EXPERIMENTAL STARTING VALUE - see file header. RMS on the Int16
    // scale (max 32767). Not a proven HY-16 constant.
    private static let voiceRMSThreshold: Float = 300

    init(log: @escaping (String) -> Void) {
        self.log = log
        // Default locale (matches the user's current Settings > General >
        // Language locale) - not hardcoded to en-US, no assumption beyond
        // what SFSpeechRecognizer() itself already resolves.
        self.recognizer = SFSpeechRecognizer()
    }

    // MARK: Start/Stop - only ever called from an explicit user tap on
    // "START SPEECH TEST" / "STOP" in ContentView. Requires the existing,
    // proven Audio Capture/Decode Test section above to already be
    // active (real 0x0A02 mic uplink + real 0x0A03 decode) - this class
    // never sends 0x0A02 itself.

    func startListening() {
        guard state == .idle else {
            log("JVSpeechTest: startListening() ignored - already \(state.description)")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            log("JVSpeechTest: SFSpeechRecognizer unavailable for the current locale/network state - aborted")
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                guard let self else { return }
                switch authStatus {
                case .authorized:
                    self.beginRecognition(with: recognizer)
                case .denied, .restricted, .notDetermined:
                    self.log("JVSpeechTest: speech recognition authorization not granted (status=\(authStatus.rawValue)) - aborted")
                @unknown default:
                    self.log("JVSpeechTest: speech recognition authorization returned an unknown status (\(authStatus.rawValue)) - aborted")
                }
            }
        }
    }

    private func beginRecognition(with recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // requiresOnDeviceRecognition intentionally NOT set (stays at its
        // documented default, false) - see file header.
        recognitionRequest = request
        converter = nil
        transcript = ""
        state = .listening
        hasDetectedSpeech = false
        consecutiveSilentDurationMs = 0
        consecutiveVoicedDurationMs = 0
        periodicDiagnosticAccumulatorMs = 0
        log("JVSpeechTest: listening started (nativeAudioFormat hint = \(request.nativeAudioFormat))")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.log("JVSpeechTest: final transcript received")
                        self.onLatencyCheckpoint?("finalTranscript")
                        let finalText = self.transcript
                        self.finishRecognition()
                        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            self.onFinalTranscript?(finalText)
                        }
                    } else {
                        // Barge-in hook (approved pass) - fires on every
                        // partial/interim result, same data @Published
                        // transcript already exposes, just hook-driven.
                        self.onInterimTranscript?(self.transcript)
                    }
                }
                if let error {
                    self.log("JVSpeechTest: recognition ended with error: \(error.localizedDescription)")
                    self.finishRecognition()
                }
            }
        }
    }

    /// `reason` defaults to the manual-tap wording so the existing STOP
    /// button call site (ContentView.swift) is unaffected - automatic
    /// end-of-speech detection below passes its own reason string so the
    /// log makes clear which path triggered a given stop.
    func stopListening(reason: String = "manual STOP tapped") {
        guard state == .listening else {
            log("JVSpeechTest: stopListening() ignored - not currently listening (state=\(state.description))")
            return
        }
        state = .processing
        log("JVSpeechTest: ending audio (\(reason)) - waiting for final result")
        onLatencyCheckpoint?("endAudioCalled")
        recognitionRequest?.endAudio()
    }

    private func finishRecognition() {
        recognitionRequest = nil
        recognitionTask = nil
        converter = nil
        state = .idle
    }

    // MARK: PCM hook - wired by ContentView to
    // AudioCaptureController.onDecodedPCMBuffer. A no-op unless a speech
    // test is actively listening, so this has zero effect on the proven
    // capture/decode path when the JV AI section isn't in use.

    func receivePCMBuffer(_ buffer: AVAudioPCMBuffer) {
        guard state == .listening, let request = recognitionRequest else { return }
        // Append this buffer to the recognizer FIRST, then evaluate
        // whether it completes the end-of-speech endpoint. This ordering
        // matters: updateEndpointDetection(for:) may itself call
        // stopListening() (which calls endAudio()) - appending audio
        // after endAudio() has been called would be invalid, so the
        // append for this buffer must happen before that can occur.
        if let converted = convert(buffer, to: request.nativeAudioFormat) {
            request.append(converted)
        }
        updateEndpointDetection(for: buffer)
    }

    // MARK: Automatic end-of-speech (endpoint) detection - see file
    // header. Operates on the ORIGINAL decoded buffer (fixed Int16/8kHz/
    // mono, per AudioCaptureController's proven decode format), not the
    // converted one, so it works independent of whatever nativeAudioFormat
    // the recognizer reports.

    private func updateEndpointDetection(for buffer: AVAudioPCMBuffer) {
        guard let rms = rmsAmplitude(of: buffer) else { return }
        let durationMs = Double(buffer.frameLength) / buffer.format.sampleRate * 1000
        let isVoiced = rms >= Self.voiceRMSThreshold

        if isVoiced {
            onLatencyCheckpoint?("lastVoicedAudio")
            if hasDetectedSpeech, consecutiveSilentDurationMs > 0 {
                log("JVSpeechTest: speech resumed (silence had reached \(Int(consecutiveSilentDurationMs))ms) - resetting silence timer")
            }
            consecutiveSilentDurationMs = 0
            consecutiveVoicedDurationMs += durationMs
            if !hasDetectedSpeech, consecutiveVoicedDurationMs >= Self.minimumSpeechDurationBeforeAutoStopMs {
                hasDetectedSpeech = true
                log("JVSpeechTest: speech detected (voiced audio threshold reached)")
                onSustainedVoiceDetected?()
            }
        } else {
            if hasDetectedSpeech, consecutiveSilentDurationMs == 0 {
                log("JVSpeechTest: silence began")
                log("JVSpeechTest: endpoint timer started (\(Int(Self.silenceEndpointDurationMs))ms threshold)")
            }
            consecutiveSilentDurationMs += durationMs
        }

        periodicDiagnosticAccumulatorMs += durationMs
        if periodicDiagnosticAccumulatorMs >= 500 {
            periodicDiagnosticAccumulatorMs = 0
            log("JVSpeechTest: [diagnostic] rms=\(String(format: "%.0f", rms)) threshold=\(Int(Self.voiceRMSThreshold)) voiced=\(isVoiced) hasDetectedSpeech=\(hasDetectedSpeech) silenceMs=\(Int(consecutiveSilentDurationMs))")
        }

        if hasDetectedSpeech, consecutiveSilentDurationMs >= Self.silenceEndpointDurationMs {
            log("JVSpeechTest: end-of-speech endpoint reached (\(Int(consecutiveSilentDurationMs))ms continuous silence) - auto-stopping")
            onLatencyCheckpoint?("vadEndpointReached")
            stopListening(reason: "automatic end-of-speech detected")
        }
    }

    /// RMS (root-mean-square) amplitude of a buffer's Int16 samples, on
    /// the same 0-32767 scale as the raw PCM. nil if the buffer is empty
    /// or not Int16 (should never happen given AudioCaptureController's
    /// fixed decode format, but never force-unwrapped regardless).
    private func rmsAmplitude(of buffer: AVAudioPCMBuffer) -> Float? {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, let channelData = buffer.int16ChannelData else { return nil }
        let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
        var sumOfSquares: Double = 0
        for sample in samples {
            let value = Double(sample)
            sumOfSquares += value * value
        }
        return Float(sqrt(sumOfSquares / Double(frameLength)))
    }

    /// Converts a decoded PCM buffer to the recognition request's own
    /// nativeAudioFormat via AVAudioConverter - see file header for why
    /// this is done unconditionally rather than assuming the proven
    /// 8kHz/Int16/mono decode format is already acceptable as-is.
    private func convert(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == targetFormat {
            return buffer
        }
        if converter == nil {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                log("JVSpeechTest: could not create AVAudioConverter from \(buffer.format) to \(targetFormat)")
                return nil
            }
            converter = newConverter
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            log("JVSpeechTest: could not allocate PCM conversion output buffer")
            return nil
        }

        var conversionError: NSError?
        var consumed = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            log("JVSpeechTest: PCM conversion FAILED: \(conversionError?.localizedDescription ?? "unknown error")")
            return nil
        }
        return outputBuffer
    }
}
