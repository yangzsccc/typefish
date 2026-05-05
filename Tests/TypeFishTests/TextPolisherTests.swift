import XCTest
@testable import TypeFish

final class TextPolisherTests: XCTestCase {
    func testGPTOSSPayloadUsesLowReasoningAndLargerTokenBudget() {
        let text = "搜索了什么内容,这个可以加到我们的UI里面吗?尤其是对于本地的model,我其实很想知道他们都做了什么。如果他卡住了,我也能知道他到底是在哪一个节点发生了问题。"

        let payload = TextPolisher.requestPayload(
            text: text,
            model: "openai/gpt-oss-120b",
            systemPrompt: "Clean only"
        )

        XCTAssertEqual(payload["reasoning_effort"] as? String, "low")
        XCTAssertGreaterThanOrEqual(payload["max_tokens"] as? Int ?? 0, 512)
    }

    func testEmptyModelContentFallsBackToRawTranscription() {
        let raw = "你想办法找真正的input然后去test一下,看看我刚刚有没有留下什么音频可以做测试。"

        let polished = TextPolisher.cleanedModelOutput(
            content: "",
            original: raw
        )

        XCTAssertEqual(polished, raw)
    }
}
