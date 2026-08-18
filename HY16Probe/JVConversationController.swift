//
//  JVConversationController.swift
//  HY16Probe
//
//  JV AI - continuous conversation + barge-in (approved pass). This is
//  the SINGLE orchestration point tying together JVSpeechTestController
//  (ASR/VAD), OpenRouterAIService (LLM), VoiceStudioTTSService (TTS), and
//  GlassesSpeakerTestController (playback) - replacing the ad-hoc
//  onFinalTranscript closure chain that previously lived directly in
//  ContentView.swift's .onAppear with one dedicated, testable class.
//
//  Completely isolated: no CoreBluetooth/Opus/Speech import, no knowledge
//  of BLEScanner/HY16Protocol/AudioCaptureController. Depends only on the
//  four controller TYPES above via their existing public methods/hooks -
//  never reaches into their internals. Does NOT modify the proven BLE
//  mic/Opus/VAD receive path, the proven 0x0805/0x0A02/0x0A03 handling,
//  or the proven speaker transport (AVAudioSession/.playback via
//  GlassesSpeakerTestController) in any way.
//
//  DEPENDENCY WIRING: constructed with ONLY a log closure (matching every
//  other controller's init signature in this project), then wired via
//  configure(...) called from ContentView's .onAppear - the one place
//  this project's own established convention (see ContentView.swift's
//  extensive comments on this) says is safe to reference self.xxx, the
//  REAL @StateObject-persisted controller instances, rather than
//  init()-local values that SwiftUI may discard on re-renders.
//
//  SIMULTANEOUS LISTENING DURING PLAYBACK (the "IMPORTANT HY-16 QUESTION"
//  from this milestone's brief) - PROVEN FROM SOURCE, not assumed:
//  JVSpeechTestController.receivePCMBuffer(_:) only processes buffers
//  while its OWN state == .listening; before this pass, a session ended
//  (state -> .idle) the moment a final transcript arrived, and nothing
//  restarted it until the user manually tapped START again - meaning ASR/
//  VAD were genuinely idle for the entire AI-thinking + TTS + playback
//  duration of every prior turn. The raw BLE mic pipeline itself
//  (BLEScanner -> AudioCaptureController -> onDecodedPCMBuffer) has ALWAYS
//  kept flowing regardless of ASR state - 0x0A02/0x0A03 have no knowledge
//  of JVSpeechTestController at all. So the limitation was ENTIRELY at
//  this app's own ASR-session-lifecycle layer, not a BLE/hardware one.
//  This file's fix: beginNewListeningSession() is called again
//  immediately after every final transcript (in continuous mode), so a
//  live ASR/VAD session is already running for the ENTIRE duration the AI
//  is thinking/speaking - this is what makes barge-in detection possible
//  at all, achieved additively, with ZERO changes to
//  JVSpeechTestController's own internal state machine.
//
//  ECHO SUPPRESSION (critical, per explicit instruction) - two
//  independent, disclosed, EXPERIMENTAL-STARTING-VALUE heuristics, no
//  arbitrary large blackout:
//    1. Content comparison: an interim transcript is treated as likely
//       echo (JV hearing its own speaker output) if it's very short OR is
//       a substring of the text JV is currently speaking. Real barge-in
//       speech is assumed to diverge from JV's own sentence quickly.
//    2. A SHORT (400ms) protection window applies ONLY to the faster,
//       riskier "sustained voice activity" trigger, only measured from
//       the moment playback begins - NOT applied to the interim-
//       transcript trigger, which is inherently slower/more deliberate
//       (real recognized words, not a raw amplitude spike) and is
//       primary/preferred per explicit instruction.
//  Whether the physical HY-16/BLE audio path provides any hardware/
//  firmware-level acoustic echo cancellation is UNKNOWN - not something
//  verifiable from this app's own source, not assumed either way.
//
//  STALE CALLBACK / GHOST SPEECH PREVENTION: a monotonically-incrementing
//  turnGeneration Int, incremented by interruptCurrentResponse() and by
//  startContinuousConversation(). Every LLM/TTS completion closure
//  captures the generation it was issued under and compares it against
//  the CURRENT generation before acting - a stale completion (including
//  one from a request we just called .cancel() on, since URLSession still
//  invokes the completion handler for a cancelled task) is discarded
//  unconditionally, regardless of whether it reports success or failure.
//  This is the exact mechanism preventing the described failure mode
//  ("Turn 1 request completes after Turn 2 has begun, and Turn 1 suddenly
//  speaks").
//

import Foundation

final class JVConversationController: ObservableObject {

    enum AIState {
        case idle
        case thinking
        case speaking

        var description: String {
            switch self {
            case .idle: return "Idle"
            case .thinking: return "Thinking"
            case .speaking: return "Speaking"
            }
        }
    }

    @Published private(set) var aiState: AIState = .idle

    private let log: (String) -> Void

    private weak var jvSpeechTest: JVSpeechTestController?
    private weak var aiService: OpenRouterAIService?
    private weak var voiceStudioTTS: VoiceStudioTTSService?
    private weak var glassesSpeakerTest: GlassesSpeakerTestController?
    private weak var latencySession: JVLatencySession?

    private var turnGeneration: Int = 0
    private var continuousModeActive: Bool = false
    private var currentLLMTask: URLSessionDataTask?
    private var currentTTSTask: URLSessionDataTask?
    private var aiSpeechStartDate: Date?
    private var currentSpokenText: String = ""

    // EXPERIMENTAL STARTING VALUES - see file header. Not proven HY-16/JV
    // constants; expected to need physical tuning, same disclosure
    // convention as this project's other experimental thresholds (e.g.
    // JVSpeechTestController's voiceRMSThreshold).
    private static let echoProtectionWindowSeconds: TimeInterval = 0.4
    private static let minimumInterimTranscriptLength = 4

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    /// Wires this controller's dependencies AND wires the other
    /// controllers' relevant hooks back to this controller's own
    /// handlers. Called from ContentView's .onAppear - see file header.
    /// Safe to call repeatedly (re-points to the same real instances,
    /// harmless), matching every other hook-wiring call in this project.
    func configure(
        jvSpeechTest: JVSpeechTestController,
        aiService: OpenRouterAIService,
        voiceStudioTTS: VoiceStudioTTSService,
        glassesSpeakerTest: GlassesSpeakerTestController,
        latencySession: JVLatencySession
    ) {
        self.jvSpeechTest = jvSpeechTest
        self.aiService = aiService
        self.voiceStudioTTS = voiceStudioTTS
        self.glassesSpeakerTest = glassesSpeakerTest
        self.latencySession = latencySession

        jvSpeechTest.onFinalTranscript = { [weak self] transcript in
            self?.handleFinalTranscript(transcript)
        }
        jvSpeechTest.onInterimTranscript = { [weak self] interim in
            self?.handleInterimTranscript(interim)
        }
        jvSpeechTest.onSustainedVoiceDetected = { [weak self] in
            self?.handleSustainedVoiceDetected()
        }
        jvSpeechTest.onLatencyCheckpoint = { [weak latencySession] name in
            latencySession?.record(name)
        }
        aiService.onLatencyCheckpoint = { [weak latencySession] name in
            latencySession?.record(name)
        }
        voiceStudioTTS.onLatencyCheckpoint = { [weak latencySession] name in
            latencySession?.record(name)
        }
        glassesSpeakerTest.onLatencyCheckpoint = { [weak latencySession] name in
            latencySession?.record(name)
        }
        // Playback-finished hook (approved pass) - resets aiState after a
        // NORMAL, successful playback completion. Fixes aiState
        // previously getting stuck at .speaking forever after every
        // uninterrupted turn (source-confirmed: startPlayback(_:) set
        // aiState = .speaking, but nothing ever reset it back except
        // interruptCurrentResponse/an LLM failure - neither of which
        // fires on ordinary success). Does not touch endpointing, LLM/TTS
        // requests, playback itself, or barge-in's actual interrupt
        // mechanism - purely a bookkeeping reset.
        glassesSpeakerTest.onPlaybackFinished = { [weak self] in
            self?.handlePlaybackFinished()
        }
    }

    /// Approved pass - see onPlaybackFinished wiring above. Guards on
    /// aiState == .speaking so a hook firing unexpectedly late (e.g. if a
    /// delegate callback landed after some other transition already
    /// happened) can never clobber a newer turn's state.
    private func handlePlaybackFinished() {
        guard aiState == .speaking else { return }
        log("JVConversation: playback finished normally - resetting aiState to idle")
        aiState = .idle
        aiSpeechStartDate = nil
        currentSpokenText = ""
    }

    // MARK: Continuous conversation entry points - only ever called from
    // an explicit user tap on START/STOP in ContentView's "JV AI - SPEECH
    // TEST" section.

    func startContinuousConversation() {
        guard !continuousModeActive else {
            log("JVConversation: startContinuousConversation() ignored - already active")
            return
        }
        continuousModeActive = true
        turnGeneration += 1
        log("JVConversation: continuous conversation mode STARTED (generation \(turnGeneration))")
        beginNewListeningSession()
    }

    func stopContinuousConversation() {
        guard continuousModeActive else {
            log("JVConversation: stopContinuousConversation() ignored - not active")
            return
        }
        continuousModeActive = false
        log("JVConversation: continuous conversation mode STOPPED")
        interruptCurrentResponse(reason: "user stopped conversation")
        jvSpeechTest?.stopListening(reason: "conversation mode stopped")
    }

    private func beginNewListeningSession() {
        latencySession?.startNewTurn()
        jvSpeechTest?.startListening()
    }

    // MARK: Turn handling

    private func handleFinalTranscript(_ transcript: String) {
        let myGeneration = turnGeneration
        log("JVConversation: final transcript for turn generation \(myGeneration): \"\(transcript)\"")
        log("JV BARGE-IN: new utterance committed - \"\(transcript)\"")

        // Immediately begin listening again for the NEXT turn / potential
        // barge-in - see file header. This is what makes mic/VAD/ASR run
        // continuously through the AI's thinking+speaking phase.
        if continuousModeActive {
            beginNewListeningSession()
        }

        aiState = .thinking
        currentSpokenText = ""
        currentLLMTask = aiService?.respond(to: transcript) { [weak self] result in
            guard let self, myGeneration == self.turnGeneration else {
                self?.log("JVConversation: ignoring stale LLM completion for generation \(myGeneration) (current is \(self?.turnGeneration ?? -1))")
                return
            }
            switch result {
            case .success(let reply):
                self.beginSpeaking(reply: reply, generation: myGeneration)
            case .failure:
                self.aiState = .idle
                self.glassesSpeakerTest?.speak("Sorry, I couldn't reach the AI service.")
            }
        }
    }

    private func beginSpeaking(reply: String, generation: Int) {
        guard generation == turnGeneration else { return }
        currentSpokenText = reply
        currentTTSTask = voiceStudioTTS?.synthesize(text: reply) { [weak self] ttsResult in
            guard let self, generation == self.turnGeneration else {
                self?.log("JVConversation: ignoring stale TTS completion for generation \(generation)")
                return
            }
            switch ttsResult {
            case .success(let audioData):
                self.startPlayback { self.glassesSpeakerTest?.playSynthesizedAudio(audioData) }
            case .failure:
                self.startPlayback { self.glassesSpeakerTest?.speak(reply) }
            }
        }
    }

    private func startPlayback(_ playAction: () -> Void) {
        aiState = .speaking
        aiSpeechStartDate = Date()
        log("JV BARGE-IN: AI/TTS playback began")
        playAction()
    }

    // MARK: Barge-in detection

    private func handleInterimTranscript(_ interim: String) {
        guard aiState == .speaking || aiState == .thinking else { return }
        log("JV BARGE-IN: interim transcript detected - \"\(interim)\"")
        if isLikelyEcho(interimTranscript: interim) {
            log("JV BARGE-IN: interruption rejected - reason: interim transcript looks like JV's own speech (\"\(interim)\")")
            return
        }
        log("JV BARGE-IN: interruption accepted - reason: credible interim transcript (\"\(interim)\")")
        interruptCurrentResponse(reason: "interim transcript: \"\(interim)\"")
    }

    private func handleSustainedVoiceDetected() {
        guard aiState == .speaking || aiState == .thinking else { return }
        log("JV BARGE-IN: wearer voice activity detected (sustained)")
        if let start = aiSpeechStartDate, Date().timeIntervalSince(start) < Self.echoProtectionWindowSeconds {
            log("JV BARGE-IN: interruption rejected - reason: within \(Self.echoProtectionWindowSeconds)s echo-protection window since playback began")
            return
        }
        log("JV BARGE-IN: interruption accepted - reason: sustained voice activity (fast trigger)")
        interruptCurrentResponse(reason: "sustained voice activity")
    }

    /// Echo-suppression heuristic 1 - see file header. Deliberately
    /// simple: too-short transcripts, or ones that are a substring of
    /// what JV is currently saying, are treated as likely self-hearing
    /// rather than a real interruption.
    private func isLikelyEcho(interimTranscript: String) -> Bool {
        let trimmed = interimTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumInterimTranscriptLength else { return true }
        guard !currentSpokenText.isEmpty else { return false }
        return currentSpokenText.localizedCaseInsensitiveContains(trimmed)
    }

    // MARK: Atomic interruption

    /// The single atomic operation handling everything required to
    /// prevent ghost speech - see file header for the full reasoning.
    private func interruptCurrentResponse(reason: String) {
        log("JV BARGE-IN: interruptCurrentResponse() - \(reason)")
        turnGeneration += 1
        log("JV BARGE-IN: AI request cancelled (turn generation now \(turnGeneration))")
        currentLLMTask?.cancel()
        currentLLMTask = nil
        log("JV BARGE-IN: TTS cancelled")
        currentTTSTask?.cancel()
        currentTTSTask = nil
        log("JV BARGE-IN: stop playback requested")
        glassesSpeakerTest?.stopImmediately()
        aiState = .idle
        aiSpeechStartDate = nil
        currentSpokenText = ""
        log("JV BARGE-IN: listening state restored")
        // No explicit jvSpeechTest?.startListening() here: in continuous
        // mode a session is ALREADY listening (started immediately after
        // the previous final transcript, per handleFinalTranscript above)
        // - the interrupting utterance is already being captured by it.
    }
}
