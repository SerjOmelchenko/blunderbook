//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

enum ZipError: LocalizedError {
    case notAZipArchive
    case unsupportedCompression
    case encrypted
    case corrupt(String)
    case unsafeEntryName(String)
    case entryTooLarge(String)
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .notAZipArchive: return "That file is not a Blunderbook backup."
        case .unsupportedCompression: return "This backup uses an unsupported compression method."
        case .encrypted: return "Encrypted archives cannot be imported."
        case .corrupt(let detail): return "The backup is damaged: \(detail)"
        case .unsafeEntryName(let name): return "The backup contains an unsafe path: \(name)"
        case .entryTooLarge(let name): return "An entry in the backup is too large: \(name)"
        case .archiveTooLarge: return "The backup expands to more data than this app will accept."
        }
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Minimal ZIP reader and writer, stored entries only.
///
/// The app writes its own backups, so compression buys little and a store-only container keeps
/// the format auditable: there is no decompressor to turn a hostile archive into a zip bomb. A
/// backup that uses any other method is refused rather than partially trusted (§10).
enum ZipArchive {
    /// Per-entry ceiling. The §10 ten-megabyte limit is a limit on a single NDJSON *record* and
    /// is enforced while the records are streamed, not here.
    private static let maxEntryBytes = 2 * 1024 * 1024 * 1024
    private static let maxTotalBytes = 20 * 1024 * 1024 * 1024

    struct Entry {
        var name: String
        var data: Data
    }

    // MARK: - Writing

    static func write(entries: [Entry], to url: URL) throws {
        var output = Data()
        var central = Data()
        var offsets: [(name: String, offset: Int, crc: UInt32, size: Int)] = []

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let offset = output.count

            output.append(uint32: 0x0403_4B50)
            output.append(uint16: 20)
            output.append(uint16: 0)
            output.append(uint16: 0)            // stored
            output.append(uint16: 0)            // mod time
            output.append(uint16: 0x21)         // mod date (1980-01-01)
            output.append(uint32: crc)
            output.append(uint32: UInt32(entry.data.count))
            output.append(uint32: UInt32(entry.data.count))
            output.append(uint16: UInt16(nameBytes.count))
            output.append(uint16: 0)
            output.append(contentsOf: nameBytes)
            output.append(entry.data)

            offsets.append((entry.name, offset, crc, entry.data.count))
        }

        for record in offsets {
            let nameBytes = Array(record.name.utf8)
            central.append(uint32: 0x0201_4B50)
            central.append(uint16: 20)
            central.append(uint16: 20)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: 0x21)
            central.append(uint32: record.crc)
            central.append(uint32: UInt32(record.size))
            central.append(uint32: UInt32(record.size))
            central.append(uint16: UInt16(nameBytes.count))
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint32: 0)
            central.append(uint32: UInt32(record.offset))
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = output.count
        output.append(central)
        output.append(uint32: 0x0605_4B50)
        output.append(uint16: 0)
        output.append(uint16: 0)
        output.append(uint16: UInt16(offsets.count))
        output.append(uint16: UInt16(offsets.count))
        output.append(uint32: UInt32(central.count))
        output.append(uint32: UInt32(centralOffset))
        output.append(uint16: 0)

        try output.write(to: url, options: .atomic)
    }

    // MARK: - Reading

    static func read(url: URL) throws -> [Entry] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 22 else { throw ZipError.notAZipArchive }

        // Locate the end-of-central-directory record, scanning backwards over any comment.
        var eocd: Int?
        let lowerBound = max(0, data.count - 66_000)
        var index = data.count - 22
        while index >= lowerBound {
            if data.uint32(at: index) == 0x0605_4B50 { eocd = index; break }
            index -= 1
        }
        guard let eocd else { throw ZipError.notAZipArchive }

        let entryCount = Int(data.uint16(at: eocd + 10))
        let centralOffset = Int(data.uint32(at: eocd + 16))
        guard centralOffset < data.count else { throw ZipError.corrupt("central directory out of range") }

        var cursor = centralOffset
        var entries: [Entry] = []
        var totalBytes = 0

        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count, data.uint32(at: cursor) == 0x0201_4B50 else {
                throw ZipError.corrupt("bad central directory entry")
            }
            let flags = data.uint16(at: cursor + 8)
            if flags & 1 != 0 { throw ZipError.encrypted }
            let method = data.uint16(at: cursor + 10)
            let crc = data.uint32(at: cursor + 16)
            let compressedSize = Int(data.uint32(at: cursor + 20))
            let uncompressedSize = Int(data.uint32(at: cursor + 24))
            let nameLength = Int(data.uint16(at: cursor + 28))
            let extraLength = Int(data.uint16(at: cursor + 30))
            let commentLength = Int(data.uint16(at: cursor + 32))
            let localOffset = Int(data.uint32(at: cursor + 42))

            guard cursor + 46 + nameLength <= data.count else { throw ZipError.corrupt("bad entry name") }
            let name = String(decoding: data[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            guard method == 0 else { throw ZipError.unsupportedCompression }
            guard isSafeName(name) else { throw ZipError.unsafeEntryName(name) }
            guard uncompressedSize <= maxEntryBytes else { throw ZipError.entryTooLarge(name) }
            totalBytes += uncompressedSize
            guard totalBytes <= maxTotalBytes else { throw ZipError.archiveTooLarge }

            guard localOffset + 30 <= data.count, data.uint32(at: localOffset) == 0x0403_4B50 else {
                throw ZipError.corrupt("bad local header for \(name)")
            }
            let localNameLength = Int(data.uint16(at: localOffset + 26))
            let localExtraLength = Int(data.uint16(at: localOffset + 28))
            let start = localOffset + 30 + localNameLength + localExtraLength
            let end = start + compressedSize
            guard end <= data.count else { throw ZipError.corrupt("truncated entry \(name)") }

            let payload = data.subdata(in: start..<end)
            guard CRC32.checksum(payload) == crc else { throw ZipError.corrupt("checksum mismatch in \(name)") }
            entries.append(Entry(name: name, data: payload))

            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Rejects absolute paths, traversal, drive letters and deep nesting before anything is read.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        guard !name.hasPrefix("/"), !name.hasPrefix("\\"), !name.contains("..") else { return false }
        guard !name.contains(":"), !name.contains("\0") else { return false }
        return name.split(separator: "/").count <= 3
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(uint32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    func uint16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[startIndex + offset])
            | (UInt32(self[startIndex + offset + 1]) << 8)
            | (UInt32(self[startIndex + offset + 2]) << 16)
            | (UInt32(self[startIndex + offset + 3]) << 24)
    }
}
