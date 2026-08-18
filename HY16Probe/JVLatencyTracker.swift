//
//  JVLatencyTracker.swift
//  HY16Probe
//
//  JV AI - end-to-end latency instrumentation (approved pass). Pure
//  measurement/logging utility - no CoreBluetooth/Opus/Speech import, no
//  knowledge of BLEScanner/JVSpeechTestController/OpenRouterAIService/
//  VoiceStudioTTSService/GlassesSpeakerTestController. Records named
//  checkpoints and prints one summary block per conversational turn.
//  Changes NOTHING about how any stage behaves - it only observes and
//  reports timing that (per this pass's investigation) already has a log
//  line at every checkpoint; this file just gives those moments a shared,
//  monotonic clock and computes the deltas between them.
//
//  MONOTONIC CLOCK (per explicit requirement): every existing timer in
//  this codebase (OpenRouterAIService.requestSentDate,
//  VoiceStudioTTSService.requestSentDate, GlassesSpeakerTestController.
//  requestDate, ContentView's prior pipelineStartDate) uses Date(), which
//  is wall-clock and not guaranteed monotonic (subject to NTP/clock
//  adjustment). This tracker deliberately uses DispatchTime.now()
//  (backed by mach_absolute_time()) instead, exactly for the new
//  aggregate measurement this pass adds. None of those existing Date()-
//  based per-controller timers are touched or removed - they keep
//  producing their own existing log lines unchanged.
//
//  ONE instance is created per conversational turn (in ContentView.swift,
//  the moment the VAD endpoint fires) and discarded after printing its
//  summary - no persistent state carried between turns.
//
//  "First byte" measurements for LLM/TTS are deliberately NOT implemented
//  this pass (see report) - both OpenRouterAIService and
//  VoiceStudioTTSService still use single-shot buffered URLSession
//  requests, so those two lines print "not measured (requires streaming
//  architecture - not implemented this pass)" rather than a fabricated
//  number.
//

import Foundation

final class JVLatencyTracker {

    private var checkpoints: [String: DispatchTime] = [:]
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    /// Records (or overwrites) the current monotonic time under `name`.
    /// Safe to call repeatedly with the same name - e.g. "lastVoicedAudio"
    /// is called on every voiced audio buffer, and only the LAST call
    /// before the VAD endpoint fires is what matters; each call simply
    /// overwrites the previous timestamp, which is exactly the desired
    /// "most recent voiced audio" semantics.
    func record(_ name: String) {
        checkpoints[name] = DispatchTime.now()
    }

    private func seconds(from: String, to: String) -> Double? {
        guard let start = checkpoints[from], let end = checkpoints[to] else { return nil }
        let deltaNanoseconds = Double(end.uptimeNanoseconds) - Double(start.uptimeNanoseconds)
        return deltaNanoseconds / 1_000_000_000
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "not measured (missing checkpoint)" }
        return String(format: "%.3fs", value)
    }

    /// Prints the exact summary block format approved for this pass.
    /// Missing checkpoints (e.g. if a stage failed/fell back) print
    /// "not measured" for that line rather than crashing or guessing.
    func printSummary() {
        log("=== JV LATENCY BREAKDOWN ===")
        log("Speech end → VAD endpoint: \(format(seconds(from: "lastVoicedAudio", to: "vadEndpointReached")))")
        log("VAD endpoint → endAudio(): \(format(seconds(from: "vadEndpointReached", to: "endAudioCalled")))")
        log("endAudio() → final transcript: \(format(seconds(from: "endAudioCalled", to: "finalTranscript")))")
        log("Final transcript → LLM request: \(format(seconds(from: "finalTranscript", to: "llmRequestSent")))")
        log("LLM request → first byte: not measured (requires streaming architecture - not implemented this pass)")
        log("LLM total: \(format(seconds(from: "llmRequestSent", to: "llmResponseComplete")))")
        log("TTS request → first byte: not measured (requires streaming architecture - not implemented this pass)")
        log("TTS total: \(format(seconds(from: "ttsRequestSent", to: "ttsComplete")))")
        log("Playback preparation: \(format(seconds(from: "ttsComplete", to: "playbackRequested")))")
        log("TOTAL last voiced audio → playback start: \(format(seconds(from: "lastVoicedAudio", to: "playbackRequested")))")
        log("============================")
    }
}

/// JV AI - latency instrumentation session holder (approved pass). Owns
/// exactly ONE JVLatencyTracker per conversational turn, so every
/// controller hook can call session.record(_:) unconditionally without
/// ContentView needing to manually re-wire four closures every turn.
/// A new turn starts via startNewTurn() (called from the existing START
/// SPEECH TEST button action in ContentView) and automatically prints
/// its summary the moment the final "playbackRequested" checkpoint
/// arrives - no separate print call needed anywhere else.
final class JVLatencySession: ObservableObject {

    private let log: (String) -> Void
    private var current: JVLatencyTracker?

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    func startNewTurn() {
        current = JVLatencyTracker(log: log)
    }

    func record(_ name: String) {
        guard let current else { return }
        current.record(name)
        if name == "playbackRequested" {
            current.printSummary()
        }
    }
}
