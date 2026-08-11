//
//  Models.swift
//  HY16Probe
//
//  Plain data structs used to display scan/discovery results.
//  No networking, no persistence, no Bluetooth calls in this file.
//

import Foundation
import CoreBluetooth

/// A peripheral seen during a scan.
struct DiscoveredPeripheral: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var isHY16: Bool
    var lastSeen: Date
}

/// One characteristic discovered on a connected peripheral, with its
/// capability flags read from CBCharacteristic.properties. This is a
/// read-only snapshot; nothing here triggers any Bluetooth traffic.
struct CharacteristicInfo: Identifiable {
    let id = UUID()
    let uuid: String
    let canRead: Bool
    let canWrite: Bool
    let canWriteWithoutResponse: Bool
    let canNotify: Bool
    let canIndicate: Bool
    let knownLabel: String?
}

/// One service discovered on a connected peripheral, plus its characteristics.
struct ServiceInfo: Identifiable {
    let id = UUID()
    let uuid: String
    let knownLabel: String?
    var characteristics: [CharacteristicInfo] = []
}

// MARK: - Glass media file list (Pass 2a)
//
// Exact Codable mirror of the REAL JSON confirmed from the physical
// HY-16's http://192.168.96.1/api/glass/file-list response:
//   { "files": [ { "name": "...", "size": 123, "url": "/images/...",
//                  "thumbnail": "/images/..." }, ... ] }
// Not a guessed shape - this matches the captured response field-for-field.

struct GlassFileListResponse: Codable {
    let files: [GlassFile]
}

struct GlassFile: Codable, Identifiable {
    let name: String
    let size: Int
    let url: String
    let thumbnail: String

    var id: String { name }

    /// Media type, determined from the file EXTENSION only (per the
    /// physically-confirmed finding that the glasses report a real MP4
    /// with Content-Type "application/octet-stream" - HTTP Content-Type
    /// cannot be trusted as the type indicator, the extension can).
    var mediaKind: GlassMediaKind {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic":
            return .photo
        case "mp4", "mov", "m4v":
            return .video
        default:
            return .unknown
        }
    }
}

enum GlassMediaKind {
    case photo
    case video
    case unknown
}
