import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

// [Hazkey Community Patch]
// hasEOS制約の遷移検査が末尾ノードの完全一致を拒む境界不具合の回帰テストをまとめる
// 遷移検査は次ノードの語を含めた長さに厳密なprefix (newTotal < constraintLength) を求めるため
// 末尾ノードで制約と完全一致する複数ノード経路が登録されず、EOS制約が単一ノード経路でしか満たせなかった
/// EOS付きprefix制約の末尾境界の回帰テストをまとめる
///
/// `kana2lattice_all_with_prefix_constraint` の遷移検査が、末尾ノードでの完全一致を許すことを検証する
final class HazkeyPrefixConstraintEOSBoundaryTests: XCTestCase {
    /// 読み全体を一度に入れた組成テキストを作る
    ///
    /// - Parameter reading: 読み (ひらがな)
    /// - Returns: 読み全体を持つ組成テキスト
    private func composingText(_ reading: String) -> ComposingText {
        var c = ComposingText()
        c.insertAtCursorPosition(reading, inputStyle: .direct)
        return c
    }

    /// 学習なしの辞書状態と変換器を作る
    ///
    /// 静的辞書だけの経路で境界不具合を再現するため、学習は有効にしない
    ///
    /// - Returns: 辞書・辞書状態・変換器の組
    private func makePlainState() -> (DicdataStore, DicdataStoreState, Kana2Kanji) {
        let dicdataStore = DicdataStore.withDefaultDictionary()
        let state = dicdataStore.prepareState()
        let kanaKanji = Kana2Kanji(dicdataStore: dicdataStore)
        return (dicdataStore, state, kanaKanji)
    }

    /// 制約付きラティス変換の候補列を返す
    ///
    /// `all_zenzai` が草稿から候補を作る手順 (`getCandidateData` と `processClauseCandidate`) と同じ方法で候補化する
    ///
    /// - Parameters:
    ///   - kanaKanji: 変換器
    ///   - reading: 読み
    ///   - surface: 制約の表記 (UTF-8化して制約にする)
    ///   - hasEOS: 制約の終端一致要求
    ///   - ignoreMemory: `ignoreMemoryAndUserDictionary` の値
    ///   - nBest: `N_best`
    ///   - state: 辞書状態
    ///   - fixedPrefix: 固定表記 (nilのときは指定なし)
    /// - Returns: 候補列 (先頭が最良)
    private func constrainedCandidates(
        _ kanaKanji: Kana2Kanji,
        reading: String,
        surface: String,
        hasEOS: Bool,
        ignoreMemory: Bool,
        nBest: Int,
        state: DicdataStoreState,
        fixedPrefix: Kana2Kanji.PrefixConstraint.FixedPrefix? = nil
    ) -> [Candidate] {
        let constraint = Kana2Kanji.PrefixConstraint(
            Array(surface.utf8),
            hasEOS: hasEOS,
            ignoreMemoryAndUserDictionary: ignoreMemory,
            fixedPrefix: fixedPrefix
        )
        let result = kanaKanji.kana2lattice_all_with_prefix_constraint(
            self.composingText(reading),
            N_best: nBest,
            constraint: constraint,
            dicdataStoreState: state
        )
        return result.result.getCandidateData().map(kanaKanji.processClauseCandidate)
    }

    /// EOS制約が静的辞書の複数ノード経路を受け入れることを検証する
    ///
    /// 読み わたしはがくせい に対する 私は学生 は助詞 は を含むため単一辞書語ではあり得ず、必ず複数ノード (私/は/学生) になる
    /// あしたこうえん → 明日公園 も複数ノードとみられるが、複合語の単一登録の可能性を排除できないため、助詞を含むこちらを選ぶ
    /// 修正前は末尾ノード 学生 の遷移が厳密なprefix検査で棄却され、候補が空になる
    func testEOSConstraintAcceptsMultiNodeStaticPath() {
        let (_, state, kanaKanji) = self.makePlainState()
        for nBest in [1, 3] {
            let candidates = self.constrainedCandidates(
                kanaKanji,
                reading: "わたしはがくせい",
                surface: "私は学生",
                hasEOS: true,
                ignoreMemory: false,
                nBest: nBest,
                state: state
            )
            let texts = candidates.map(\.text)
            XCTAssertFalse(
                texts.isEmpty,
                "N_best=\(nBest): EOS制約 私は学生 を満たす候補が空であってはならない (得られた候補: \(texts))"
            )
            XCTAssertEqual(
                texts.first, "私は学生",
                "N_best=\(nBest): 先頭は制約表記 私は学生 になるべき (得られた候補: \(texts))"
            )
            let topNodeCount = candidates.first?.data.count ?? 0
            XCTAssertGreaterThanOrEqual(
                topNodeCount, 2,
                "N_best=\(nBest): 先頭候補は複数ノード経路であるべき (ノード数: \(topNodeCount))"
            )
        }
    }

    /// EOS制約が完全一致しない経路を受け入れないことを検証する
    ///
    /// 制約を末尾1文字欠けの厳密なprefix (私は学) にすると、全文を覆う経路はどれも完全一致しないため、候補は空のはず
    /// 修正が非厳密な一致を許していないことの退行guard (修正の前後とも通る)
    func testEOSConstraintRejectsLongerOrShorterPath() {
        let (_, state, kanaKanji) = self.makePlainState()
        for nBest in [1, 3] {
            let candidates = self.constrainedCandidates(
                kanaKanji,
                reading: "わたしはがくせい",
                surface: "私は学",
                hasEOS: true,
                ignoreMemory: false,
                nBest: nBest,
                state: state
            )
            let texts = candidates.map(\.text)
            XCTAssertTrue(
                texts.allSatisfy { $0 == "私は学" },
                "N_best=\(nBest): EOS制約 私は学 と異なる表記を含んではならない (得られた候補: \(texts))"
            )
        }
    }

    /// 非EOS制約がprefix一致を受け入れることを検証する
    ///
    /// 制約を先頭の語 私 だけにすると、全文経路 私は学生 がprefix一致で登録される (修正の前後とも通る退行guard)
    func testNonEOSConstraintStillAcceptsPrefix() {
        let (_, state, kanaKanji) = self.makePlainState()
        for nBest in [1, 3] {
            let candidates = self.constrainedCandidates(
                kanaKanji,
                reading: "わたしはがくせい",
                surface: "私",
                hasEOS: false,
                ignoreMemory: false,
                nBest: nBest,
                state: state
            )
            let texts = candidates.map(\.text)
            XCTAssertFalse(
                texts.isEmpty,
                "N_best=\(nBest): 非EOS制約 私 を満たす候補が空であってはならない (得られた候補: \(texts))"
            )
            XCTAssertTrue(
                texts.first?.hasPrefix("私") ?? false,
                "N_best=\(nBest): 先頭は制約表記 私 で始まるべき (得られた候補: \(texts))"
            )
        }
    }

    /// 固定表記が制約免除の語にも掛かることを検証する
    ///
    /// 動的ユーザ辞書の 喜海 は制約 機会 を素通しするが、制約全体を固定表記にすると除外される
    /// 免除分岐は今回の修正で触らないため、修正の前後とも通る退行guard
    /// `FixedPrefix` は素朴な2要素structのため、公開のメンバワイズ初期化子で直接作れる
    func testFixedPrefixStillAppliesToExemptNodes() {
        let (_, state, kanaKanji) = self.makePlainState()
        let userWord = DicdataElement(word: "喜海", ruby: "キカイ", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.importDynamicUserDictionary([userWord])
        let fixed = Kana2Kanji.PrefixConstraint.FixedPrefix(byteCount: Array("機会".utf8).count, rubyCount: 3)
        for nBest in [1, 3] {
            let candidates = self.constrainedCandidates(
                kanaKanji,
                reading: "きかい",
                surface: "機会",
                hasEOS: true,
                ignoreMemory: true,
                nBest: nBest,
                state: state,
                fixedPrefix: fixed
            )
            let texts = candidates.map(\.text)
            XCTAssertFalse(
                texts.contains("喜海"),
                "N_best=\(nBest): 固定表記があるときユーザ辞書語 喜海 を含んではならない (得られた候補: \(texts))"
            )
            XCTAssertEqual(
                texts.first, "機会",
                "N_best=\(nBest): 先頭は制約表記 機会 になるべき (得られた候補: \(texts))"
            )
        }
    }
}
