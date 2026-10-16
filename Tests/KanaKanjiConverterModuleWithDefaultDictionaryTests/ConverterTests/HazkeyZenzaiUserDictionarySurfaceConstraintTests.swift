import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

// [Hazkey Community Patch]
// Zenzaiの評価で受け入れたユーザ辞書の語が、不合格の後の下書きし直しでも残ることを検証する
// 評価はモデル用に正規化した表記 (jinenのNFKC、zenzの空白の置換) で行うが、ラティスは語の元の表記を制約と照合する
// 評価が返す制約でユーザ辞書の語の範囲を元の表記へ戻さないと、その語を含む経路が制約を満たせない
/// ユーザ辞書の語を含む下書きが不合格になった時の、制約付きの下書きし直しを検証する
///
/// 制約は `ZenzCandidateEvaluator.userDictionaryProtection(...)` で作り、`review(...)` と同じ
/// `Kana2Kanji.normalizedZenzConstraint(...)` を通して `kana2lattice_all_with_prefix_constraint` へ渡す
final class HazkeyZenzaiUserDictionarySurfaceConstraintTests: XCTestCase {
    private func composingText(_ reading: String) -> ComposingText {
        var c = ComposingText()
        c.insertAtCursorPosition(reading, inputStyle: .direct)
        return c
    }

    private func element(_ word: String, _ ruby: String, _ metadata: DicdataElementMetadata = .empty) -> DicdataElement {
        DicdataElement(word: word, ruby: ruby, cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10, metadata: metadata)
    }

    /// 下書き `data` の評価で、先頭 `acceptedTokenCount` 個のトークンを受け入れた後にモデルが `modelPiece` を求めた時の制約
    private func fixRequiredConstraint(
        data: [DicdataElement],
        tokens: [String],
        acceptedTokenCount: Int,
        modelPiece: String,
        normalize: (String) -> String
    ) -> [UInt8] {
        let pieces = tokens.map { Array($0.utf8) }
        let protection = ZenzCandidateEvaluator.userDictionaryProtection(
            candidateText: data.map(\.word).joined(),
            data: data,
            candidateTokenPieces: pieces,
            normalize: normalize
        )
        let decoded = pieces.prefix(acceptedTokenCount).flatMap { $0 }
        return (protection?.restoringSurface(decoded) ?? decoded) + Array(modelPiece.utf8)
    }

    private func redraftTexts(reading: String, userWord: DicdataElement, constraint: [UInt8]) -> [String] {
        let dicdataStore = DicdataStore.withDefaultDictionary()
        let state = dicdataStore.prepareState()
        state.importDynamicUserDictionary([userWord])
        let kanaKanji = Kana2Kanji(dicdataStore: dicdataStore)
        let result = kanaKanji.kana2lattice_all_with_prefix_constraint(
            self.composingText(reading),
            N_best: 5,
            constraint: Kana2Kanji.normalizedZenzConstraint(constraint, defaultHasEOS: false, ignoreMemoryAndUserDictionary: false),
            dicdataStoreState: state
        )
        return result.result.getCandidateData().map(kanaKanji.processClauseCandidate).map(\.text)
    }

    /// jinen: ㍻ (UD) の後の 機械 が不合格になり、モデルが 機会 を求める
    func testRedraftKeepsNFKCExpandedUserDictionaryWord() {
        let userWord = self.element("㍻", "ヘイセイ")
        let draft = [self.element("㍻", "ヘイセイ", .isFromUserDictionary), self.element("の", "ノ"), self.element("機械", "キカイ")]
        let constraint = self.fixRequiredConstraint(
            data: draft,
            tokens: ["平成", "の", "機械"],
            acceptedTokenCount: 2,
            modelPiece: "機会",
            normalize: { $0.precomposedStringWithCompatibilityMapping }
        )
        XCTAssertEqual(String(decoding: constraint, as: UTF8.self), "㍻の機会")
        let texts = self.redraftTexts(reading: "へいせいのきかい", userWord: userWord, constraint: constraint)
        XCTAssertTrue(texts.contains("㍻の機会"), "ユーザ辞書の語と、モデルが求めた語を両方含む経路が残るべき (得られた候補: \(texts))")

        // 正規化後の表記のままの制約では、ユーザ辞書の語を含む経路が制約を満たせない
        let normalizedTexts = self.redraftTexts(reading: "へいせいのきかい", userWord: userWord, constraint: Array("平成の機会".utf8))
        XCTAssertFalse(normalizedTexts.contains { $0.hasPrefix("㍻") }, "得られた候補: \(normalizedTexts)")
    }

    /// zenz: 半角空白を含むユーザ辞書の語は、モデルへは全角空白で渡る
    func testRedraftKeepsUserDictionaryWordWithZenzSpace() {
        let userWord = self.element("Hazkey Community", "ハズキーコミュニティ")
        let draft = [
            self.element("Hazkey Community", "ハズキーコミュニティ", .isFromUserDictionary),
            self.element("の", "ノ"),
            self.element("機械", "キカイ"),
        ]
        let constraint = self.fixRequiredConstraint(
            data: draft,
            tokens: ["Haz", "key", "\u{3000}", "Community", "の", "機械"],
            acceptedTokenCount: 5,
            modelPiece: "機会",
            normalize: { $0.replacingOccurrences(of: " ", with: "\u{3000}").replacingOccurrences(of: "\n", with: "") }
        )
        XCTAssertEqual(String(decoding: constraint, as: UTF8.self), "Hazkey Communityの機会")
        let texts = self.redraftTexts(reading: "はずきーこみゅにてぃのきかい", userWord: userWord, constraint: constraint)
        XCTAssertTrue(texts.contains("Hazkey Communityの機会"), "得られた候補: \(texts)")
    }
}
