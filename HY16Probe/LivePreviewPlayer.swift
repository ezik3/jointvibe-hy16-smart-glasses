//
//  LivePreviewPlayer.swift
//  HY16Probe
//
//  Isolated RTSP live-preview player (approved test pass). Wraps VideoLAN's
//  own official VLCKit SPM distribution (code.videolan.org/videolan/VLCKit,
//  tag 4.0.0-a23, alpha - tracks VLC core's rewritten clock architecture,
//  which structurally removes the fixed-3-second video timestamp rejection
//  that a prior pass traced as the cause of frozen playback under VLCKit
//  3.6.0/VLC 3.0.x's unchanged clock code) - the only third-party
//  dependency in this project. Chosen because AVPlayer/AVKit has no RTSP
//  support on iOS, and FFmpegKit was retired in 2025.
//
//  This file NEVER hardcodes an RTSP URL. start(urlString:) only ever
//  receives whatever BLEScanner.previewAddress actually decoded from a
//  real 0x0908 notify sent by the physical glasses (wired in ContentView
//  via onChange(of: scanner.previewAddress)). It is completely separate
//  from the existing AVPlayer used for downloaded local MP4 playback
//  (BLEScanner.videoPlayer / downloadVideo(_:)) - that code is untouched.
//
//  No BLE code lives here. This file only ever opens a network stream in
//  response to an address the device itself already reported.
//

import Foundation
import UIKit
import SwiftUI
import VLCKit

enum LivePreviewStatus: Equatable {
    case waitingForAddress
    case connecting
    case playing
    case stopped
    case error(String)

    var label: String {
        switch self {
        case .waitingForAddress: return "Waiting for address…"
        case .connecting: return "Connecting…"
        case .playing: return "Playing"
        case .stopped: return "Stopped"
        case .error(let message): return "Error: \(message)"
        }
    }
}

final class LivePreviewController: NSObject, ObservableObject {

    @Published var status: LivePreviewStatus = .waitingForAddress
    @Published var currentURLString: String?

    private var player: VLCMediaPlayer?
    private let log: (String) -> Void

    // The one UIView VLCPlayerView.makeUIView() creates, remembered here so
    // start() can bind it to a newly-created VLCMediaPlayer deterministically
    // BEFORE calling play() - fixes a real attachment race where .drawable
    // was previously only ever set as an indirect side effect of SwiftUI's
    // updateUIView, with no guarantee it ran before playback began.
    private var hostView: UIView?

    init(log: @escaping (String) -> Void) {
        self.log = log
        super.init()
        // DIAGNOSTIC (this test pass only): route libVLC's own internal
        // module/decoder/demux log lines to the console via VLCKit's
        // current, non-deprecated logging API, so we can see which decoder
        // module actually opens and any SPS/PPS parser warnings - detail
        // no VLCMediaPlayer property exposes. Verbose/noisy by design;
        // revisit once the video-decode question is settled.
        VLCLibrary.shared().loggers = [VLCConsoleLogger()]
    }

    /// Validates the address is actually an rtsp:// URL before doing
    /// anything - never assumes, never falls back to a guessed address.
    func start(urlString: String) {
        guard urlString.lowercased().hasPrefix("rtsp://"), let url = URL(string: urlString) else {
            log("LivePreview: REJECTED - \"\(urlString)\" is not a valid rtsp:// URL, not attempting playback")
            status = .error("Not a valid rtsp:// URL")
            return
        }

        stopPlayerOnly() // tear down any previous session first, no state-reset log spam

        currentURLString = urlString
        status = .connecting
        log("LivePreview: opening \(urlString)")

        // VLCKit 4.0.0-a23's initWithURL: is `nullable` (unlike 3.6.0's
        // non-optional initializer) - handle a genuine construction failure
        // explicitly rather than force-unwrapping.
        guard let media = VLCMedia(url: url) else {
            log("LivePreview: REJECTED - VLCMedia(url:) returned nil for \(urlString)")
            status = .error("Could not construct VLCMedia for this URL")
            return
        }
        // Embedded RTSP servers on camera hardware very often only speak
        // TCP-interleaved, not UDP RTP - force TCP, and use a conservative
        // low-latency cache suited to a LIVE preview (not a scrubbable file).
        media.addOption(":rtsp-tcp")
        media.addOption(":network-caching=300")
        // DIAGNOSTIC (this test pass only): verified real libVLC option
        // (modules/codec/videotoolbox.m, add_bool("videotoolbox", true, ...))
        // - forces VLC to skip its VideoToolbox hardware decoder module and
        // fall back to its FFmpeg software H.264 decoder, to test whether
        // the black screen / -12903 is specific to hardware decode.
        media.addOption(":no-videotoolbox")
        // DIAGNOSTIC (this test pass only): verified real libVLC option
        // (src/input/input.c: `if var_GetInteger(p_input,"clock-synchro") != -1
        // then b_can_pace_control = !var_GetInteger(...)`). 0 = "Disable" per
        // libvlc-module.c's own description: "It is possible to disable the
        // input clock synchronisation for real-time sources. Use this if you
        // experience jerky playback of network streams." Forces
        // b_can_pace_control=true, which skips VLC's continuous stream/system
        // drift-averaging (src/input/clock.c's AvgUpdate on cl->drift) rather
        // than tuning the fixed 3s video timestamp bound itself (confirmed
        // not configurable by any option) - tests whether a frozen, simpler
        // reference mapping passes that bound consistently instead.
        media.addOption(":clock-synchro=0")

        // VLCKit 4.0.0-a23 has no plain parameterless init - initWithOptions:
        // (empty array here) is the documented equivalent.
        let newPlayer = VLCMediaPlayer(options: [])
        newPlayer.delegate = self
        newPlayer.media = media
        // Deterministic attach - assigned exactly ONCE here, before
        // play(), and never reassigned afterward (VLCPlayerView.updateUIView
        // is a no-op - see below). Previously this was reassigned on every
        // SwiftUI recompute via updateUIView, which is a plausible source
        // of repeated buffer-reset churn in VLCKit's GLES2 vout.
        newPlayer.drawable = hostView
        log("LivePreview: drawable assigned to newPlayer exactly once, before play() - hostView present=\(hostView != nil)")
        self.player = newPlayer
        newPlayer.play()
    }

    /// Explicit stop, called from the Stop Live Preview button and from
    /// onDisappear - both are SwiftUI call sites, always on the main
    /// thread already, so no additional dispatch is needed here (adding
    /// one would just be redundant, not safer).
    func stop() {
        stopPlayerOnly()
        status = .stopped
        currentURLString = nil
    }

    private func stopPlayerOnly() {
        if let player {
            log("LivePreview: stopping player")
            player.stop()
        }
        player = nil
    }

    /// Diagnostic-only: logs whether libVLC believes it has an actual video
    /// output attached (hasVideoOut), the decoded frame size (videoSize),
    /// and per-track codec/resolution info (tracksInformation) - lets us
    /// tell apart "no rendering surface attached" from "no video track/
    /// codec found" instead of guessing from the black screen alone.
    private func logVideoDiagnostics(_ player: VLCMediaPlayer) {
        log("LivePreview: hasVideoOut=\(player.hasVideoOut) videoSize=\(player.videoSize)")
        if let tracks = player.media?.tracksInformation {
            log("LivePreview: tracksInformation = \(tracks)")
        } else {
            log("LivePreview: tracksInformation = (none available yet)")
        }
    }

    /// Called ONCE by VLCPlayerView.makeUIView() when the render surface is
    /// first created. Only stores the view - deliberately does NOT touch
    /// .drawable here. At this point no player exists yet anyway (start()
    /// hasn't run), and .drawable is now assigned exactly once, inside
    /// start(), before play() - never reassigned afterward.
    func registerHostView(_ view: UIView) {
        hostView = view
    }

    /// Diagnostic-only (this test pass): called from
    /// VLCPlayerView.updateUIView() to confirm, in the log, that SwiftUI
    /// recomputes are NOT causing the drawable to be reassigned.
    func logUpdateUIViewNoOp() {
        log("LivePreview: updateUIView called (SwiftUI recompute) - drawable NOT reassigned (no-op by design)")
    }
}

extension LivePreviewController: VLCMediaPlayerDelegate {
    // VERIFIED from VLCKit 3.6.0 source (VLCEventsHandler.m); the same
    // events-handler dispatch mechanism is present in 4.0.0-a23. Unless
    // VLCLibrary.sharedEventsConfiguration is explicitly set (we don't set
    // it), this delegate method fires SYNCHRONOUSLY on libVLC's own
    // internal event thread, NOT the main thread. Every @Published mutation
    // (status, currentURLString) and every log(...) call (which appends to
    // BLEScanner's @Published logLines via the closure from ContentView)
    // must therefore be bridged onto the main queue explicitly - a plain
    // @MainActor on this class would NOT do this for us, since the call
    // arrives from Objective-C/libVLC, not from Swift-async code.
    //
    // VLCKit 4.0.0-a23 signature change (verified from the real header,
    // Headers/Public/Playback/VLCMediaPlayer.h): takes VLCMediaPlayerState
    // directly, not NSNotification. The enum itself also changed - 3.6.0's
    // Buffering and ESAdded cases no longer exist; 4.0.0-a23 has only
    // NothingSpecial, Opening, Playing, Paused, Stopped, Stopping, Error.
    func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        let firedOnMainThread = Thread.isMainThread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.log("LivePreview: delegate fired on \(firedOnMainThread ? "MAIN" : "BACKGROUND") thread; state mutation now running on MAIN=\(Thread.isMainThread)")
            guard let player = self.player else { return }
            switch newState {
            case .nothingSpecial:
                self.log("LivePreview: VLC state = nothingSpecial")
            case .opening:
                self.status = .connecting
                self.log("LivePreview: VLC state = opening")
            case .playing:
                self.status = .playing
                self.log("LivePreview: VLC state = playing")
                self.logVideoDiagnostics(player)
            case .paused:
                self.log("LivePreview: VLC state = paused")
            case .stopped:
                self.log("LivePreview: VLC state = stopped")
            case .stopping:
                self.log("LivePreview: VLC state = stopping")
            case .error:
                self.status = .error("VLC playback error - check log above for the last state before this (transport/codec/network)")
                self.log("LivePreview: VLC state = error")
            @unknown default:
                self.log("LivePreview: VLC state = unknown(\(newState.rawValue))")
            }
        }
    }
}

/// UIKit bridge - VLCMediaPlayer renders into a plain UIView via `.drawable`.
struct VLCPlayerView: UIViewRepresentable {
    let controller: LivePreviewController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        controller.registerHostView(view)
        return view
    }

    /// Intentionally a no-op beyond diagnostic logging. The render surface
    /// is registered once in makeUIView and bound to a player exactly once
    /// in start(), before play(). Previously this reassigned .drawable on
    /// every SwiftUI recompute (which happens on every VLC state change,
    /// since those changes publish @Published state this view depends on)
    /// - the strongest identified explanation for "one frame then frozen."
    func updateUIView(_ uiView: UIView, context: Context) {
        controller.logUpdateUIViewNoOp()
    }
}
