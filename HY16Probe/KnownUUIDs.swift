//
//  KnownUUIDs.swift
//  HY16Probe
//
//  Reference-only list of BLE UUIDs identified during static analysis of the
//  manufacturer's generic BES/Bestechnic SDK. Used ONLY to label matches in
//  the UI/log. Nothing in this file sends any data anywhere.
//

import CoreBluetooth

enum KnownUUIDs {

    /// UUID string (uppercase, as returned by CBUUID.uuidString) -> human label.
    static let labels: [String: String] = [
        "66666666-6666-6666-6666-666666666666": "BES OTA Service",
        "77777777-7777-7777-7777-777777777777": "BES OTA Characteristic",
        "86868686-8686-8686-8686-868686868686": "BES TOTA Service",
        "97979797-9797-9797-9797-979797979797": "BES TOTA Characteristic",
        "01000100-0000-1000-8000-009078563412": "BES BLE-WiFi Service",
        "03000300-0000-1000-8000-009278563412": "BES BLE-WiFi TX Characteristic",
        "02000200-0000-1000-8000-009178563412": "BES BLE-WiFi RX Characteristic",
        "65786365-6C70-6F69-6E74-2E636F820000": "BES SmartVoice Service",

        // Confirmed from the physical HY-16 probe AND the official
        // 通信协议 v2.0.17 document (page 8) — the real UUIDs this
        // device actually uses (the "2000" family, not the generic
        // SDK's "1000" family above).
        "01000100-0000-2000-8000-009078563412": "HY-16 Service (v2.0.17 confirmed)",
        "03000300-0000-2000-8000-009278563412": "HY-16 WRITE Characteristic (v2.0.17 confirmed)",
        "02000200-0000-2000-8000-009178563412": "HY-16 READ/NOTIFY Characteristic (v2.0.17 confirmed)",
    ]

    /// Returns a human-readable label if this UUID matches a known BES SDK
    /// UUID, or nil if it is unknown (i.e. possibly HY-16-specific).
    static func label(for uuid: CBUUID) -> String? {
        labels[uuid.uuidString.uppercased()]
    }
}
