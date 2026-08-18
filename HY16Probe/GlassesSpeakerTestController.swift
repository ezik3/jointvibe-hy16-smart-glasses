//
//  GlassesSpeakerTestController.swift
//  HY16Probe
//
//  TEST GLASSES SPEAKER (approved pass) - isolates PATH A ONLY:
//  iPhone -> normal iOS audio system -> Bluetooth audio profile -> HY-16
//  speaker. Proves/disproves nothing about the separate, untouched
//  0x0A03 speaker-downlink experiment (AudioDownlinkTest.swift) - this
//  file sends NO CoreBluetooth/BLE command of any kind, requires no BLE
//  connection, and never touches 0x0805/0x0A02/0x0A03/mic capture.
//
//  Motivated by a physical finding: PLAY LAST CAPTURE (AudioCapture.swift,
//  untouched by this pass) also uses plain AVAudioSession(.playback) +
//  a local audio player with zero BLE involvement, and DID eventually
//  play back through the HY-16 speaker - but only after an unexplained
//  ~2 minute delay that nothing in this app could observe, because no
//  route-change/interruption instrumentation existed anywhere. This file
//  adds that missing instrumentation and repeats an equivalent PATH A
//  test using AVSpeechSynthesizer's direct speak() playback instead of a
//  saved capture, so the test doesn't require a prior BLE mic session at
//  all - it can be run standalone.
//
//  Completely isolated: no CoreBluetooth import, no knowledge of BLE
//  UUIDs/characteristics/CRC/sequencing, no Opus, no knowledge of
//  AudioCaptureController/BLEScanner/AudioDownlinkTestSender/
//  JVSpeechTestController. Uses AVSpeechSynthesizer's speak(_:) API
//  directly (delegate-based playback) - a different code path from
//  AudioDownlinkTest.swift's write(_:toBufferCallback:) capture-only
//  usage, which never plays audio aloud.
//
//  AVAudioSession config is deliberately identical in shape to the
//  already-proven AudioCaptureController.playLastCapture() call
//  (.playback / .default, no extra options) - the only new variable is
//  the audio source (live TTS instead of a saved WAV) and the addition
//  of route/interruption instrumentation, verified against the real
//  AVFAudio.framework headers in this SDK (AVAudioSessionTypes.h,
//  AVAudioSessionRoute.h) rather than assumed.
//

import Foundation
import AVFoundation

final class GlassesSpeakerTestController: NSObject, ObservableObject {

    enum State {
        case idle
        case speaking
        case finished
        case failed

        var description: String {
            switch self {
            case .idle: return "Idle"
            case .speaking: return "Speaking"
            case .finished: return "Finished"
            case .failed: return "Failed"
            }
        }
    }

    @Published var state: State = .idle
    @Published var currentOutputPortName: String = "(unknown)"
    @Published var currentOutputPortType: String = "(unknown)"

    private let log: (String) -> Void
    private let synthesizer = AVSpeechSynthesizer()
    private var routeChangeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var requestDate: Date?
    // JV AI - VoiceStudio TTS (approved pass): holds the AVAudioPlayer
    // for playSynthesizedAudio(_:) below, additive alongside the existing
    // AVSpeechSynthesizer-based speak(_:) - that method and its state are
    // completely unchanged by this addition.
    private var audioPlayer: AVAudioPlayer?

    // MARK: Latency instrumentation hook (approved pass). Optional
    // closure, set by ContentView to JVLatencyTracker.record(_:). Fired
    // only from playSynthesizedAudio(_:) below, at the exact moment the
    // existing "playback requested (play() returned true)" log line
    // already fires - this method's speak(_:) sibling (Apple TTS path)
    // is untouched and does not report this checkpoint, since the
    // baseline latency breakdown this pass measures is specifically the
    // VoiceStudio/Kokoro path. Nil (never set) is a no-op.
    var onLatencyCheckpoint: ((String) -> Void)?

    // MARK: Playback-finished hook (approved pass). Optional closure, set
    // by JVConversationController to reset its own aiState after a
    // NORMAL, successful playback completion - fired only from
    // audioPlayerDidFinishPlaying(_:successfully:) and
    // speechSynthesizer(_:didFinish:) below, the two success-completion
    // delegate callbacks. Deliberately NOT fired from didCancel/
    // audioPlayerDecodeErrorDidOccur/setup-failure paths - those are a
    // separate, smaller remaining gap, out of scope for this pass. Nil
    // (never set) is a no-op - changes nothing about playback itself.
    var onPlaybackFinished: (() -> Void)?

    init(log: @escaping (String) -> Void) {
        self.log = log
        super.init()
        synthesizer.delegate = self
        refreshCurrentOutputDescription()
    }

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: Test entry point - only ever called from an explicit user tap
    // on "TEST GLASSES SPEAKER" in ContentView. Sends NO CoreBluetooth/
    // BLE command - PATH A only.

    func testSpeaker() {
        speak("Joint Vibe speaker test.")
    }

    /// Speaks arbitrary text through the same proven PATH A (normal iOS
    /// Bluetooth audio routing) as testSpeaker() above - factored out,
    /// approved pass, so the closed-loop conversational test can reuse
    /// the exact same proven mechanism with a different phrase. Behavior
    /// for the "Joint Vibe speaker test." case is unchanged byte-for-byte
    /// from before this refactor.
    func speak(_ text: String) {
        guard state != .speaking else {
            log("GlassesSpeakerTest: speak(_:) ignored - already speaking")
            return
        }
        requestDate = Date()
        state = .speaking
        log("GlassesSpeakerTest: requesting playback of \"\(text)\"")

        installNotificationObserversIfNeeded()
        logCurrentRoute(label: "BEFORE setCategory/setActive")

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log("GlassesSpeakerTest: AVAudioSession setup FAILED: \(error.localizedDescription)")
            state = .failed
            return
        }
        logCurrentRoute(label: "AFTER setActive")

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    /// JV AI - VoiceStudio TTS (approved pass). Plays PRE-SYNTHESIZED
    /// audio Data (e.g. from VoiceStudioTTSService) through the exact
    /// same proven PATH A (AVAudioSession .playback/.default, no extra
    /// options, same route/interruption instrumentation) as speak(_:)
    /// above - the only difference is AVAudioPlayer(data:) instead of
    /// AVSpeechSynthesizer, since the audio is already synthesized
    /// rather than needing on-device synthesis. speak(_:) itself is not
    /// modified by this method and remains available as the Apple-TTS
    /// fallback path (see ContentView.swift's onFinalTranscript wiring).
    func playSynthesizedAudio(_ data: Data) {
        guard state != .speaking else {
            log("GlassesSpeakerTest: playSynthesizedAudio(_:) ignored - already speaking")
            return
        }
        requestDate = Date()
        state = .speaking
        log("GlassesSpeakerTest: TTS requested - requesting playback of \(data.count) bytes of synthesized audio")

        installNotificationObserversIfNeeded()
        logCurrentRoute(label: "BEFORE setCategory/setActive (synthesized audio)")

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log("GlassesSpeakerTest: AVAudioSession setup FAILED: \(error.localizedDescription)")
            state = .failed
            return
        }
        logCurrentRoute(label: "AFTER setActive (synthesized audio)")

        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            audioPlayer = player
            let didStart = player.play()
            let elapsed = requestDate.map { String(format: "%.2fs", Date().timeIntervalSince($0)) } ?? "?"
            if didStart {
                // NOTE: AVAudioPlayer has no "did actually start" delegate
                // callback (unlike AVSpeechSynthesizer's didStart below) -
                // this is the moment play() was called/returned true, the
                // best available proxy, not a confirmed "audio is now
                // audible" event. Disclosed here rather than implied.
                log("GlassesSpeakerTest: playback requested (play() returned true) - \(elapsed) after request")
                onLatencyCheckpoint?("playbackRequested")
            } else {
                log("GlassesSpeakerTest: AVAudioPlayer.play() returned false - playback did not start")
                state = .failed
                audioPlayer = nil
            }
        } catch {
            log("GlassesSpeakerTest: AVAudioPlayer could not decode synthesized audio (\(data.count) bytes): \(error.localizedDescription)")
            state = .failed
        }
    }

    /// JV AI - barge-in (approved pass). Immediately stops any current
    /// AVSpeechSynthesizer speech and/or AVAudioPlayer playback, for use
    /// by JVConversationController.interruptCurrentResponse() when the
    /// wearer begins speaking while JV is talking. Safe to call even if
    /// nothing is currently playing (no-op in that case). Does NOT modify
    /// speak(_:) or playSynthesizedAudio(_:) themselves - purely an
    /// additive stop path alongside them. stopSpeaking(at:)/isSpeaking
    /// and stop()/isPlaying verified against the real AVSpeechSynthesis.h/
    /// AVAudioPlayer.h headers in this SDK rather than assumed.
    func stopImmediately() {
        guard state == .speaking else {
            log("GlassesSpeakerTest: stopImmediately() - nothing currently playing, no-op")
            return
        }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if let audioPlayer, audioPlayer.isPlaying {
            audioPlayer.stop()
        }
        audioPlayer = nil
        state = .idle
        log("GlassesSpeakerTest: stopImmediately() - playback/synthesis stopped for barge-in")
    }

    // MARK: Route/output diagnostics - verified against the real
    // AVFAudio.framework headers in this SDK (AVAudioSessionRoute.h:
    // portType/portName; AVAudioSessionTypes.h: notification key names
    // and enum cases) rather than assumed.

    private func logCurrentRoute(label: String) {
        let route = AVAudioSession.sharedInstance().currentRoute
        if route.outputs.isEmpty {
            log("GlassesSpeakerTest: currentRoute \(label) - NO outputs reported")
        } else {
            for output in route.outputs {
                log("GlassesSpeakerTest: currentRoute \(label) - output port type=\(output.portType.rawValue) name=\"\(output.portName)\"")
            }
        }
        refreshCurrentOutputDescription()
    }

    private func refreshCurrentOutputDescription() {
        let route = AVAudioSession.sharedInstance().currentRoute
        if let first = route.outputs.first {
            currentOutputPortName = first.portName
            currentOutputPortType = first.portType.rawValue
        } else {
            currentOutputPortName = "(none)"
            currentOutputPortType = "(none)"
        }
    }

    private func installNotificationObserversIfNeeded() {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let reasonValue = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
            self.log("GlassesSpeakerTest: routeChangeNotification - reason=\(self.describe(reason))")
            self.logCurrentRoute(label: "on routeChangeNotification")
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let typeValue = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            let description: String
            switch type {
            case .began: description = "began"
            case .ended: description = "ended"
            default: description = "unknown(\(typeValue))"
            }
            self.log("GlassesSpeakerTest: interruptionNotification - type=\(description)")
        }
    }

    private func describe(_ reason: AVAudioSession.RouteChangeReason?) -> String {
        guard let reason else { return "unknown" }
        switch reason {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        @unknown default: return "unknown(\(reason.rawValue))"
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate
//
// SwiftUI-warning fix (approved pass): Apple's real AVSpeechSynthesis.h/
// AVAudioPlayer.h headers document NO main-thread/actor guarantee for
// these delegate callbacks - confirmed by direct header inspection, no
// MainActor/main-queue annotation present. Every OTHER callback in this
// codebase (JVSpeechTestController's recognitionTask closure,
// OpenRouterAIService's and VoiceStudioTTSService's URLSession
// completions) already explicitly dispatches to main before touching any
// @Published property; these five methods were the one place that
// didn't, and are the identified, high-confidence source of the
// "Publishing changes from within view updates is not allowed" warning.
// Wrapping each body in DispatchQueue.main.async makes this file match
// every other callback's already-established pattern - no logic change,
// no new behavior, same eventual state transitions, just guaranteed
// on-main execution.

extension GlassesSpeakerTestController: AVSpeechSynthesizerDelegate {

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let elapsed = self.requestDate.map { String(format: "%.2fs", Date().timeIntervalSince($0)) } ?? "?"
            self.log("GlassesSpeakerTest: didStart (speech synthesis actually began) - \(elapsed) after request")
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let elapsed = self.requestDate.map { String(format: "%.2fs", Date().timeIntervalSince($0)) } ?? "?"
            self.log("GlassesSpeakerTest: didFinish - \(elapsed) after request")
            self.logCurrentRoute(label: "AFTER didFinish")
            self.state = .finished
            self.onPlaybackFinished?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let elapsed = self.requestDate.map { String(format: "%.2fs", Date().timeIntervalSince($0)) } ?? "?"
            self.log("GlassesSpeakerTest: didCancel - \(elapsed) after request")
            self.state = .failed
        }
    }
}

// MARK: - AVAudioPlayerDelegate (JV AI - VoiceStudio TTS, approved pass)
// Additive: used only by playSynthesizedAudio(_:) above. Method
// signatures verified against the real AVAudioPlayer.h header in this
// SDK (audioPlayerDidFinishPlaying(_:successfully:) /
// audioPlayerDecodeErrorDidOccur(_:error:)) rather than assumed. Same
// DispatchQueue.main.async fix as AVSpeechSynthesizerDelegate above.

extension GlassesSpeakerTestController: AVAudioPlayerDelegate {

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let elapsed = self.requestDate.map { String(format: "%.2fs", Date().timeIntervalSince($0)) } ?? "?"
            self.log("GlassesSpeakerTest: synthesized audio playback finished (successfully=\(flag)) - \(elapsed) after request")
            self.logCurrentRoute(label: "AFTER synthesized audio playback finished")
            self.state = flag ? .finished : .failed
            self.audioPlayer = nil
            if flag {
                self.onPlaybackFinished?()
            }
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.log("GlassesSpeakerTest: synthesized audio decode error: \(error?.localizedDescription ?? "unknown")")
            self.state = .failed
            self.audioPlayer = nil
        }
    }
}
