import Compression
import Foundation

/// Decodes `ZICNOTEDATA.ZDATA` into plaintext + best-effort HTML.
///
/// Format (forensic community reverse-engineered, stable across macOS 10.11+):
///   gzip(protobuf NotesStoreProto)
///
/// NotesStoreProto wraps a Document → Data message, whose field 2 is the UTF-8
/// text string of the note. Other fields carry attribute runs (bold, italic,
/// link, list, checklist, attachments).
///
/// v0.1.0 strategy: walk the protobuf tree scanning for length-delimited fields,
/// pick the longest UTF-8 string as the plain text. Robust to minor schema
/// drift at the cost of not rendering attribute runs. HTML output is the
/// plaintext wrapped in `<div>` with newlines converted to `<br>`.
///
/// v0.2.0 TODO: structured decode following the apple_cloud_notes_parser
/// reference schema to produce proper `<b>`, `<i>`, `<a>`, `<ul>` HTML.
enum NoteProtobufDecoder {

    static func decode(_ blob: Data) throws -> (text: String, html: String) {
        let inflated = try gunzip(blob)
        let text = extractLongestString(inflated) ?? ""
        return (text, BodyHTMLRenderer.plaintextToHTML(text))
    }

    // MARK: - Gzip

    static func gunzip(_ data: Data) throws -> Data {
        // gzip magic 1F 8B
        guard data.count >= 2, data[0] == 0x1F, data[1] == 0x8B else {
            // Already plain protobuf (rare — some older notes).
            return data
        }

        // Allocate an output buffer heuristically sized; compressed body is
        // rarely over 20×, but we retry with larger buffer on overflow.
        var destSize = max(data.count * 20, 256 * 1024)
        for _ in 0..<4 {
            if let out = inflate(data, destSize: destSize) {
                return out
            }
            destSize *= 4
        }
        throw NotesSQLiteError.decodeFailed("gzip inflate failed after retries")
    }

    private static func inflate(_ data: Data, destSize: Int) -> Data? {
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: destSize)
        defer { dst.deallocate() }

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let written = compression_decode_buffer(
                dst, destSize,
                src, data.count,
                nil,
                COMPRESSION_ZLIB
            )
            guard written > 0 else { return nil }
            return Data(bytes: dst, count: written)
        // ZLIB decoder expects raw deflate, but gzip has a header + trailer:
        // on failure, retry with the gzip framing stripped.
        } ?? tryRawDeflate(data, destSize: destSize)
    }

    /// Skip gzip header (10 bytes + optional fields) and feed raw deflate to Compression.
    private static func tryRawDeflate(_ data: Data, destSize: Int) -> Data? {
        guard data.count > 18 else { return nil }
        let headerLen = gzipHeaderLength(data) ?? 10
        guard headerLen < data.count - 8 else { return nil }
        let trailerLen = 8
        let payload = data.subdata(in: headerLen..<(data.count - trailerLen))

        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: destSize)
        defer { dst.deallocate() }

        return payload.withUnsafeBytes { raw -> Data? in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let written = compression_decode_buffer(
                dst, destSize,
                src, payload.count,
                nil,
                COMPRESSION_ZLIB
            )
            guard written > 0 else { return nil }
            return Data(bytes: dst, count: written)
        }
    }

    /// Return full gzip header length (minimum 10, plus any FEXTRA/FNAME/FCOMMENT/FHCRC fields).
    private static func gzipHeaderLength(_ data: Data) -> Int? {
        guard data.count >= 10, data[0] == 0x1F, data[1] == 0x8B else { return nil }
        let flags = data[3]
        var offset = 10

        // FEXTRA
        if flags & 0x04 != 0 {
            guard offset + 2 <= data.count else { return nil }
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
        }
        // FNAME
        if flags & 0x08 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FCOMMENT
        if flags & 0x10 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FHCRC
        if flags & 0x02 != 0 {
            offset += 2
        }
        return offset
    }

    // MARK: - Protobuf scan

    /// Walk the protobuf structure collecting all UTF-8 strings (length-delimited
    /// fields that validate as UTF-8), recursing into sub-messages. Returns the
    /// longest one, which is the note body text.
    static func extractLongestString(_ buf: Data) -> String? {
        let strings = collectStrings(buf)
        // Filter out short "noise" strings — but keep if it's the only candidate.
        let candidates = strings.filter { $0.count > 2 }
        return candidates.max(by: { $0.count < $1.count }) ?? strings.max(by: { $0.count < $1.count })
    }

    private static func collectStrings(_ buf: Data, depth: Int = 0) -> [String] {
        guard depth < 16 else { return [] }  // protect against malformed pb
        var result: [String] = []
        var i = 0
        while i < buf.count {
            guard let (tag, next1) = readVarint(buf, at: i) else { break }
            let wireType = Int(tag & 0x07)
            i = next1

            switch wireType {
            case 0:  // varint
                guard let (_, next) = readVarint(buf, at: i) else { return result }
                i = next
            case 1:  // 64-bit
                i += 8
                if i > buf.count { return result }
            case 2:  // length-delimited
                guard let (len, next2) = readVarint(buf, at: i) else { return result }
                i = next2
                let end = i + Int(len)
                guard end <= buf.count, Int(len) >= 0 else { return result }
                let chunk = buf.subdata(in: i..<end)
                if let str = String(data: chunk, encoding: .utf8),
                   isLikelyText(str)
                {
                    result.append(str)
                }
                // Also recurse — this could be a sub-message containing more strings
                result.append(contentsOf: collectStrings(chunk, depth: depth + 1))
                i = end
            case 5:  // 32-bit
                i += 4
                if i > buf.count { return result }
            default:
                return result
            }
        }
        return result
    }

    private static func readVarint(_ buf: Data, at start: Int) -> (UInt64, Int)? {
        var i = start
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while i < buf.count {
            let b = buf[i]
            value |= UInt64(b & 0x7F) << shift
            i += 1
            if b & 0x80 == 0 {
                return (value, i)
            }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    /// Return true if the string looks like note text (letters, punctuation,
    /// whitespace — reject mostly-control-char or all-hex-looking noise).
    private static func isLikelyText(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var printable = 0
        var control = 0
        for ch in s.unicodeScalars {
            if ch.value == 0x0A || ch.value == 0x0D || ch.value == 0x09 || (ch.value >= 0x20 && ch.value <= 0x10FFFF) {
                printable += 1
            } else if ch.value < 0x20 {
                control += 1
            }
        }
        // Heuristic: at least 70% printable and not all single-char repeats
        let total = printable + control
        guard total > 0 else { return false }
        return Double(printable) / Double(total) >= 0.7
    }
}
