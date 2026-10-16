// [Hazkey Community Patch]
// 前回の評価の後で読みが揃ったユーザ辞書の語を、Zenzaiの引き継ぎ制約が締め出さないことを検証する
// 読みの途中で評価した表記 (ひらがな) が制約に残ると、その語がラティスに現れず、表記が固定されていた
@testable import KanaKanjiConverterModule
import XCTest

final class HazkeyZenzaiUserDictionaryConstraintTests: XCTestCase {
    private let matouZouken = DicdataElement(word: "間桐臓硯", ruby: "マトウゾウケン", cid: CIDData.固有名詞.cid, mid: 100, value: -5)
    private let matou = DicdataElement(word: "間桐", ruby: "マトウ", cid: CIDData.固有名詞.cid, mid: 100, value: -5)

    /// 前回の評価の時点で読みが途中だった語は、揃った時点で制約から外す
    func testWordCompletedAfterEvaluationIsDroppedFromConstraint() {
        let cache = Self.cache(evaluated: "まとうぞうけ", candidate: [("まとうぞうけ", "マトウゾウケ")])
        let constraint = cache.getNewConstraint(for: Self.composingText("まとうぞうけんと"), userDictionary: [self.matouZouken])
        XCTAssertEqual(constraint.constraint, [])
    }

    /// 語の開始位置より前の表記は制約に残す
    func testConstraintKeepsTheReadingBeforeTheWord() {
        let cache = Self.cache(evaluated: "きょうはまと", candidate: [("今日", "キョウ"), ("は", "ハ"), ("まと", "マト")])
        let constraint = cache.getNewConstraint(for: Self.composingText("きょうはまとう"), userDictionary: [self.matou])
        XCTAssertEqual(constraint.constraint, Array("今日は".utf8))
    }

    /// 評価済みの読みの中で揃っていた語は、モデルが評価済みなので制約を保つ
    func testWordInsideEvaluatedReadingKeepsConstraint() {
        let cache = Self.cache(evaluated: "まとうぞうけんと", candidate: [("間桐臓硯", "マトウゾウケン"), ("と", "ト")])
        let constraint = cache.getNewConstraint(
            for: Self.composingText("まとうぞうけんとま"),
            userDictionary: [self.matouZouken, self.matou]
        )
        XCTAssertEqual(constraint.constraint, Array("間桐臓硯と".utf8))
    }

    /// 未確定のローマ字を含んで評価した候補でも、揃った語の手前までを制約に残す
    func testPendingRomajiCandidateIsCutBeforeTheCompletedWord() {
        let cache = Self.cache(
            evaluated: "まとうぞうけんとまt",
            candidate: [("まとうぞうけんと", "マトウゾウケント"), ("まt", "マt")]
        )
        let constraint = cache.getNewConstraint(for: Self.composingText("まとうぞうけんとまとう"), userDictionary: [self.matou])
        XCTAssertEqual(constraint.constraint, Array("まとうぞうけんと".utf8))
    }

    /// ユーザ辞書が空なら従来どおり候補の表記を全て制約にする
    func testEmptyUserDictionaryKeepsLegacyConstraint() {
        let cache = Self.cache(evaluated: "まとうぞうけ", candidate: [("まとうぞうけ", "マトウゾウケ")])
        let constraint = cache.getNewConstraint(for: Self.composingText("まとうぞうけんと"), userDictionary: [])
        XCTAssertEqual(constraint.constraint, Array("まとうぞうけ".utf8))
    }

    /// 候補を持たない制約は、評価済みの読みにかかる語が揃ったら捨てる
    func testRawConstraintIsDroppedWhenWordOverlapsEvaluatedReading() {
        let cache = Kana2Kanji.ZenzaiCache(
            Self.composingText("まとうぞうけ"),
            constraint: Kana2Kanji.PrefixConstraint(Array("まとうぞ".utf8)),
            satisfyingCandidate: nil
        )
        let constraint = cache.getNewConstraint(for: Self.composingText("まとうぞうけんと"), userDictionary: [self.matouZouken])
        XCTAssertEqual(constraint.constraint, [])
    }

    /// 候補を持たない制約は、評価済みの読みより後ろで始まる語では保つ
    func testRawConstraintIsKeptWhenWordStartsAfterEvaluatedReading() {
        let cache = Kana2Kanji.ZenzaiCache(
            Self.composingText("きょうは"),
            constraint: Kana2Kanji.PrefixConstraint(Array("今日は".utf8)),
            satisfyingCandidate: nil
        )
        let constraint = cache.getNewConstraint(for: Self.composingText("きょうはまとう"), userDictionary: [self.matou])
        XCTAssertEqual(constraint.constraint, Array("今日は".utf8))
    }

    /// 評価で常に受け入れたユーザ辞書の語は、制約へ引き継がない (引き継ぐと以後の文脈で選び直せない)
    func testUserDictionaryWordInCandidateIsNotCarriedIntoConstraint() {
        let cache = Self.cache(evaluated: "ゆうきを", elements: [
            Self.element("結城", "ユウキ", metadata: .isFromUserDictionary),
            Self.element("を", "ヲ"),
        ])
        let constraint = cache.getNewConstraint(for: Self.composingText("ゆうきをだ"), userDictionary: [Self.yuuki])
        XCTAssertEqual(constraint.constraint, [])
    }

    /// ユーザ辞書の語より前の表記は制約に残す
    func testConstraintKeepsWordsBeforeUserDictionaryWordInCandidate() {
        let cache = Self.cache(evaluated: "きょうはゆうきと", elements: [
            Self.element("今日", "キョウ"),
            Self.element("は", "ハ"),
            Self.element("結城", "ユウキ", metadata: .isFromUserDictionary),
            Self.element("と", "ト"),
        ])
        let constraint = cache.getNewConstraint(for: Self.composingText("きょうはゆうきとあ"), userDictionary: [Self.yuuki])
        XCTAssertEqual(constraint.constraint, Array("今日は".utf8))
    }

    /// 学習語はモデルが評価し直せるので、従来どおり制約に残す
    func testLearnedWordInCandidateIsStillCarriedIntoConstraint() {
        let cache = Self.cache(evaluated: "ゆうきを", elements: [
            Self.element("結城", "ユウキ", metadata: .isLearned),
            Self.element("を", "ヲ"),
        ])
        let constraint = cache.getNewConstraint(for: Self.composingText("ゆうきをだ"), userDictionary: [])
        XCTAssertEqual(constraint.constraint, Array("結城を".utf8))
    }

    /// 候補を持たない制約は、評価済みの読みの中で揃っていたユーザ辞書の語の表記を含み得るので捨てる
    func testRawConstraintWithUserDictionaryWordInsideEvaluatedReadingIsDropped() {
        let cache = Kana2Kanji.ZenzaiCache(
            Self.composingText("ゆうきを"),
            constraint: Kana2Kanji.PrefixConstraint(Array("結城を".utf8)),
            satisfyingCandidate: nil
        )
        let constraint = cache.getNewConstraint(for: Self.composingText("ゆうきをだ"), userDictionary: [Self.yuuki])
        XCTAssertEqual(constraint.constraint, [])
    }

    /// 明示的に受け入れた先頭候補は、ユーザ辞書の語を含んでも固定部分として残す
    func testAcceptedPrefixWithUserDictionaryWordIsKeptAsFixedPrefix() {
        let candidate = Self.candidate(evaluated: "ゆうきを", elements: [
            Self.element("結城", "ユウキ", metadata: .isFromUserDictionary),
            Self.element("を", "ヲ"),
        ])
        let accepted = Self.cache(evaluated: "ゆうきを", candidate: candidate).settingPrefixCandidate(candidate)
        let expectedFixedPrefix = Kana2Kanji.PrefixConstraint.FixedPrefix(byteCount: "結城を".utf8.count, rubyCount: 4)
        for cache in [accepted, accepted.keepingOnlyAcceptedPrefix()] {
            let constraint = cache.getNewConstraint(for: Self.composingText("ゆうきをだ"), userDictionary: [Self.yuuki])
            XCTAssertEqual(constraint.constraint, Array("結城を".utf8))
            XCTAssertEqual(constraint.fixedPrefix, expectedFixedPrefix)
        }
    }

    private static let yuuki = DicdataElement(
        word: "結城",
        ruby: "ユウキ",
        cid: CIDData.固有名詞.cid,
        mid: 100,
        value: -5,
        metadata: .isFromUserDictionary
    )

    private static func element(_ word: String, _ ruby: String, metadata: DicdataElementMetadata = .empty) -> DicdataElement {
        DicdataElement(word: word, ruby: ruby, cid: CIDData.一般名詞.cid, mid: 100, value: -10, metadata: metadata)
    }

    private static func cache(evaluated reading: String, candidate items: [(word: String, ruby: String)]) -> Kana2Kanji.ZenzaiCache {
        Self.cache(evaluated: reading, elements: items.map { Self.element($0.word, $0.ruby) })
    }

    private static func cache(evaluated reading: String, elements data: [DicdataElement]) -> Kana2Kanji.ZenzaiCache {
        Self.cache(evaluated: reading, candidate: Self.candidate(evaluated: reading, elements: data))
    }

    private static func candidate(evaluated reading: String, elements data: [DicdataElement]) -> Candidate {
        Candidate(
            text: data.map(\.word).joined(),
            value: -20,
            composingCount: .inputCount(reading.count),
            lastMid: 100,
            data: data
        )
    }

    private static func cache(evaluated reading: String, candidate: Candidate) -> Kana2Kanji.ZenzaiCache {
        Kana2Kanji.ZenzaiCache(
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
