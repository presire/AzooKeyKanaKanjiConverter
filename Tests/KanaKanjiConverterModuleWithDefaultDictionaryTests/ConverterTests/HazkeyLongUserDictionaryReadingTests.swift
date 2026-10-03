import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

// [Hazkey Community Patch]
// 読みの途中がどのLOUDSにも無い動的ユーザ辞書の語を変換候補に出すことの回帰テストをまとめる
// 辞書探索は短い読みから順に伸ばし、どのLOUDSでも到達できない読みの先を打ち切る
// そのため、マトウゾウケンのように途中のマトウゾでLOUDSの経路が切れる語は、読みの全体まで届かずにラティスへ載らなかった
// 入力途中の変換要求で増分探索が読みの全体から始まった場合だけ載るため、出たり出なかったりした
/// LOUDSに経路の無い長い読みを持つ動的ユーザ辞書語の回帰テストをまとめる
///
/// 入力途中の変換要求の有無やカーソル位置に関わらず、登録語をラティスへ載せる
final class HazkeyLongUserDictionaryReadingTests: XCTestCase {
    /// 検証用の動的ユーザ辞書を作る
    ///
    /// マトウゾウケンは途中のマトウゾでシステム辞書の経路が切れる読みで、マトウは経路のある短い読みの対照に使う
    ///
    /// - Returns: 検証語の辞書要素列
    private func userDictionary() -> [DicdataElement] {
        [
            DicdataElement(word: "間桐臓硯", ruby: "マトウゾウケン", cid: CIDData.人名一般.cid, mid: MIDData.一般.mid, value: -5),
            DicdataElement(word: "間桐", ruby: "マトウ", cid: CIDData.人名一般.cid, mid: MIDData.一般.mid, value: -5),
        ]
    }

    /// 検証用の変換要求を作る
    ///
    /// 学習や誤字訂正の影響を除き、辞書だけで候補を作る
    ///
    /// - Returns: 固定条件の変換要求
    private func requestOptions() -> ConvertRequestOptions {
        ConvertRequestOptions(
            N_best: 10,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: true,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            maxMemoryCount: 0,
            shouldResetMemory: false,
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: URL(fileURLWithPath: ""),
            textReplacer: .empty,
            specialCandidateProviders: [],
            zenzaiMode: .off,
            typoCorrectionMode: .disabled,
            metadata: nil
        )
    }

    /// 打鍵列を1文字ずつ入力する
    ///
    /// - Parameters:
    ///   - composingText: 入力先の組成テキスト
    ///   - sequence: 打鍵列
    private func sequentialInput(_ composingText: inout ComposingText, sequence: String) {
        for char in sequence {
            composingText.insertAtCursorPosition(String(char), inputStyle: .roman2kana)
        }
    }

    /// 動的ユーザ辞書を読み込んだ変換器を作る
    ///
    /// - Returns: 検証語を読み込んだ変換器
    private func makeConverter() -> KanaKanjiConverter {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        converter.importDynamicUserDictionary(self.userDictionary())
        return converter
    }

    /// 読みの先頭からの辞書探索で見つかる表記を求める
    ///
    /// 読みの先頭から全ての長さを探索し、増分探索の起点に依存しない条件で調べる
    ///
    /// - Parameters:
    ///   - hiragana: 入力する読み
    ///   - dictionary: 動的ユーザ辞書
    ///   - needTypoCorrection: 誤り訂正の探索も行うかどうか
    /// - Returns: 探索結果の表記の集合
    private func lookupWords(hiragana: String, dictionary: [DicdataElement], needTypoCorrection: Bool) -> Set<String> {
        let dicdataStore = DicdataStore.withDefaultDictionary()
        let state = dicdataStore.prepareState()
        state.importDynamicUserDictionary(dictionary)
        var c = ComposingText()
        c.insertAtCursorPosition(hiragana, inputStyle: .direct)
        let result = dicdataStore.lookupDicdata(
            composingText: c,
            inputRange: needTypoCorrection ? (0, nil) : nil,
            surfaceRange: (0, nil),
            needTypoCorrection: needTypoCorrection,
            state: state
        )
        return Set(result.map(\.data.word))
    }

    /// 読みの先頭からの辞書探索で長い読みの登録語が見つかることを検証する
    ///
    /// 修正前は、マトウゾで経路が切れて探索が打ち切られ、間桐臓硯が見つからなかった
    func testLookupFromReadingStartFindsLongUserDictionaryWord() {
        let words = self.lookupWords(hiragana: "まとうぞうけんとまとうしんじ", dictionary: self.userDictionary(), needTypoCorrection: false)
        XCTAssertTrue(words.contains("間桐臓硯"))
        XCTAssertTrue(words.contains("間桐"))
    }

    /// 誤り訂正の探索を併用しても長い読みの登録語が見つかることを検証する
    ///
    /// 誤り訂正の生成器も同じ到達不能の通知で枝を刈るため、併用時も読みの全体まで届くことを確かめる
    func testLookupWithTypoCorrectionFindsLongUserDictionaryWord() {
        let words = self.lookupWords(hiragana: "まとうぞうけん", dictionary: self.userDictionary(), needTypoCorrection: true)
        XCTAssertTrue(words.contains("間桐臓硯"))
    }

    /// 登録語の読みと途中で分かれる入力では探索結果が変わらないことを検証する
    ///
    /// 登録語の読みと一致する範囲だけを到達可能として扱い、余計な語を混ぜない
    func testDivergingReadingKeepsLookupResultUnchanged() {
        let hiragana = "まとうぞうきんをあらう"
        let withDictionary = self.lookupWords(hiragana: hiragana, dictionary: self.userDictionary(), needTypoCorrection: false)
        let withoutDictionary = self.lookupWords(hiragana: hiragana, dictionary: [], needTypoCorrection: false)
        XCTAssertEqual(withDictionary.subtracting(["間桐"]), withoutDictionary)
    }

    /// 入力途中で変換を要求せずに全文を変換しても登録語が候補に出ることを検証する
    ///
    /// 修正前は、入力途中の変換要求が無いと増分探索の起点が読みの先頭になり、候補に出なかった
    func testConversionWithoutIntermediateRequestsShowsLongUserDictionaryWord() {
        let converter = self.makeConverter()
        var c = ComposingText()
        self.sequentialInput(&c, sequence: "matouzoukentomatousinnji")
        let texts = converter.requestCandidates(c, options: self.requestOptions()).mainResults.map(\.text)
        XCTAssertTrue(texts.contains("間桐臓硯"), "\(texts)")
    }

    /// 打鍵ごとに変換を要求した場合も従来どおり候補に出ることを検証する
    ///
    /// 増分探索が読みの全体から始まる経路でも結果を変えない
    func testConversionWithPerKeystrokeRequestsShowsLongUserDictionaryWord() {
        let converter = self.makeConverter()
        var c = ComposingText()
        var texts: [String] = []
        for char in "matouzoukentomatousinnji" {
            c.insertAtCursorPosition(String(char), inputStyle: .roman2kana)
            texts = converter.requestCandidates(c, options: self.requestOptions()).mainResults.map(\.text)
        }
        XCTAssertTrue(texts.contains("間桐臓硯"), "\(texts)")
    }

    /// 文節境界の調整でカーソルまでを変換しても登録語が候補に出ることを検証する
    ///
    /// hazkeyと同じくカーソルまでの読みで要求する。読みが縮むとラティスを作り直すため、修正前は読みの先頭からの探索で落ちていた
    func testMidCursorConversionShowsLongUserDictionaryWord() {
        let converter = self.makeConverter()
        var c = ComposingText()
        self.sequentialInput(&c, sequence: "matouzoukentomatousinnji")
        _ = converter.requestCandidates(c, options: self.requestOptions())
        _ = c.moveCursorFromCursorPosition(count: -7)
        let prefix = c.prefixToCursorPosition()
        XCTAssertEqual(prefix.convertTarget, "まとうぞうけん")
        let texts = converter.requestCandidates(prefix, options: self.requestOptions()).mainResults.map(\.text)
        XCTAssertEqual(texts.first, "間桐臓硯", "\(texts)")
    }
}
