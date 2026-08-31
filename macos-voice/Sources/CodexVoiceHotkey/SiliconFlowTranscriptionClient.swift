import Foundation

enum SiliconFlowTranscriptionError: LocalizedError {
    case missingAPIKey
    case emptyAudio
    case invalidResponse
    case httpFailure(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "SiliconFlow API Key 不能为空。"
        case .emptyAudio:
            return "录音为空，请按住快捷键后再说话。"
        case .invalidResponse:
            return "SiliconFlow 没有返回可用文本。"
        case let .httpFailure(statusCode, body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "SiliconFlow 转写失败（HTTP \(statusCode)），服务端没有返回错误详情。"
            }
            return "SiliconFlow 转写失败（HTTP \(statusCode)）：\(detail)"
        }
    }
}

final class SiliconFlowTranscriptionClient {
    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(
        baseURL: String,
        apiKey: String,
        model: String,
        session: URLSession = .shared
    ) {
        self.baseURL = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ?? URL(string: "https://api.siliconflow.cn/v1")!
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func transcribe(fileURL: URL, filename: String, contentType: String? = nil) async throws -> String {
        let data = try Data(contentsOf: fileURL)
        return try await transcribe(data: data, filename: filename, contentType: contentType)
    }

    func transcribe(data: Data, filename: String, contentType: String? = nil) async throws -> String {
        guard !apiKey.isEmpty else { throw SiliconFlowTranscriptionError.missingAPIKey }
        guard !data.isEmpty else { throw SiliconFlowTranscriptionError.emptyAudio }

        let boundary = "----codexvoice" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = multipartBody(boundary: boundary, filename: filename, data: data, contentType: contentType ?? "audio/wav")
        log("开始远程转写：\(request.url?.absoluteString ?? "未知地址")，音频 \(data.count) bytes。")

        let (responseData, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        guard httpResponse?.statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            let statusCode = httpResponse?.statusCode ?? -1
            log("远程转写失败：HTTP \(statusCode)，响应 \(body.isEmpty ? "为空" : body)。")
            throw SiliconFlowTranscriptionError.httpFailure(statusCode: statusCode, body: body)
        }
        let payload = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        let text = payload?["text"] as? String
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw SiliconFlowTranscriptionError.invalidResponse }
        return trimmed
    }

    private func multipartBody(boundary: String, filename: String, data: Data, contentType: String) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
