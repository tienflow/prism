import XCTest
@testable import Prism

final class GenerationModelsTests: XCTestCase {

    // MARK: - AspectRatioOption

    func testAspectRatioRawValues() {
        XCTAssertEqual(AspectRatioOption.allCases.map(\.rawValue),
                       ["1:1", "16:9", "9:16", "4:3", "3:4"])
    }

    func testEveryAspectHasCriteriaHint() {
        for option in AspectRatioOption.allCases {
            XCTAssertFalse(option.criteriaHint.isEmpty, "\(option.rawValue) 缺少 criteriaHint")
            XCTAssertFalse(option.title.isEmpty)
        }
    }

    // MARK: - ArtStyleOption

    func testNoneStyleHasEmptySuffix() {
        XCTAssertEqual(ArtStyleOption.none.contextSuffix, "")
    }

    func testEveryNonNoneStyleHasNonEmptySuffix() {
        for option in ArtStyleOption.allCases where option != .none {
            XCTAssertFalse(option.contextSuffix.isEmpty, "\(option.rawValue) 缺少 contextSuffix")
            XCTAssertFalse(option.criteriaHint.isEmpty, "\(option.rawValue) 缺少 criteriaHint")
        }
    }

    func testRawValuesAreUnique() {
        let rawValues = ArtStyleOption.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count)
    }

    // MARK: - GenerationBatch 稿次轮次

    func testOriginalImageLabel() {
        let batch = GenerationBatch(prompt: "猫", imagePaths: ["/a0.png", "/a1.png"])
        XCTAssertEqual(batch.turnLabel(at: 0), "原图")
        XCTAssertEqual(batch.turnLabel(at: 1), "原图")
    }

    func testSingleEditRoundLabel() {
        let batch = GenerationBatch(
            prompt: "猫",
            imagePaths: ["/a0.png", "/a1.png"],
            editTurns: [
                EditTurn(instruction: "改成夜景", imagePath: "/a1.png", roundIndex: 0)
            ]
        )
        XCTAssertEqual(batch.turnLabel(at: 0), "原图")
        XCTAssertEqual(batch.turnLabel(at: 1), "改 1")
        XCTAssertEqual(batch.turnInstruction(at: 1), "改成夜景")
        XCTAssertNil(batch.turnInstruction(at: 0))
    }

    func testMultipleCandidatesShareRoundNumber() {
        // 同一次改图返回 2 张候选，共享 roundIndex 0，都应显示「改 1」
        let batch = GenerationBatch(
            prompt: "猫",
            imagePaths: ["/a0.png", "/a1.png", "/a2.png"],
            editTurns: [
                EditTurn(instruction: "改成夜景", imagePath: "/a1.png", roundIndex: 0),
                EditTurn(instruction: "改成夜景", imagePath: "/a2.png", roundIndex: 0)
            ]
        )
        XCTAssertEqual(batch.turnLabel(at: 1), "改 1")
        XCTAssertEqual(batch.turnLabel(at: 2), "改 1")
    }

    func testSecondRoundIncrementsLabel() {
        let batch = GenerationBatch(
            prompt: "猫",
            imagePaths: ["/a0.png", "/a1.png", "/a2.png"],
            editTurns: [
                EditTurn(instruction: "改夜景", imagePath: "/a1.png", roundIndex: 0),
                EditTurn(instruction: "加一只狗", imagePath: "/a2.png", roundIndex: 1)
            ]
        )
        XCTAssertEqual(batch.turnLabel(at: 1), "改 1")
        XCTAssertEqual(batch.turnLabel(at: 2), "改 2")
    }

    func testLegacyNilRoundIndexFallsBackToArrayIndex() {
        // 旧数据没有 roundIndex：数组下标即轮次
        let batch = GenerationBatch(
            prompt: "猫",
            imagePaths: ["/a0.png", "/a1.png", "/a2.png"],
            editTurns: [
                EditTurn(instruction: "改夜景", imagePath: "/a1.png"),
                EditTurn(instruction: "加狗", imagePath: "/a2.png")
            ]
        )
        XCTAssertEqual(batch.turnRound(at: 1), 0)
        XCTAssertEqual(batch.turnRound(at: 2), 1)
        XCTAssertEqual(batch.turnLabel(at: 2), "改 2")
    }

    func testTurnRoundOutOfBoundsReturnsNil() {
        let batch = GenerationBatch(prompt: "猫", imagePaths: ["/a0.png"])
        XCTAssertNil(batch.turnRound(at: 5))
        XCTAssertNil(batch.turnInstruction(at: 5))
        XCTAssertEqual(batch.turnLabel(at: 9), "—")
    }

    func testTurnSnapshotFallsBackToBatchLevel() {
        let batch = GenerationBatch(
            prompt: "猫",
            negativePrompt: "模糊",
            aspectRatio: "16:9",
            style: "赛博朋克",
            imagePaths: ["/a0.png", "/a1.png"],
            editTurns: [
                EditTurn(instruction: "改夜景", imagePath: "/a1.png",
                         aspectRatio: "1:1", style: nil, negativePrompt: "过曝")
            ]
        )
        // 原图：记录级参数
        let original = batch.turnSnapshot(at: 0)
        XCTAssertEqual(original.aspectRatio, "16:9")
        XCTAssertEqual(original.style, "赛博朋克")
        XCTAssertEqual(original.negativePrompt, "模糊")
        // 改稿：本轮值优先，nil 字段回退记录级
        let edited = batch.turnSnapshot(at: 1)
        XCTAssertEqual(edited.aspectRatio, "1:1")
        XCTAssertEqual(edited.style, "赛博朋克")
        XCTAssertEqual(edited.negativePrompt, "过曝")
    }

    // MARK: - Codable 持久化往返

    func testBatchCodableRoundTrip() throws {
        let batch = GenerationBatch(
            prompt: "一只猫",
            negativePrompt: "水印",
            aspectRatio: "3:4",
            style: "吉卜力动漫",
            stage: .completed,
            statusMessage: "完成",
            imagePaths: ["/x/a0.png", "/x/a1.png"],
            referenceImagePath: "/ref.png",
            editTurns: [
                EditTurn(instruction: "改成雨天", imagePath: "/x/a1.png",
                         aspectRatio: "3:4", style: "吉卜力动漫",
                         negativePrompt: "水印", roundIndex: 0)
            ]
        )
        let data = try JSONEncoder().encode(batch)
        let decoded = try JSONDecoder().decode(GenerationBatch.self, from: data)
        XCTAssertEqual(decoded.id, batch.id)
        XCTAssertEqual(decoded.prompt, "一只猫")
        XCTAssertEqual(decoded.aspectRatio, "3:4")
        XCTAssertEqual(decoded.stage, .completed)
        XCTAssertEqual(decoded.imagePaths, ["/x/a0.png", "/x/a1.png"])
        XCTAssertEqual(decoded.editTurns?.first?.instruction, "改成雨天")
        XCTAssertEqual(decoded.turnLabel(at: 1), "改 1")
    }
}
