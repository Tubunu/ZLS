import Foundation
import Compression

public enum ZipArchiveError: Error {
    case compressionFailed
    case invalidEntryName
}

/// Zero-dependency PKZIP archive writer supporting Deflate (via Apple `Compression`) and Store fallback.
public struct ZipArchiveWriter {
    public struct Entry {
        public let fileName: String
        public let data: Data
        public let modificationDate: Date

        public init(fileName: String, data: Data, modificationDate: Date = Date()) {
            self.fileName = fileName
            self.data = data
            self.modificationDate = modificationDate
        }
    }

    public static func createArchive(entries: [Entry]) throws -> Data {
        var archive = Data()
        var centralDirectory = Data()

        for entry in entries {
            guard let nameData = entry.fileName.data(using: .utf8), !nameData.isEmpty else {
                throw ZipArchiveError.invalidEntryName
            }

            let crc = crc32(entry.data)
            let uncompressedSize = UInt32(entry.data.count)
            let compressed = deflateRaw(entry.data)
            let useDeflate = compressed != nil && compressed!.count < entry.data.count
            let payload = useDeflate ? compressed! : entry.data
            let compressionMethod: UInt16 = useDeflate ? 8 : 0
            let compressedSize = UInt32(payload.count)
            let (dosTime, dosDate) = dosDateTime(from: entry.modificationDate)

            let localHeaderOffset = UInt32(archive.count)

            // Local file header (30 bytes + name)
            archive.appendLE(UInt32(0x04034B50))
            archive.appendLE(UInt16(20)) // version needed: 2.0
            archive.appendLE(UInt16(0x0800)) // UTF-8 filename flag
            archive.appendLE(compressionMethod)
            archive.appendLE(dosTime)
            archive.appendLE(dosDate)
            archive.appendLE(crc)
            archive.appendLE(compressedSize)
            archive.appendLE(uncompressedSize)
            archive.appendLE(UInt16(nameData.count))
            archive.appendLE(UInt16(0)) // extra field length
            archive.append(nameData)
            archive.append(payload)

            // Central directory header (46 bytes + name)
            centralDirectory.appendLE(UInt32(0x02014B50))
            centralDirectory.appendLE(UInt16(20)) // version made by
            centralDirectory.appendLE(UInt16(20)) // version needed
            centralDirectory.appendLE(UInt16(0x0800)) // UTF-8 flag
            centralDirectory.appendLE(compressionMethod)
            centralDirectory.appendLE(dosTime)
            centralDirectory.appendLE(dosDate)
            centralDirectory.appendLE(crc)
            centralDirectory.appendLE(compressedSize)
            centralDirectory.appendLE(uncompressedSize)
            centralDirectory.appendLE(UInt16(nameData.count))
            centralDirectory.appendLE(UInt16(0)) // extra length
            centralDirectory.appendLE(UInt16(0)) // comment length
            centralDirectory.appendLE(UInt16(0)) // disk number start
            centralDirectory.appendLE(UInt16(0)) // internal file attributes
            centralDirectory.appendLE(UInt32(0)) // external file attributes
            centralDirectory.appendLE(localHeaderOffset)
            centralDirectory.append(nameData)
        }

        let centralOffset = UInt32(archive.count)
        let centralSize = UInt32(centralDirectory.count)
        archive.append(centralDirectory)

        // End of central directory record (22 bytes)
        archive.appendLE(UInt32(0x06054B50))
        archive.appendLE(UInt16(0)) // disk number
        archive.appendLE(UInt16(0)) // start disk
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(centralSize)
        archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0)) // comment length

        return archive
    }

    private static func deflateRaw(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        let destCapacity = max(64, input.count + 64)
        var dest = [UInt8](repeating: 0, count: destCapacity)
        let compressedCount = input.withUnsafeBytes { srcPtr -> Int in
            guard let base = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                &dest,
                destCapacity,
                base,
                input.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard compressedCount > 0 else { return nil }
        return Data(dest.prefix(compressedCount))
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB88320 & mask)
            }
        }
        return ~crc
    }

    private static func dosDateTime(from date: Date) -> (UInt16, UInt16) {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 2026) - 1980
        let month = c.month ?? 1
        let day = c.day ?? 1
        let hour = c.hour ?? 0
        let minute = c.minute ?? 0
        let second = (c.second ?? 0) / 2
        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        let dosDate = UInt16((year << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
