//
//  AIService.swift
//  HY16Probe
//
//  JV AI conversational-response abstraction (approved pass). Deliberately
//  a single-method protocol: takes a transcript String in, returns a
//  response String (or error) out. No knowledge of CoreBluetooth, Opus,
//  Speech, or any glasses-specific type - this is the seam that lets a
//  future pass swap OpenRouter for DeepSeek/Kimi/Qwen/Gemini/OpenAI
//  direct/etc. by writing one new conforming type and changing one line
//  in ContentView.swift, with zero changes anywhere in the BLE/audio/
//  VAD/TTS stack.
//

import Foundation

protocol AIResponding {
    /// Sends `transcript` to the AI backend and returns its reply text
    /// (or an error) via `completion`, called on the main queue. Returns
    /// the underlying URLSessionDataTask (or nil, e.g. if the request
    /// couldn't even be constructed) so a caller can .cancel() it - added
    /// for barge-in (approved pass), so JVConversationController can
    /// cancel an in-flight LLM request the moment the wearer interrupts.
    /// A cancelled/any other-generation completion is still expected to
    /// fire; callers are responsible for ignoring stale results (see
    /// JVConversationController's turn-generation mechanism) - this
    /// method does not attempt to suppress the completion itself.
    @discardableResult
    func respond(to transcript: String, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask?
}
