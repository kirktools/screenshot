import Foundation
import XCTest
@testable import KirkTranslation

final class ChatGPTPlanTests: XCTestCase {
    @MainActor func testCallbackRequiresTheRightPathAndUniqueState() {
        func request(_ path: String) -> Data { Data("GET \(path) HTTP/1.1\r\n\r\n".utf8) }
        let callback = ChatGPTLoopback.callback(request("/auth/callback?code=example&state=expected"), state: "expected")
        XCTAssertEqual(callback?.queryItems?.first?.value, "example")
        XCTAssertNil(ChatGPTLoopback.callback(request("/auth/callback?state=wrong"), state: "expected"))
        XCTAssertNil(ChatGPTLoopback.callback(request("/auth/callback?state=expected&state=expected"), state: "expected"))
        XCTAssertNil(ChatGPTLoopback.callback(request("/other?state=expected"), state: "expected"))
    }

    @MainActor func testOnlyCompletedTranslationsAreReturned() throws {
        let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"译文\"}\r\n\r\n"
        let completed = "data: {\"type\":\"response.completed\"}\r\n\r\n"
        XCTAssertEqual(try ChatGPTPlan.translation(from: Data((delta + completed).utf8)), "译文")
        XCTAssertThrowsError(try ChatGPTPlan.translation(from: Data(delta.utf8)))
        let failure = """
        data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}
        """
        XCTAssertThrowsError(try ChatGPTPlan.translation(from: Data((delta + failure).utf8))) {
            XCTAssertEqual($0 as? ChatGPTPlan.Failure, .usageLimit)
        }
    }

    func testSessionSurvivesNewStoreAndCanBeClearedWithoutReadingLegacyCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatGPTSessionStore(directory: directory)
        XCTAssertNil(try store.read())
        let signedIn = Data(#"{"test":"signed-in"}"#.utf8)
        try store.write(signedIn)
        let reopened = ChatGPTSessionStore(directory: directory)
        XCTAssertEqual(try reopened.read(), signedIn)

        let signedOut = Data(#"{"test":"signed-out"}"#.utf8)
        try reopened.write(signedOut)
        XCTAssertEqual(try store.read(), signedOut)
        let file = directory.appendingPathComponent("session.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try reopened.read())
    }

    @MainActor func testImageAnalysisUsesTheProviderSpecificImageInput() throws {
        let png = Data([1, 2, 3])
        let analysis = try ImageAnalysis(png: png, question: "解释这道题", language: "zh-Hans")
        let responses = try ChatGPTPlan.analysisRequest(analysis, model: "", token: "fixture")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(responses.httpBody)) as? [String: Any])
        let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
        let parts = try XCTUnwrap(input.first?["content"] as? [[String: String]])
        XCTAssertEqual(parts.map { $0["type"] }, ["input_text", "input_image"])
        XCTAssertEqual(parts.first?["text"], "解释这道题")
        XCTAssertEqual(parts.last?["image_url"], "data:image/png;base64,AQID")
        XCTAssertEqual(payload["store"] as? Bool, false)

        let api = try CloudTranslation(baseURL: "https://example.invalid/v1", model: "vision-fixture")
        let completions = try api.analysisRequest(analysis, apiKey: "fixture")
        let chat = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(completions.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        let chatParts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(chatParts.last?["type"] as? String, "image_url")
        XCTAssertEqual((chatParts.last?["image_url"] as? [String: String])?["url"], parts.last?["image_url"])
        XCTAssertThrowsError(try ImageAnalysis(png: Data(), question: "", language: "zh-Hans"))
    }

    @MainActor func testDefaultTranslationRequestsLunaWithLowEffort() throws {
        let request = try ChatGPTPlan.translationRequest("Example text", target: "zh-Hans", model: "", token: "fixture")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "gpt-6-luna")
        XCTAssertEqual((payload["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(payload["stream"] as? Bool, true)
        XCTAssertEqual(payload["store"] as? Bool, false)
    }

    @MainActor func testModelListDiagnosticsClassifyEnvelopesWithoutReturningContents() {
        let fixtures: [(String, ChatGPTPlan.ModelListEvent.BodyShape)] = [
            (#"{"models":[]}"#, .chatGPTCatalog),
            (#"{"data":[]}"#, .standardCatalog),
            (#"{"detail":"private fixture"}"#, .errorObject),
            (#"{"other":"private fixture"}"#, .otherJSON),
            ("<html>gateway response</html>", .nonJSON)
        ]
        for (body, expected) in fixtures {
            XCTAssertEqual(ChatGPTPlan.modelListBodyShape(Data(body.utf8)), expected)
        }
    }

    @MainActor func testModelCatalogSkipsHiddenEntriesAndUsesSlugAsFallbackLabel() throws {
        let data = Data("""
        {"models":[{"visibility":"hidden"},{"slug":"model-a","visibility":"list","display_name":"Model A"},
                   {"slug":"model-b","visibility":"list"}]}
        """.utf8)
        let models = try ChatGPTPlan.decodeModels(data)
        XCTAssertEqual(models.map(\.slug), ["model-a", "model-b"])
        XCTAssertEqual(models.map(\.displayName), ["Model A", "model-b"])
        XCTAssertThrowsError(try ChatGPTPlan.decodeModels(Data("{}".utf8))) {
            XCTAssertEqual($0 as? ChatGPTPlan.Failure, .invalidModelCatalog)
        }
    }

    @MainActor func testLoopbackReceivesBrowserCallback() async throws {
        let callback = try await ChatGPTLoopback().wait(state: "expected") { uri in
            let url = try XCTUnwrap(URL(string: uri + "?state=expected&code=example"))
            Task {
                let (_, response) = try await URLSession.shared.data(from: url)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            }
        }
        XCTAssertEqual(callback.queryItems?.first(where: { $0.name == "code" })?.value, "example")
    }
}
