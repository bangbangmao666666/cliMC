import XCTest
@testable import CodexVoiceHotkey

final class SiliconFlowTranscriptionClientTests: XCTestCase {
    func testTranscribeUsesConfiguredBaseURLModelAndAPIKey() async throws {
        MockURLProtocol.reset()
        let session = URLSession(configuration: Self.makeConfiguration())
        let client = SiliconFlowTranscriptionClient(
            baseURL: "https://example.com/v1",
            apiKey: "secret-key",
            model: "demo-model",
            session: session
        )
        MockURLProtocol.responseData = #"{"text":"你好"}"#.data(using: .utf8)

        let result = try await client.transcribe(
            data: Data("audio".utf8),
            filename: "speech.wav",
            contentType: "audio/wav"
        )

        XCTAssertEqual(result, "你好")
        XCTAssertEqual(MockURLProtocol.capturedRequest?.url?.absoluteString, "https://example.com/v1/audio/transcriptions")
        XCTAssertEqual(MockURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertTrue(MockURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
        let body = String(data: MockURLProtocol.requestBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("name=\"model\""))
        XCTAssertTrue(body.contains("demo-model"))
        XCTAssertTrue(body.contains("speech.wav"))
    }

    func testTranscribeRejectsEmptyAudio() async throws {
        let client = SiliconFlowTranscriptionClient(
            baseURL: "https://example.com/v1",
            apiKey: "secret-key",
            model: "demo-model"
        )

        do {
            _ = try await client.transcribe(data: Data(), filename: "speech.wav")
            XCTFail("Expected empty audio to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("录音为空"))
        }
    }

    func testTranscribeReportsHTTPStatusWhenServerReturnsEmptyError() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseStatusCode = 401
        let session = URLSession(configuration: Self.makeConfiguration())
        let client = SiliconFlowTranscriptionClient(
            baseURL: "https://example.com/v1",
            apiKey: "secret-key",
            model: "demo-model",
            session: session
        )

        do {
            _ = try await client.transcribe(data: Data("audio".utf8), filename: "speech.wav")
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 401"))
        }
    }

    private static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return configuration
    }
}

final class MockURLProtocol: URLProtocol {
    static var requestBody: Data?
    static var responseData: Data?
    static var responseStatusCode = 200
    static var capturedRequest: URLRequest?

    static func reset() {
        requestBody = nil
        responseData = nil
        responseStatusCode = 200
        capturedRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequest = self.request
        Self.requestBody = Self.bodyData(from: self.request)
        let response = HTTPURLResponse(
            url: self.request.url!,
            statusCode: Self.responseStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData ?? Data(#"{"text":"mock"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody {
            return httpBody
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
