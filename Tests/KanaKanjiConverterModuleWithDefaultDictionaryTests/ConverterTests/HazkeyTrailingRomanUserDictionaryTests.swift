import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

// [hazkey-community patch] 読みの末尾に未確定のローマ字 (例: 「ばn」) が残る入力でも、
// 動的ユーザ辞書の語を予測候補に出すことを検査する。
// システム辞書は末尾のローマ字を `InputTable.possibleNexts` で展開して引く (「ばn」→「バン」「バナ」…) が、
// 動的ユーザ辞書は「バn」のまま前方一致させていたため、「ばん」で登録した語が「ban」では出なかった。
final class HazkeyTrailingRomanUserDictionaryTests: XCTestCase {
    private func sequentialInput(_ composingText: inout ComposingText, sequence: String, inputStyle: KanaKanjiConverterModule.InputStyle) {
        for char in sequence {
            composingText.insertAtCursorPosition(String(char), inputStyle: inputStyle)
        }
    }

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

    private func userDictionary() -> [DicdataElement] {
        [
            DicdataElement(word: "登録版", ruby: "バン", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5),
            DicdataElement(word: "登録蘭", ruby: "ラン", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5),
            DicdataElement(word: "登録番組", ruby: "バングミ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5),
            DicdataElement(word: "登録英字", ruby: "バbq", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5),
        ]
    }

    private func predictionTexts(for sequence: String, inputStyle: KanaKanjiConverterModule.InputStyle) -> [String] {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        converter.importDynamicUserDictionary(self.userDictionary())
        var c = ComposingText()
        self.sequentialInput(&c, sequence: sequence, inputStyle: inputStyle)
        return converter.requestCandidates(c, options: self.requestOptions()).predictionResults.map(\.text)
    }

    /// 末尾が「n」1つでも、「ん」で終わる読みで登録した語が予測候補に出る。
    func testUserDictionaryWordEndingWithNIsPredictedFromSingleTrailingN() {
        for inputStyle: KanaKanjiConverterModule.InputStyle in [.roman2kana, .mapped(id: .defaultRomanToKana)] {
            XCTAssertTrue(self.predictionTexts(for: "ban", inputStyle: inputStyle).contains("登録版"), "\(inputStyle)")
            XCTAssertTrue(self.predictionTexts(for: "ran", inputStyle: inputStyle).contains("登録蘭"), "\(inputStyle)")
        }
    }

    /// 末尾のローマ字の展開でも、前方一致の長い読みの語が予測候補に出る。
    func testLongerUserDictionaryWordIsPredictedFromSingleTrailingN() {
        XCTAssertTrue(self.predictionTexts(for: "ban", inputStyle: .roman2kana).contains("登録番組"))
    }

    /// 「nn」まで入力した場合の挙動は従来どおり。
    func testDoubleNKeepsPredictingUserDictionaryWords() {
        let texts = self.predictionTexts(for: "bann", inputStyle: .roman2kana)
        XCTAssertTrue(texts.contains("登録版"))
        XCTAssertTrue(texts.contains("登録番組"))
    }

    /// 末尾のローマ字に展開先が無い場合 (「バbq」) は、英字を含む読みで登録した語を従来どおり未展開の読みで引く。
    func testUnexpandableTrailingRomanKeepsRawReadingMatch() {
        XCTAssertTrue(self.predictionTexts(for: "babq", inputStyle: .roman2kana).contains("登録英字"))
    }

    /// 末尾のローマ字の展開先に合わない語は出ない。
    func testUnrelatedUserDictionaryWordIsNotPredicted() {
        XCTAssertFalse(self.predictionTexts(for: "ban", inputStyle: .roman2kana).contains("登録蘭"))
    }
}
