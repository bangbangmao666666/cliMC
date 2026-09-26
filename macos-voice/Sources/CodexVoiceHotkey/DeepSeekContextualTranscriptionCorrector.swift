import Foundation

final class DeepSeekContextualTranscriptionCorrector: ContextualTranscriptionCorrecting {
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private struct Suggestion: Decodable {
        let source: String
        let replacement: String
    }

    private struct CorrectionPayload: Decodable {
        let corrections: [Suggestion]
    }

    private struct CompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        let choices: [Choice]
    }

    private let settings: DeepSeekSettings
    private let session: URLSession
    private let onResponse: (Bool, Int) -> Void
    private static let redirectSafeSession = URLSession(
        configuration: .ephemeral,
        delegate: RedirectBlocker(),
        delegateQueue: nil
    )

    init(
        settings: DeepSeekSettings,
        session: URLSession? = nil,
        onResponse: @escaping (Bool, Int) -> Void = { _, _ in }
    ) {
        self.settings = settings
        self.session = session ?? Self.redirectSafeSession
        self.onResponse = onResponse
    }

    func correct(_ text: String, knownTerms: [String], completion: @escaping (String) -> Void) {
        let terms = Array(Set(knownTerms.filter { !$0.isEmpty })).sorted()
        let input: [String: Any] = ["transcript": text, "known_terms": terms]
        guard let inputData = try? JSONSerialization.data(withJSONObject: input),
              let inputJSON = String(data: inputData, encoding: .utf8) else {
            onResponse(false, 0)
            completion(text)
            return
        }

        let body: [String: Any] = [
            "model": settings.model,
            "stream": false,
            "thinking": ["type": "disabled"],
            "max_tokens": 256,
            "response_format": ["type": "json_object"],
            "messages": [
                [
                    "role": "system",
                    "content": "你是中文语音识别纠错器。结合整句中文语境，重点检查中英混说的技术专名。known_terms 是用户词表中的标准名称：如果原文存在大小写变体、音近拼写或中文音译，且句意指向其中某个名称，就应返回局部纠错；不要机械替换语境不符的普通词。输出 JSON：{\"corrections\":[{\"source\":\"原文中连续出现的原样片段\",\"replacement\":\"标准名称\"}]}。source 必须逐字来自原文且只出现一次。只给局部替换，不改写其他内容；不确定时返回空数组，最多 5 项。"
                ],
                [
                    "role": "user",
                    "content": "请按系统规则检查这段最终语音转写，使用提供的标准术语列表：\n" + inputJSON
                ]
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            onResponse(false, 0)
            completion(text)
            return
        }
        guard let endpoint = Self.completionsURL(from: settings.baseURL) else {
            onResponse(false, 0)
            completion(text)
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 4.5
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = bodyData

        let session = self.session
        session.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let response = try? JSONDecoder().decode(CompletionResponse.self, from: data),
                  let content = response.choices.first?.message.content,
                  let resultData = content.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(CorrectionPayload.self, from: resultData) else {
                if let http = response as? HTTPURLResponse {
                    log("DeepSeek 上下文纠错失败（HTTP \(http.statusCode)），保留 ASR 原文。")
                } else if error != nil {
                    log("DeepSeek 上下文纠错请求失败，保留 ASR 原文。")
                }
                self.onResponse(false, 0)
                completion(text)
                return
            }

            var suggestions: [String: String] = [:]
            for suggestion in payload.corrections.prefix(5) {
                guard !suggestion.source.isEmpty,
                      !suggestion.replacement.isEmpty,
                      Self.occursExactlyOnce(suggestion.source, in: text) else { continue }
                suggestions[suggestion.source] = suggestion.replacement
            }
            let result = TranscriptionTextCorrector.applyWithCount(text, corrections: suggestions)
            self.onResponse(true, result.count)
            completion(result.text)
        }.resume()
    }

    private static func occursExactlyOnce(_ source: String, in text: String) -> Bool {
        let haystack = text as NSString
        let needle = source as NSString
        guard haystack.length > 0, needle.length > 0 else { return false }
        var searchRange = NSRange(location: 0, length: haystack.length)
        var count = 0
        while searchRange.location < haystack.length {
            let match = haystack.range(of: source, options: [.caseInsensitive], range: searchRange)
            guard match.location != NSNotFound else { break }
            count += 1
            if count > 1 { return false }
            searchRange = NSRange(location: NSMaxRange(match), length: haystack.length - NSMaxRange(match))
        }
        return count == 1
    }

    private static func completionsURL(from baseURL: String) -> URL? {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !value.isEmpty else { return nil }
        let endpoint = value.hasSuffix("/chat/completions") ? value : value + "/chat/completions"
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              scheme == "https" || (scheme == "http" && isLoopbackHost(host)) else { return nil }
        return url
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
    }
}
