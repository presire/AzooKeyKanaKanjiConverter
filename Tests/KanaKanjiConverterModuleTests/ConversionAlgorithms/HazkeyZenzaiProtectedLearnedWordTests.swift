// [Hazkey Community Patch]
// 要求で保護を指定された学習語 (`ConvertRequestOptions.ZenzaiMode.protectedLearnedWords`) を、
// Zenzaiの評価・再試行・制約の引き継ぎでユーザ辞書の語と同じく扱うことを、モデルなしで検証する
// 指定のない学習語は従来どおり扱う (別の文脈では Zenzai が選び直せる)
@testable import KanaKanjiConverterModule
import XCTest

final class HazkeyZenzaiProtectedLearnedWordTests: XCTestCase {
    private static let kikai = ConvertRequestOptions.ZenzaiMode.ProtectedLearnedWord(ruby: "キカイ", word: "機械")
    private static let protection = Kana2Kanji.ZenzaiWordProtection(learnedWords: [kikai])

    // MARK: - 保護の判定

    func testProtectsOnlySpecifiedLearnedWord() {
        XCTAssertTrue(Self.protection.protects(Self.element("機械", "キカイ", metadata: .isLearned)))
        XCTAssertFalse(Self.protection.protects(Self.element("機会", "キカイ", metadata: .isLearned)))
        XCTAssertFalse(Self.protection.protects(Self.element("機械", "キカイ")))
        XCTAssertTrue(Self.protection.protects(Self.element("機会", "キカイ", metadata: .isFromUserDictionary)))
    }

    func testEmptyProtectionKeepsUserDictionaryOnly() {
        let empty = Kana2Kanji.ZenzaiWordProtection()
        XCTAssertFalse(empty.protects(Self.element("機械", "キカイ", metadata: .isLearned)))
        XCTAssertTrue(empty.protects(Self.element("機械", "キカイ", metadata: .isFromUserDictionary)))
    }

    // MARK: - 再試行

    func testProtectedLearnedWordIsNotRetriedWithoutMemory() {
        let candidate = Self.candidate([Self.element("機械", "キカイ", metadata: .isLearned)])
        let constraint = Kana2Kanji.PrefixConstraint(Array("機会".utf8))
        XCTAssertFalse(Kana2Kanji.retriesWithoutMemory(candidate, constraint: constraint, protection: Self.protection))
    }

    func testUnprotectedLearnedWordIsRetriedWithoutMemory() {
        let candidate = Self.candidate([Self.element("機会", "キカイ", metadata: .isLearned)])
        let constraint = Kana2Kanji.PrefixConstraint(Array("機械".utf8))
        XCTAssertTrue(Kana2Kanji.retriesWithoutMemory(candidate, constraint: constraint, protection: Self.protection))
        XCTAssertTrue(Kana2Kanji.retriesWithoutMemory(candidate, constraint: constraint, protection: Kana2Kanji.ZenzaiWordProtection()))
    }

    // MARK: - 評価で保護するトークンの範囲

    func testMaskProtectsTokensOfProtectedLearnedWord() {
        let data = [Self.element("いい", "イイ"), Self.element("機械", "キカイ", metadata: .isLearned)]
        let protection = ZenzCandidateEvaluator.userDictionaryProtection(
            candidateText: "いい機械",
            data: data,
            candidateTokenPieces: [Array("いい".utf8), Array("機".utf8), Array("械".utf8)],
            normalize: { $0 },
            isProtected: Self.protection.protects
        )
        XCTAssertEqual(protection?.tokenMask, [false, true, true])
    }

    // MARK: - 制約の引き継ぎ

    func testProtectedLearnedWordIsNotCarriedIntoConstraint() {
        let cache = Self.cache(evaluated: "いいきかい", elements: [
            Self.element("いい", "イイ"),
            Self.element("機械", "キカイ", metadata: .isLearned),
        ])
        let constraint = cache.getNewConstraint(for: Self.composingText("いいきかいだ"), userDictionary: [], protection: Self.protection)
        XCTAssertEqual(constraint.constraint, Array("いい".utf8))
    }

    func testUnprotectedLearnedWordIsStillCarriedIntoConstraint() {
        let cache = Self.cache(evaluated: "いいきかい", elements: [
            Self.element("いい", "イイ"),
            Self.element("機会", "キカイ", metadata: .isLearned),
        ])
        let constraint = cache.getNewConstraint(for: Self.composingText("いいきかいだ"), userDictionary: [], protection: Self.protection)
        XCTAssertEqual(constraint.constraint, Array("いい機会".utf8))
    }

    /// 候補を持たない制約も、評価済みの読みの中で揃っていた保護する学習語の表記を含み得るので捨てる (ユーザ辞書の語と同じ)
    func testRawConstraintWithProtectedLearnedWordInsideEvaluatedReadingIsDropped() {
        let cache = Kana2Kanji.ZenzaiCache(
            Self.composingText("いいきかい"),
            constraint: Kana2Kanji.PrefixConstraint(Array("いい機械".utf8)),
            satisfyingCandidate: nil
        )
        let constraint = cache.getNewConstraint(for: Self.composingText("いいきかいだ"), userDictionary: [], protection: Self.protection)
        XCTAssertEqual(constraint.constraint, [])
    }

    // MARK: - 評価キャッシュのキー

    /// 保護した要求で作った制約は、保護しない要求へ引き継がない (保護した語が評価されずに合格するのを防ぐ)
    func testConstraintFromProtectedRequestIsNotCarriedWithoutProtection() {
        var cache = Self.cache(evaluated: "いいきかい", elements: [
            Self.element("いい", "イイ"),
            Self.element("機械", "キカイ", metadata: .isLearned),
        ])
        cache.wordProtection = Self.protection
        let unprotected = Kana2Kanji.ZenzaiWordProtection()
        let constraint = cache.adoptingWordProtection(unprotected)
            .getNewConstraint(for: Self.composingText("いいきかいだ"), userDictionary: [], protection: unprotected)
        XCTAssertEqual(constraint.constraint, [])
    }

    /// 保護が同じ要求では、従来どおり制約を引き継ぐ
    func testConstraintIsCarriedWhenProtectionIsUnchanged() {
        var cache = Self.cache(evaluated: "いいきかい", elements: [
            Self.element("いい", "イイ"),
            Self.element("機械", "キカイ", metadata: .isLearned),
        ])
        cache.wordProtection = Self.protection
        let constraint = cache.adoptingWordProtection(Self.protection)
            .getNewConstraint(for: Self.composingText("いいきかいだ"), userDictionary: [], protection: Self.protection)
        XCTAssertEqual(constraint.constraint, Array("いい".utf8))
    }

    func testCandidateSegmentDistinguishesProtection() {
        let learned = Self.element("機械", "キカイ", metadata: .isLearned)
        XCTAssertNotEqual(
            ZenzEvaluationCacheKey.CandidateSegment(learned, protection: Self.protection),
            ZenzEvaluationCacheKey.CandidateSegment(learned)
        )
    }

    // MARK: - ヘルパ

    private static func element(_ word: String, _ ruby: String, metadata: DicdataElementMetadata = .empty) -> DicdataElement {
        DicdataElement(word: word, ruby: ruby, cid: CIDData.一般名詞.cid, mid: 100, value: -10, metadata: metadata)
    }

    private static func candidate(_ data: [DicdataElement]) -> Candidate {
        Candidate(
            text: data.map(\.word).joined(),
            value: -20,
            composingCount: .inputCount(data.map(\.ruby.count).reduce(0, +)),
            lastMid: 100,
            data: data
        )
    }

    private static func cache(evaluated reading: String, elements data: [DicdataElement]) -> Kana2Kanji.ZenzaiCache {
        let candidate = Candidate(
            text: data.map(\.word).joined(),
            value: -20,
            composingCount: .inputCount(reading.count),
            lastMid: 100,
            data: data
        )
        return Kana2Kanji.ZenzaiCache(
            Self.composingText(reading),
            constraint: Kana2Kanji.PrefixConstraint(Array(candidate.text.utf8)),
            satisfyingCandidate: candidate
        )
    }

    private static func composingText(_ text: String) -> ComposingText {
        var composing = ComposingText()
        composing.insertAtCursorPosition(text, inputStyle: .direct)
        return composing
    }
}
