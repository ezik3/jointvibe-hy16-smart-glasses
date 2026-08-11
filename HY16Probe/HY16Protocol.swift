//
//  HY16Protocol.swift
//  HY16Probe
//
//  Minimal, verified implementation of the official HY-16 v2.0.17
//  Communication Protocol transport frame (A5 / CRC16), plus the
//  documented commands needed for: (1) 0x0D01 Device Control, value 8
//  (Take Photo), and (2) Pass 1 of media import - 0x090B (WiFi AP
//  Control) plus decoding of the notify commands the glasses send back
//  during that flow (0x0917 AP MAC, 0x0904 connection status, 0x090C
//  SSID, 0x090D password, 0x090E file-list API URL, 0x0916 file count).
//
//  Every byte layout and the CRC16 algorithm below were cross-checked
//  against the manufacturer's official "通信协议v2.0.17" document
//  (page 9 for the frame layout, page 46-54 for the WiFi/0x09xx family,
//  page 90 for 0x0D01, page 108-109 for the CRC16 reference table) AND
//  independently validated against real packets captured from the
//  physical HY-16 with PacketLogger (55/55 for the frame/CRC; the WiFi
//  sequence separately, during a real photo-import session).
//
//  This file defines: take-photo (0x0D01/8), start/stop video recording
//  (0x0D01/9 and 0x0D01/10 - same command family and frame shape as the
//  already-proven take-photo, per protocol doc page 90 §14.1), and WiFi
//  AP on/off (0x090B). Values 11/12 (audio recording), WiFi P2P
//  (0x0918-0x091B), video preview/RTSP (0x0908/0x090A), video-duration/
//  resolution config (0x091D/0x091E/0x0921/0x0922), and all OTA/delete/
//  reset commands are NOT defined anywhere here.
//

import Foundation
import CoreBluetooth

enum HY16Protocol {

    // MARK: Verified physical characteristics (from the physical probe + protocol doc, page 8)

    static let serviceUUID = CBUUID(string: "01000100-0000-2000-8000-009078563412")
    static let writeCharacteristicUUID = CBUUID(string: "03000300-0000-2000-8000-009278563412")
    static let notifyCharacteristicUUID = CBUUID(string: "02000200-0000-2000-8000-009178563412")

    // MARK: Command type byte (protocol doc, every command section)

    enum CommandType: UInt8 {
        case request = 1
        case response = 2
        case notify = 3
    }

    // MARK: The one command this file supports (protocol doc page 90, section 14.1)

    static let cmdDeviceControl: UInt16 = 0x0D01
    static let deviceControlTakePhoto: UInt8 = 0x08
    static let deviceControlStartVideo: UInt8 = 0x09
    static let deviceControlStopVideo: UInt8 = 0x0A
    // Deliberately NOT defined: 11 (start audio recording),
    // 12 (stop audio recording), or any OTA (0x0B0x) / delete
    // (0x0E02/0x0E03) command.

    /// Convenience: build the documented start/stop video recording frame.
    static func buildVideoControlFrame(start: Bool, sequence: UInt8) -> [UInt8] {
        let value = start ? deviceControlStartVideo : deviceControlStopVideo
        return buildFrame(cmdID: cmdDeviceControl, type: .request, sequence: sequence, payload: [value])
    }

    // MARK: WiFi AP control (protocol doc page 53, section 10.11)
    // Payload: single byte, 0 = off, 1 = on. Response is an empty ack.
    // Verified against captured traffic: real writes to this handle
    // used payload 0x01 to open and 0x00 to close.

    static let cmdWifiApControl: UInt16 = 0x090B

    /// Convenience: build the documented WiFi-AP-on or WiFi-AP-off request.
    static func buildWifiApControlFrame(on: Bool, sequence: UInt8) -> [UInt8] {
        buildFrame(cmdID: cmdWifiApControl, type: .request, sequence: sequence, payload: [on ? 0x01 : 0x00])
    }

    // MARK: CRC16 (CRC-16/ARC — poly 0x8005 reflected, init 0x0000)
    // Verified against the official doc's own published lookup table
    // (table[1] = 0xC0C1, table[2] = 0xC181, both matched exactly)
    // and against 55/55 real captured packets.

    static func crc16(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0x0000
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    // MARK: A5 frame encoder
    // A5 | LEN(2, LE) | DATA | CRC16(2, LE)
    // DATA = CMD_ID(2, LE) | TYPE(1) | SEQ(1) | PAYLOAD_LEN(2, LE) | PAYLOAD

    static func buildFrame(cmdID: UInt16, type: CommandType, sequence: UInt8, payload: [UInt8]) -> [UInt8] {
        var data: [UInt8] = []
        data.append(UInt8(cmdID & 0xFF))
        data.append(UInt8((cmdID >> 8) & 0xFF))
        data.append(type.rawValue)
        data.append(sequence)
        let payloadLen = UInt16(payload.count)
        data.append(UInt8(payloadLen & 0xFF))
        data.append(UInt8((payloadLen >> 8) & 0xFF))
        data.append(contentsOf: payload)

        var frame: [UInt8] = [0xA5]
        let dataLen = UInt16(data.count)
        frame.append(UInt8(dataLen & 0xFF))
        frame.append(UInt8((dataLen >> 8) & 0xFF))
        frame.append(contentsOf: data)

        let crc = crc16(frame) // scope = A5 + LEN + DATA (everything before the CRC)
        frame.append(UInt8(crc & 0xFF))
        frame.append(UInt8((crc >> 8) & 0xFF))
        return frame
    }

    /// Convenience: build the exact, documented "take photo" request frame.
    static func buildTakePhotoFrame(sequence: UInt8) -> [UInt8] {
        buildFrame(cmdID: cmdDeviceControl, type: .request, sequence: sequence, payload: [deviceControlTakePhoto])
    }

    // MARK: A5 frame decoder (for logging/decoding whatever the glasses send back)

    struct DecodedFrame {
        let cmdID: UInt16
        let type: UInt8
        let sequence: UInt8
        let payload: [UInt8]
        let crcValid: Bool
    }

    static func decodeFrame(_ bytes: [UInt8]) -> DecodedFrame? {
        guard bytes.count >= 5, bytes[0] == 0xA5 else { return nil }
        let length = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        let dataStart = 3
        let dataEnd = dataStart + Int(length)
        guard bytes.count >= dataEnd + 2 else { return nil }
        let data = Array(bytes[dataStart..<dataEnd])
        guard data.count >= 6 else { return nil }

        let cmdID = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let type = data[2]
        let sequence = data[3]
        let payloadLen = Int(UInt16(data[4]) | (UInt16(data[5]) << 8))
        let payload = payloadLen > 0 && data.count >= 6 + payloadLen ? Array(data[6..<(6 + payloadLen)]) : []

        let crcBytes = Array(bytes[dataEnd..<(dataEnd + 2)])
        let receivedCRC = UInt16(crcBytes[0]) | (UInt16(crcBytes[1]) << 8)
        let computedCRC = crc16(Array(bytes[0..<dataEnd]))

        return DecodedFrame(cmdID: cmdID, type: type, sequence: sequence, payload: payload, crcValid: receivedCRC == computedCRC)
    }

    static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Best-effort ASCII/UTF-8 decode for the string-payload notify
    /// commands (SSID, password, URL). Falls back to hex if the bytes
    /// aren't valid text, so nothing is ever silently dropped from the log.
    static func asciiString(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .ascii) ?? hexString(bytes)
    }

    static func commandName(_ cmdID: UInt16) -> String {
        switch cmdID {
        case 0x0D01: return "Device Control"
        case 0x0905: return "Pending File Count Update"
        case 0x0D02: return "Local Video Recording Status"
        case 0x090B: return "WiFi AP Control"
        case 0x0917: return "Report AP MAC Address"
        case 0x0904: return "Report Connection Status"
        case 0x090C: return "Report AP SSID"
        case 0x090D: return "Report AP Password"
        case 0x090E: return "Report WiFi Operation API URL"
        case 0x0916: return "Get Pending File Count"
        default: return String(format: "Unknown (0x%04X)", cmdID)
        }
    }

    static func typeName(_ type: UInt8) -> String {
        switch type {
        case 1: return "REQUEST"
        case 2: return "RESPONSE"
        case 3: return "NOTIFY"
        default: return "UNKNOWN(\(type))"
        }
    }
}
