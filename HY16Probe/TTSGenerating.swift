//
//  TTSGenerating.swift
//  HY16Probe
//
//  JV AI text-to-speech abstraction (approved pass). Mirrors AIResponding
//  exactly: takes text in, returns synthesized audio Data (or error) out.
//  No knowledge of CoreBluetooth, BLE, or any glasses-specific type. This
//  is the seam that lets a future pass swap VoiceStudio for Apple TTS,
//  ElevenLabs, or another provider by writing one new conforming type and
//  changing one line in ContentView.swift, with zero changes anywhere in
//  the BLE/audio-output stack (GlassesSpeakerTestController's proven
//  speak(_:) path is untouched by this abstraction entirely).
//

import Foundation

protocol TTSGenerating {
    /// Synthesizes `text` and returns audio Data (or an error) via
    /// `completion`, called on the main queue. The returned Data's format
    /// is the concrete implementation's choice to document/guarantee -
    /// VoiceStudioTTSService requests WAV specifically so callers can
    /// hand it directly to AVAudioPlayer with no conversion. Returns the
    /// underlying URLSessionDataTask (or nil, e.g. if unconfigured) so a
    /// caller can .cancel() it - added for barge-in (approved pass), same
    /// reasoning as AIResponding.respond(to:completion:)'s equivalent
    /// change: callers must ignore stale/cancelled completions themselves
    /// via their own turn-generation mechanism, not rely on this method
    /// to suppress them.
    @discardableResult
    func synthesize(text: String, completion: @escaping (Result<Data, Error>) -> Void) -> URLSessionDataTask?
}
