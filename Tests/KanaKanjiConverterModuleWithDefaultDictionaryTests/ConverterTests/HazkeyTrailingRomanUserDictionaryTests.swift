import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

// [Hazkey Community Patch]
// 読みの末尾に未確定のローマ字 (例: ばn) が残る入力でも動的ユーザ辞書の語を予測候補に出すことの回帰テストをまとめる
// システム辞書は末尾のローマ字をInputTableのpossibleNextsで展開して引くが、動的ユーザ辞書は未展開のまま前方一致させていた
// そのため、"ばん"で登録した語がbanでは出なかった
/// 末尾ローマ字残りの入力での動的ユーザ辞書予測の回帰テストをまとめる
///
/// 末尾の未確定ローマ字を展開した読みでも辞書語を予測候補に出す
final class HazkeyTrailingRomanUserDictionaryTests: XCTestCase {
    /// 打鍵列を1文字ずつ入力する
    ///
    /// 実際の入力過程と同じく1文字ずつ積み、予測の増分計算を再現する
    ///
    /// - Parameters:
    ///   - composingText: 入力先の組成テキスト
    ///   - sequence: 打鍵列
    ///   - inputStyle: ローマ字かな変換などの入力方式
    private func sequentialInput(_ composingText: inout ComposingText, sequence: String, inputStyle: KanaKanjiConverterModule.InputStyle) {
        for char in sequence {
            composingText.insertAtCursorPosition(String(char), inputStyle: inputStyle)
        }
    }

    /// 検証用の変換要求を作る
    ///
    /// 予測は手動混合に固定し、学習や誤字訂正の影響を除く
    ///
    /// - Returns: 固定条件の変換要求
    private func requestOptions() -> ConvertRequestOptions {
        ConvertRequestOptions(
            N_best: 10,
            requireJapanesePrediction: .manualMix,
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

    /// 検証用の動的ユーザ辞書を作る
    ///
    /// "ん"で終わる読みと長い読みと英字混じりの読みを含み、各展開条件を1つの辞書で検証する
    ///
    /// - Returns: 検証語の辞書要素列
    private func userDictionary() -> [DicdataElement] {
        [
            DicdataElement(word: "登録版", ruby: "バン", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5),
            DicdataElement(word: "登録蘭", ruby: "ラン", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5),
            DicdataElement(word: "登録番組", ruby: "バングミ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5),
            DicdataElement(word: "登録英字", ruby: "バbq", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5),
        ]
    }

    /// 打鍵列の予測候補表記列を求める
    ///
    /// 動的ユーザ辞書を読み込んだ変換器へ1文字ずつ入力して、予測結果だけを取り出す
    ///
    /// - Parameters:
    ///   - sequence: 打鍵列
    ///   - inputStyle: ローマ字かな変換などの入力方式
    /// - Returns: 予測候補の表記列
    private func predictionTexts(for sequence: String, inputStyle: KanaKanjiConverterModule.InputStyle) -> [String] {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        converter.importDynamicUserDictionary(self.userDictionary())
        var c = ComposingText()
        self.sequentialInput(&c, sequence: sequence, inputStyle: inputStyle)
        return converter.requestCandidates(c, options: self.requestOptions()).predictionResults.map(\.text)
    }

    /// 末尾n1つでも登録語が予測候補に出ることを検証する
    ///
    /// roman2kanaとmappedのどちらの入力方式でも成り立つ
    func testUserDictionaryWordEndingWithNIsPredictedFromSingleTrailingN() {
        for inputStyle: KanaKanjiConverterModule.InputStyle in [.roman2kana, .mapped(id: .defaultRomanToKana)] {
            XCTAssertTrue(self.predictionTexts(for: "ban", inputStyle: inputStyle).contains("登録版"), "\(inputStyle)")
            XCTAssertTrue(self.predictionTexts(for: "ran", inputStyle: inputStyle).contains("登録蘭"), "\(inputStyle)")
        }
    }

    /// 末尾展開で前方一致の長い語も出ることを検証する
    ///
    /// 末尾ローマ字の展開で長い読みの語まで届く
    func testLongerUserDictionaryWordIsPredictedFromSingleTrailingN() {
        XCTAssertTrue(self.predictionTexts(for: "ban", inputStyle: .roman2kana).contains("登録番組"))
    }

    /// nnまで入力しても従来どおり予測することを検証する
    ///
    /// 展開済み読みでの前方一致は変えない
    func testDoubleNKeepsPredictingUserDictionaryWords() {
        let texts = self.predictionTexts(for: "bann", inputStyle: .roman2kana)
        XCTAssertTrue(texts.contains("登録版"))
        XCTAssertTrue(texts.contains("登録番組"))
    }

    /// 展開先が無い末尾ローマ字は未展開の読みで引くことを検証する
    ///
    /// 英字を含む読みで登録した語は従来どおり未展開の読みで当たる
    func testUnexpandableTrailingRomanKeepsRawReadingMatch() {
        XCTAssertTrue(self.predictionTexts(for: "babq", inputStyle: .roman2kana).contains("登録英字"))
    }

    /// 展開先に合わない語は出ないことを検証する
    ///
    /// 展開で余計な語を混ぜない
    func testUnrelatedUserDictionaryWordIsNotPredicted() {
        XCTAssertFalse(self.predictionTexts(for: "ban", inputStyle: .roman2kana).contains("登録蘭"))
    }
}
