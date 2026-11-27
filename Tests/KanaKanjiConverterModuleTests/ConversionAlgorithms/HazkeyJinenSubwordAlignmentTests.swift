import Foundation
@testable import KanaKanjiConverterModule
import XCTest

// [Hazkey Community Patch]
final class HazkeyJinenSubwordAlignmentTests: XCTestCase {
    private let identity: (String) -> String = { $0 }
    private let nfkc: (String) -> String = { $0.precomposedStringWithCompatibilityMapping }
    private let zenzNormalize: (String) -> String = {
        $0.replacingOccurrences(of: " ", with: "\u{3000}").replacingOccurrences(of: "\n", with: "")
    }

    private func element(
        _ word: String,
        _ ruby: String,
        metadata: DicdataElementMetadata = .empty
    ) -> DicdataElement {
        DicdataElement(
            word: word,
            ruby: ruby,
            cid: CIDData.一般名詞.cid,
            mid: MIDData.一般.mid,
            value: -10,
            metadata: metadata
        )
    }

    private func learned(_ word: String, _ ruby: String) -> DicdataElement {
        self.element(word, ruby, metadata: .isLearned)
    }

    private func pieces(_ parts: [String]) -> [[UInt8]] {
        parts.map { Array($0.utf8) }
    }

    // MARK: - F1: learnedTokenPriorities

    func testLearnedPrioritiesAlignAcrossSubwordMerge() {
        let kouen = self.learned("公演", "コウエン")
        let data = [
            self.element("日本", "ニホン"),
            self.element("語", "ゴ"),
            self.element("の", "ノ"),
            kouen,
        ]
        let priorities = ZenzCandidateEvaluator.learnedTokenPriorities(
            candidateText: "日本語の公演",
            data: data,
            candidateTokenPieces: self.pieces(["日本語の", "公演"]),
            normalize: self.nfkc
        )
        let expected = logf(ZenzCandidateEvaluator.learningPriority(data: kouen))
        XCTAssertEqual(priorities?.count, 2)
        XCTAssertEqual(priorities?[0], 0)
        XCTAssertEqual(priorities?[1] ?? -1, expected, accuracy: 1e-5)
    }

    func testLearnedPrioritiesDoNotBoostTokenStraddlingNormalAndLearnedWord() {
        let kouen = self.learned("公演", "コウエン")
        let data = [
            self.element("の", "ノ"),
            kouen,
        ]
        let priorities = ZenzCandidateEvaluator.learnedTokenPriorities(
            candidateText: "の公演",
            data: data,
            candidateTokenPieces: self.pieces(["の公", "演"]),
            normalize: self.nfkc
        )
        let expected = logf(ZenzCandidateEvaluator.learningPriority(data: kouen))
        XCTAssertEqual(priorities?.count, 2)
        XCTAssertEqual(priorities?[0], 0)
        XCTAssertEqual(priorities?[1] ?? -1, expected, accuracy: 1e-5)
    }

    func testLearnedPrioritiesUseMinPriorityAcrossAdjacentLearnedWords() {
        let shortLearned = self.learned("新", "シン")
        let longLearned = self.learned("幹線鉄道", "カンセンテツドウ")
        let data = [shortLearned, longLearned]
        let priorities = ZenzCandidateEvaluator.learnedTokenPriorities(
            candidateText: "新幹線鉄道",
            data: data,
            candidateTokenPieces: self.pieces(["新幹", "線鉄道"]),
            normalize: self.nfkc
        )
        let pShort = logf(ZenzCandidateEvaluator.learningPriority(data: shortLearned))
        let pLong = logf(ZenzCandidateEvaluator.learningPriority(data: longLearned))
        XCTAssertLessThan(pShort, pLong)
        XCTAssertEqual(priorities?.count, 2)
        XCTAssertEqual(priorities?[0] ?? -1, pShort, accuracy: 1e-5)
        XCTAssertEqual(priorities?[1] ?? -1, pLong, accuracy: 1e-5)
    }

    func testLearnedPrioritiesRespectLeadingDropCountAfterFixedPrefix() {
        let kouen = self.learned("公演", "コウエン")
        let data = [
            self.element("日本語の", "ニホンゴノ"),
            kouen,
        ]
        let priorities = ZenzCandidateEvaluator.learnedTokenPriorities(
            candidateText: "語の公演",
            data: data,
            candidateTokenPieces: self.pieces(["語の", "公演"]),
            normalize: self.nfkc
        )
        let expected = logf(ZenzCandidateEvaluator.learningPriority(data: kouen))
        XCTAssertEqual(priorities?.count, 2)
        XCTAssertEqual(priorities?[0], 0)
        XCTAssertEqual(priorities?[1] ?? -1, expected, accuracy: 1e-5)
    }

    func testLearnedPrioritiesReturnsNilWhenNoLearnedElementOrNormalizationMismatch() {
        let normalData = [
            self.element("日本語", "ニホンゴ"),
            self.element("の", "ノ"),
        ]
        XCTAssertNil(
            ZenzCandidateEvaluator.learnedTokenPriorities(
                candidateText: "日本語の",
                data: normalData,
                candidateTokenPieces: self.pieces(["日本語の"]),
                normalize: self.nfkc
            )
        )

        let learnedData = [self.learned("A B", "エービー")]
        XCTAssertNil(
            ZenzCandidateEvaluator.learnedTokenPriorities(
                candidateText: "A B",
                data: learnedData,
                candidateTokenPieces: self.pieces(["A", "\u{2581}", "B"]),
                normalize: self.nfkc
            )
        )
    }

    func testLearnedPrioritiesMatchPerCharacterTokensForZenz() {
        let kouen = self.learned("公演", "コウエン")
        let data = [
            self.element("日本", "ニホン"),
            self.element("語", "ゴ"),
            self.element("の", "ノ"),
            kouen,
        ]
        let priorities = ZenzCandidateEvaluator.learnedTokenPriorities(
            candidateText: "日本語の公演",
            data: data,
            candidateTokenPieces: self.pieces(["日", "本", "語", "の", "公", "演"]),
            normalize: self.zenzNormalize
        )
        let expected = logf(ZenzCandidateEvaluator.learningPriority(data: kouen))
        XCTAssertEqual(priorities?.count, 6)
        XCTAssertEqual(priorities?[0], 0)
        XCTAssertEqual(priorities?[1], 0)
        XCTAssertEqual(priorities?[2], 0)
        XCTAssertEqual(priorities?[3], 0)
        XCTAssertEqual(priorities?[4] ?? -1, expected, accuracy: 1e-5)
        XCTAssertEqual(priorities?[5] ?? -1, expected, accuracy: 1e-5)
    }

    // MARK: - F2: reusableAddressedTokenCount

    func testReusableAddressedTokenCountDoesNotSkipUncheckedSubword() {
        let count = ZenzCandidateEvaluator.reusableAddressedTokenCount(
            candidateTokenPieces: self.pieces(["ありがとう", "ご", "ざい", "ます"]),
            prefixConstraint: Kana2Kanji.PrefixConstraint(Array("ありがと".utf8)),
            normalize: self.nfkc
        )
        XCTAssertEqual(count, 0)

        let mergedCount = ZenzCandidateEvaluator.reusableAddressedTokenCount(
            candidateTokenPieces: self.pieces(["日本語の", "変換"]),
            prefixConstraint: Kana2Kanji.PrefixConstraint(Array("日".utf8)),
            normalize: self.nfkc
        )
        XCTAssertEqual(mergedCount, 0)
    }

    func testReusableAddressedTokenCountSkipsExactLeadingSubwordTokens() {
        let tokenPieces = self.pieces(["ありがとう", "ご", "ざい", "ます"])
        XCTAssertEqual(
            ZenzCandidateEvaluator.reusableAddressedTokenCount(
                candidateTokenPieces: tokenPieces,
                prefixConstraint: Kana2Kanji.PrefixConstraint(Array("ありがとう".utf8)),
                normalize: self.nfkc
            ),
            1
        )
        XCTAssertEqual(
            ZenzCandidateEvaluator.reusableAddressedTokenCount(
                candidateTokenPieces: tokenPieces,
                prefixConstraint: Kana2Kanji.PrefixConstraint(Array("ありがとうご".utf8)),
                normalize: self.nfkc
            ),
            2
        )
        XCTAssertEqual(
            ZenzCandidateEvaluator.reusableAddressedTokenCount(
                candidateTokenPieces: self.pieces(["あ", "り", "が", "と", "う"]),
                prefixConstraint: Kana2Kanji.PrefixConstraint(Array("ありがと".utf8)),
                normalize: self.identity
            ),
            4
        )
    }

    func testReusableAddressedTokenCountNormalizesConstraintForJinenNFKC() {
        let count = ZenzCandidateEvaluator.reusableAddressedTokenCount(
            candidateTokenPieces: self.pieces(["A", "B"]),
            prefixConstraint: Kana2Kanji.PrefixConstraint(Array("Ａ".utf8)),
            normalize: self.nfkc
        )
        XCTAssertEqual(count, 1)
    }

    func testReusableAddressedTokenCountNormalizesSpaceForZenz() {
        let count = ZenzCandidateEvaluator.reusableAddressedTokenCount(
            candidateTokenPieces: self.pieces(["あ", "\u{3000}", "い"]),
            prefixConstraint: Kana2Kanji.PrefixConstraint(Array("あ ".utf8)),
            normalize: self.zenzNormalize
        )
        XCTAssertEqual(count, 2)
    }

    func testReusableAddressedTokenCountReturnsZeroForInvalidUTF8Constraint() {
        let count = ZenzCandidateEvaluator.reusableAddressedTokenCount(
            candidateTokenPieces: self.pieces(["あ", "い"]),
            prefixConstraint: Kana2Kanji.PrefixConstraint([0xFF, 0xFE]),
            normalize: self.nfkc
        )
        XCTAssertEqual(count, 0)

        let emptyPieceCount = ZenzCandidateEvaluator.reusableAddressedTokenCount(
            candidateTokenPieces: [[], Array("あ".utf8)],
            prefixConstraint: Kana2Kanji.PrefixConstraint(Array("あ".utf8)),
            normalize: self.nfkc
        )
        XCTAssertEqual(emptyPieceCount, 0)
    }

    // MARK: - F3: ZenzContext.tokenizeWithRetry

    func testTokenizeWithRetryExpandsBufferWhenNegativeCountReturned() {
        var capacities: [Int32] = []
        let tokens = ZenzContext.tokenizeWithRetry(utf8Count: 1, addBOS: false) { buffer, capacity in
            capacities.append(capacity)
            if capacity < 3 {
                return -3
            }
            buffer[0] = 230
            buffer[1] = 154
            buffer[2] = 133
            return 3
        }
        XCTAssertEqual(capacities, [1, 3])
        XCTAssertEqual(tokens, [230, 154, 133])
    }

    func testTokenizeWithRetryHandlesEmptyInputWithoutBOS() {
        var called = false
        let tokens = ZenzContext.tokenizeWithRetry(utf8Count: 0, addBOS: false) { _, _ in
            called = true
            return 0
        }
        XCTAssertFalse(called)
        XCTAssertEqual(tokens, [])
    }

    func testTokenizeWithRetryRejectsFailureWithoutFabricatingBOS() {
        let repeatedNegative = ZenzContext.tokenizeWithRetry(utf8Count: 1, addBOS: false) { _, _ in
            -3
        }
        XCTAssertNil(repeatedNegative)

        let int32Min = ZenzContext.tokenizeWithRetry(utf8Count: 1, addBOS: false) { _, _ in
            Int32.min
        }
        XCTAssertNil(int32Min)

        let excessiveCapacity = ZenzContext.tokenizeWithRetry(utf8Count: 1, addBOS: false) { _, _ in
            -100_000
        }
        XCTAssertNil(excessiveCapacity)
    }
}
