import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

// [Hazkey Community Patch]
// ignoreMemoryAndUserDictionary が真のとき、学習語にもprefix制約をかける修正 (option A) の回帰テストをまとめる
// 上流は再試行で全ノードの制約を外しており、拒否された学習語が再び選ばれていた
// ユーザ辞書の語は修正の前後とも制約を素通しする (forkのユーザ辞書保護を維持)
/// Zenzai再試行制約 (ignoreMemoryAndUserDictionary) の回帰テストをまとめる
///
/// `kana2lattice_all_with_prefix_constraint` を直接呼び、学習語とユーザ辞書語の扱いを検証する
final class HazkeyZenzaiIgnoreMemoryConstraintTests: XCTestCase {
    /// 検証用の学習データ置き場
    ///
    /// テストごとに作り、終了時に削除する
    private var memoryDirectoryURL: URL!

    /// 学習データ置き場を作る
    ///
    /// 一時学習を有効にするため書き込み可能な置き場が要る
    override func setUpWithError() throws {
        try super.setUpWithError()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hazkey-ignore-memory-constraint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.memoryDirectoryURL = url
    }

    /// 学習データ置き場を削除する
    ///
    /// 一時ディレクトリに検証の残骸を残さない
    override func tearDownWithError() throws {
        if let url = self.memoryDirectoryURL {
            try? FileManager.default.removeItem(at: url)
        }
        self.memoryDirectoryURL = nil
        try super.tearDownWithError()
    }

    /// 読み全体を一度に入れた組成テキストを作る
    ///
    /// - Parameter reading: 読み (ひらがな)
    /// - Returns: 読み全体を持つ組成テキスト
    private func composingText(_ reading: String) -> ComposingText {
        var c = ComposingText()
        c.insertAtCursorPosition(reading, inputStyle: .direct)
        return c
    }

    /// 学習を有効にした辞書状態と変換器を作る
    ///
    /// - Returns: 辞書・辞書状態・変換器の組
    private func makeLearnedState() -> (DicdataStore, DicdataStoreState, Kana2Kanji) {
        let dicdataStore = DicdataStore.withDefaultDictionary()
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(.init(learningType: .inputAndOutput, maxMemoryCount: 100, memoryURL: self.memoryDirectoryURL))
        let kanaKanji = Kana2Kanji(dicdataStore: dicdataStore)
        return (dicdataStore, state, kanaKanji)
    }

    /// 制約付きラティス変換の候補テキスト列を返す
    ///
    /// `all_zenzai` が草稿から候補を作る手順 (`getCandidateData` と `processClauseCandidate`) と同じ方法でテキスト化する
    ///
    /// - Parameters:
    ///   - kanaKanji: 変換器
    ///   - reading: 読み
    ///   - surface: 制約の表記 (UTF-8化して制約にする)
    ///   - ignoreMemory: `ignoreMemoryAndUserDictionary` の値
    ///   - nBest: `N_best`
    ///   - state: 辞書状態
    /// - Returns: 候補テキストの列 (先頭が最良)
    private func constrainedTexts(
        _ kanaKanji: Kana2Kanji,
        reading: String,
        surface: String,
        ignoreMemory: Bool,
        nBest: Int,
        state: DicdataStoreState
    ) -> [String] {
        let constraint = Kana2Kanji.PrefixConstraint(Array(surface.utf8), hasEOS: true, ignoreMemoryAndUserDictionary: ignoreMemory)
        let result = kanaKanji.kana2lattice_all_with_prefix_constraint(
            self.composingText(reading),
            N_best: nBest,
            constraint: constraint,
            dicdataStoreState: state
        )
        return result.result.getCandidateData().map(kanaKanji.processClauseCandidate).map(\.text)
    }

    /// フラグ真で学習語が制約され、制約表記が先頭になることを検証する
    ///
    /// きかい を 機械 として学習させ、制約を 機会 (静的辞書にある別の表記) にする
    /// 修正前は学習語が制約を素通しして 機械 が再び先頭になり、この検証は失敗する
    func testIgnoreMemoryConstrainsLearnedWord() {
        let (_, state, kanaKanji) = self.makeLearnedState()
        let learned = DicdataElement(word: "機械", ruby: "キカイ", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [learned])

        for nBest in [1, 3] {
            let texts = self.constrainedTexts(kanaKanji, reading: "きかい", surface: "機会", ignoreMemory: true, nBest: nBest, state: state)
            XCTAssertFalse(
                texts.contains("機械"),
                "N_best=\(nBest): ignoreMemoryAndUserDictionary=true では学習語 機械 を含んではならない (得られた候補: \(texts))"
            )
            XCTAssertEqual(
                texts.first, "機会",
                "N_best=\(nBest): 先頭は制約表記 機会 になるべき (得られた候補: \(texts))"
            )
        }
    }

    /// フラグ偽では学習語が従来どおり制約を素通しすることを検証する
    ///
    /// 同じ学習・制約の組でフラグを偽にすると、学習語 機械 が候補に現れる (既存の動作の退行 guard)
    func testNoIgnoreMemoryLetsLearnedWordBypass() {
        let (_, state, kanaKanji) = self.makeLearnedState()
        let learned = DicdataElement(word: "機械", ruby: "キカイ", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [learned])

        let texts = self.constrainedTexts(kanaKanji, reading: "きかい", surface: "機会", ignoreMemory: false, nBest: 3, state: state)
        XCTAssertTrue(
            texts.contains("機械"),
            "ignoreMemoryAndUserDictionary=false では学習語 機械 が制約を素通しするべき (得られた候補: \(texts))"
        )
    }

    /// フラグ真でもユーザ辞書語の素通しが保たれることを検証する
    ///
    /// 動的ユーザ辞書に制約と異なる表記 (喜海) を登録し、フラグ真でも候補に現れることを確かめる
    /// 修正は学習語だけを制約対象に加え、ユーザ辞書語は前後とも素通しする
    func testIgnoreMemoryStillBypassesUserDictionaryWord() {
        let (_, state, kanaKanji) = self.makeLearnedState()
        let userWord = DicdataElement(word: "喜海", ruby: "キカイ", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.importDynamicUserDictionary([userWord])

        let texts = self.constrainedTexts(kanaKanji, reading: "きかい", surface: "機会", ignoreMemory: true, nBest: 10, state: state)
        XCTAssertTrue(
            texts.contains("喜海"),
            "ignoreMemoryAndUserDictionary=true でもユーザ辞書語 喜海 は制約を素通しするべき (得られた候補: \(texts))"
        )
    }

    /// 満たせる経路が無い制約で落ちずに空または静的のみを返すことを検証する
    ///
    /// 読み きかい に対して静的・学習のいずれも作れない長い制約を与え、クラッシュせず学習語を含まないことを確かめる
    /// 制約と一致する学習語だけを入れた場合も学習語は制約を満たして選ばれるため、空経路の検証には満たせない制約を使う
    /// `all_zenzai` は空の草稿を `guard ... best else` 分岐で扱う
    func testUnsatisfiableConstraintReturnsWithoutLearnedWord() {
        let (_, state, kanaKanji) = self.makeLearnedState()
        let learned = DicdataElement(word: "機械", ruby: "キカイ", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [learned])

        let impossible = "機会機会機会機会機会"
        let texts = self.constrainedTexts(kanaKanji, reading: "きかい", surface: impossible, ignoreMemory: true, nBest: 1, state: state)
        XCTAssertTrue(
            texts.isEmpty,
            "満たせない制約では候補が空であるべき (得られた候補: \(texts))"
        )
        XCTAssertFalse(
            texts.contains("機械"),
            "満たせない制約では学習語 機械 を含んではならない (得られた候補: \(texts))"
        )
    }
}
