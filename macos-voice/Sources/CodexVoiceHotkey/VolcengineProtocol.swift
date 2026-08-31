import Compression
import Foundation

enum VolcengineEvent: Int32 {
    case startConnection = 1
    case finishConnection = 2
    case startSession = 100
    case finishSession = 102
    case taskRequest = 200
    case asrInfo = 450
    case asrResponse = 451
    case asrEnded = 459
}

struct VolcengineASRResult: Equatable {
    let text: String
    let isFinal: Bool
}

struct VolcenginePCMReplayBuffer {
    let byteLimit: Int
    private(set) var packets: [Data] = []
    private(set) var byteCount = 0
    private(set) var isComplete = true

    mutating func append(_ packet: Data) -> Bool {
        guard isComplete else { return false }
        guard byteCount + packet.count <= byteLimit else {
            isComplete = false
            packets.removeAll(keepingCapacity: false)
            byteCount = 0
            return false
        }
        packets.append(packet)
        byteCount += packet.count
        return true
    }
}

enum VolcengineInboundFrame: Equatable {
    case result(VolcengineASRResult)
    case serverError(code: Int32, message: String)

    static func parse(_ data: Data) throws -> VolcengineInboundFrame {
        guard data.count >= 8 else {
            throw VolcengineSpeechError.protocolFailure("响应短于 8 bytes")
        }
        let headerSize = Int(data[0] & 0x0f) * 4
        guard headerSize >= 4, data.count >= headerSize else {
            throw VolcengineSpeechError.protocolFailure("响应头长度无效")
        }
        let messageType = data[1] >> 4
        let flags = data[1] & 0x0f
        let compression = data[2] & 0x0f
        var offset = headerSize
        if flags & 0x01 != 0 {
            guard data.count >= offset + 4 else {
                throw VolcengineSpeechError.protocolFailure("响应缺少序号")
            }
            offset += 4
        }
        let isLast = flags & 0x02 != 0
        var event: VolcengineEvent = .asrResponse
        if flags & 0x04 != 0 {
            guard data.count >= offset + 4 else {
                throw VolcengineSpeechError.protocolFailure("响应缺少事件")
            }
            event = VolcengineEvent(rawValue: readInt32(data, at: offset)) ?? .asrResponse
            offset += 4
        }
        var serverErrorCode: Int32?
        if messageType == 0xf {
            guard data.count >= offset + 8 else {
                throw VolcengineSpeechError.protocolFailure("服务端错误响应不完整")
            }
            serverErrorCode = readInt32(data, at: offset)
            offset += 4
        }
        guard data.count >= offset + 4 else {
            throw VolcengineSpeechError.protocolFailure("响应缺少 payload 长度")
        }
        let payloadLength = Int(readInt32(data, at: offset))
        offset += 4
        guard payloadLength >= 0, data.count >= offset + payloadLength else {
            throw VolcengineSpeechError.protocolFailure("响应 payload 长度无效")
        }
        var payload = data.subdata(in: offset..<(offset + payloadLength))
        if compression == 1 {
            payload = try GzipCodec.decompress(payload)
        }
        if let serverErrorCode {
            return .serverError(
                code: serverErrorCode,
                message: String(data: payload, encoding: .utf8) ?? "<non-UTF8 payload>"
            )
        }
        return .result(
            try VolcengineFrame.parseResponse(payload, event: event, isLast: isLast)
        )
    }

    private static func readInt32(_ data: Data, at offset: Int) -> Int32 {
        Int32(bigEndian: data[offset..<offset + 4].withUnsafeBytes {
            $0.loadUnaligned(as: Int32.self)
        })
    }
}

struct VolcengineSessionGeneration: Equatable {
    fileprivate let rawValue: UInt64
}

struct VolcengineSessionTracker {
    private var nextGeneration: UInt64 = 0
    private(set) var activeGeneration: VolcengineSessionGeneration?

    mutating func begin() -> VolcengineSessionGeneration {
        nextGeneration &+= 1
        let generation = VolcengineSessionGeneration(rawValue: nextGeneration)
        activeGeneration = generation
        return generation
    }

    mutating func invalidate(_ generation: VolcengineSessionGeneration? = nil) {
        guard generation == nil || activeGeneration == generation else { return }
        activeGeneration = nil
    }

    func isActive(_ generation: VolcengineSessionGeneration) -> Bool {
        activeGeneration == generation
    }
}

enum VolcengineFrame {
    static func initialRequest(sequence: Int32, vocabulary: CustomVocabulary? = nil) throws -> Data {
        var requestObject: [String: Any] = [
            "model_name": "bigmodel",
            "enable_nonstream": true,
            "enable_itn": false,
            "enable_speaker_info": false,
            "enable_punc": false,
            "enable_ddc": false,
            "show_utterances": false,
            "result_type": "full",
        ]
        if let vocab = vocabulary, !vocab.hotwords.isEmpty {
            requestObject["customization"] = [
                "hot_word_list": vocab.hotwords.map { ["text": $0.key, "weight": $0.value] }
            ]
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "user": ["uid": "codex-voice"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": requestObject,
        ])
        let compressed = try GzipCodec.compress(payload)
        var frame = Data([0x11, 0x11, 0x11, 0x00])
        frame.append(contentsOf: be32(sequence))
        frame.append(contentsOf: be32(Int32(compressed.count)))
        frame.append(compressed)
        return frame
    }

    static func startConnection() throws -> Data {
        try eventFrame(type: 1, event: .startConnection, payload: Data("{}".utf8))
    }

    static func finishConnection() throws -> Data {
        try eventFrame(type: 1, event: .finishConnection, payload: Data())
    }

    static func startSession(sessionID: String, payload: Data) throws -> Data {
        var frame = eventFramePrefix(type: 1, event: .startSession)
        let id = Data(sessionID.utf8)
        frame.append(contentsOf: be32(Int32(id.count)))
        frame.append(id)
        appendPayload(payload, to: &frame)
        return frame
    }

    static func finishSession(sessionID: String) throws -> Data {
        var frame = eventFramePrefix(type: 1, event: .finishSession)
        let id = Data(sessionID.utf8)
        frame.append(contentsOf: be32(Int32(id.count)))
        frame.append(id)
        appendPayload(Data("{}".utf8), to: &frame)
        return frame
    }

    static func audio(_ audio: Data, sequence: Int32, sessionID: String = "", isFinal: Bool) throws -> Data {
        let compressed = try GzipCodec.compress(audio)
        var frame = Data([0x11, isFinal ? 0x23 : 0x21, 0x11, 0x00])
        frame.append(contentsOf: be32(isFinal ? -sequence : sequence))
        frame.append(contentsOf: be32(Int32(compressed.count)))
        frame.append(compressed)
        return frame
    }

    static func parseResponse(_ payload: Data, event: VolcengineEvent, isLast: Bool = false) throws -> VolcengineASRResult {
        guard event == .asrInfo || event == .asrResponse || event == .asrEnded else {
            throw VolcengineSpeechError.invalidResponse
        }
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:]
        let text = (object["text"] as? String) ?? (object["result"] as? [String: Any])?["text"] as? String ?? ""
        let isFinal = (object["is_final"] as? Bool) ?? isLast || event == .asrEnded
        return VolcengineASRResult(text: text, isFinal: isFinal)
    }

    private static func eventFrame(type: UInt8, event: VolcengineEvent, payload: Data) throws -> Data {
        var frame = eventFramePrefix(type: type, event: event)
        appendPayload(payload, to: &frame)
        return frame
    }

    private static func eventFramePrefix(type: UInt8, event: VolcengineEvent) -> Data {
        var frame = Data([0x14, (type << 4) | 0x04, 0x10, 0x00])
        frame.append(contentsOf: be32(event.rawValue))
        return frame
    }

    private static func appendPayload(_ payload: Data, to frame: inout Data) {
        frame.append(contentsOf: be32(Int32(payload.count)))
        frame.append(payload)
    }

    private static func be32(_ value: Int32) -> Data {
        Data([UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }
}

enum GzipCodec {
    static func compress(_ data: Data) throws -> Data {
        let capacity = max(data.count + 64, data.count * 2)
        var output = Data(count: capacity)
        let size = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard size > 6 else { throw VolcengineSpeechError.invalidResponse }
        // libcompression returns a raw DEFLATE stream. Wrap the complete stream
        // in gzip framing expected by the SAUC endpoint.
        var gzip = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
        gzip.append(output.prefix(size))
        gzip.append(contentsOf: crc32(data))
        gzip.append(contentsOf: le32(UInt32(data.count)))
        return gzip
    }

    static func decompress(_ data: Data) throws -> Data {
        guard data.count >= 18, data[0] == 0x1f, data[1] == 0x8b else { return data }
        var zlib = Data([0x78, 0x9c])
        zlib.append(data.subdata(in: 10..<(data.count - 8)))
        var output = Data(count: max(data.count * 8, 4096))
        let outputCapacity = output.count
        let size = output.withUnsafeMutableBytes { dst in
            zlib.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, outputCapacity, src.bindMemory(to: UInt8.self).baseAddress!, zlib.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard size > 0 else { throw VolcengineSpeechError.invalidResponse }
        return output.prefix(size)
    }

    private static func crc32(_ data: Data) -> Data {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return le32(~crc)
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
    }
}
