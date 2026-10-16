import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

// [Hazkey Community Patch]
// 制約付きの下書きを N_best: 1 で作るとき (リッチな候補を要求しない変換) も、呼び出し側 (Kana2Kanji.all_zenzai(...)) が
// 候補の評価値 (processClauseCandidate の value。意味連接のコストを含む) で選ぶ最良候補が、N_best: 3 と同じになることを検証する
// 修正前は、文末に達した経路のうちラティスの累積値 (totalValue) が最大の1本だけを残していた
// 累積値と評価値の順位は意味連接のコストで入れ替わり得るため、ユーザ辞書の 感心 (固有名詞、-5) が 関心 より選ばれていた
final class HazkeyPrefixConstraintSingleBestTests: XCTestCase {
    private func composingText(_ reading: String) -> ComposingText {
        var c = ComposingText()
        c.insertAtCursorPosition(reading, inputStyle: .direct)
        return c
    }

    /// hazkey-server のユーザ辞書の名詞と同じ品詞・コスト (UserDictionaryEntry.toDicdataElement())
    private func userDictionaryNoun(_ word: String, _ ruby: String) -> DicdataElement {
        DicdataElement(word: word, ruby: ruby, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
    }

    private func draftCandidates(reading: String, userDictionary: [DicdataElement], constraint: String, nBest: Int) -> [Candidate] {
        let dicdataStore = DicdataStore.withDefaultDictionary()
        let state = dicdataStore.prepareState()
        state.importDynamicUserDictionary(userDictionary)
        let kanaKanji = Kana2Kanji(dicdataStore: dicdataStore)
        let result = kanaKanji.kana2lattice_all_with_prefix_constraint(
            self.composingText(reading),
            N_best: nBest,
            constraint: Kana2Kanji.PrefixConstraint(Array(constraint.utf8)),
            dicdataStoreState: state
        )
        return result.result.getCandidateData().map(kanaKanji.processClauseCandidate)
    }

    /// all_zenzai(...) と同じく、評価値が最大の候補 (同値なら先に現れたもの)
    private func best(_ candidates: [Candidate]) -> Candidate? {
        candidates.reduce(into: Candidate?.none) { best, candidate in
            if let current = best, candidate.value > current.value {
                best = candidate
            } else if best == nil {
                best = candidate
            }
        }
    }

    /// せいじへのかんしん: ユーザ辞書に 感心 があっても、制約 政治への の下書きの最良候補は N_best 1 と 3 で同じ 政治への関心
    func testSingleBestDraftPicksSameBestAsThreeBestWithUserDictionaryWord() {
        let userDictionary = [self.userDictionaryNoun("感心", "カンシン")]
        let three = self.draftCandidates(reading: "せいじへのかんしん", userDictionary: userDictionary, constraint: "政治への", nBest: 3)
        let one = self.draftCandidates(reading: "せいじへのかんしん", userDictionary: userDictionary, constraint: "政治への", nBest: 1)
        XCTAssertEqual(self.best(three)?.text, "政治への関心", "N_best 3 の候補: \(three.map(\.text))")
        XCTAssertEqual(self.best(one)?.text, self.best(three)?.text, "N_best 1 の候補: \(one.map { "\($0.text)[\($0.value)]" })")
    }

    /// ユーザ辞書が無いときは、修正の前後とも 政治への関心
    func testSingleBestDraftWithoutUserDictionaryIsUnchanged() {
        let one = self.draftCandidates(reading: "せいじへのかんしん", userDictionary: [], constraint: "政治への", nBest: 1)
        XCTAssertEqual(self.best(one)?.text, "政治への関心", "N_best 1 の候補: \(one.map(\.text))")
    }

    /// ユーザ辞書の語が無い文でも、N_best 1 の候補はどれも制約を満たし、最良候補は N_best 3 と同じ
    func testSingleBestDraftKeepsConstraintAndMatchesThreeBest() {
        let reading = "わたしはがくせいです"
        let constraint = "私は"
        let one = self.draftCandidates(reading: reading, userDictionary: [], constraint: constraint, nBest: 1)
        let three = self.draftCandidates(reading: reading, userDictionary: [], constraint: constraint, nBest: 3)
        XCTAssertFalse(one.isEmpty)
        XCTAssertTrue(one.allSatisfy { $0.text.hasPrefix(constraint) }, "候補: \(one.map(\.text))")
        XCTAssertEqual(self.best(one)?.text, self.best(three)?.text)
    }
}
