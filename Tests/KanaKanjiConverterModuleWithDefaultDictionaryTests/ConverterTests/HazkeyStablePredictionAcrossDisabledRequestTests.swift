import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import SwiftUtils
import XCTest

// [Hazkey Community Patch]
// 予測なしの要求 ([Space] の変換) を挟んでも、入力中に作った予測候補のキャッシュが残ることの回帰テストをまとめる
// hazkey は同じ変換セッションに、予測ありのサジェストと予測なしの [Space] の変換を交互に送る
// 上流は予測なしの要求でキャッシュを消していたため、[Esc] で入力中の表示へ戻すと予測候補が消えたり並びが変わったりした
/// 予測なしの要求を挟んだ後の予測候補の回帰テストをまとめる
///
/// 予測なしの要求の後に予測ありの要求を再び送ると、その前と同じ予測候補が返る
final class HazkeyStablePredictionAcrossDisabledRequestTests: XCTestCase {
    /// 検証用の変換要求を作る
    ///
    /// 学習・誤字訂正・Zenzaiは無効にして、予測候補のキャッシュの効果だけを比べる
    ///
    /// - Parameter prediction: 日本語の予測の要求方法 (サジェストは manualMix、[Space] の変換は disabled)
    /// - Returns: 固定条件の変換要求
    private func requestOptions(_ prediction: ConvertRequestOptions.PredictionMode) -> ConvertRequestOptions {
        ConvertRequestOptions(
            N_best: 10,
            requireJapanesePrediction: prediction,
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

    /// 1文字ずつ入力しながら毎回予測ありで変換し、最後の変換結果を返す
    ///
    /// hazkey が打鍵ごとに送るサジェストと同じ順序で要求する
    ///
    /// - Parameters:
    ///   - converter: 変換器
    ///   - composingText: 入力を追加する組成テキスト
    ///   - reading: 追加する読み
    /// - Returns: 読み全体を入力した時点の変換結果
    private func typeWithSuggestions(
        _ converter: KanaKanjiConverter,
        composingText: inout ComposingText,
        reading: String
    ) -> ConversionResult {
        var result: ConversionResult?
        for char in reading {
            composingText.insertAtCursorPosition(String(char), inputStyle: .direct)
            result = converter.requestCandidates(composingText, options: self.requestOptions(.manualMix))
        }
        return result!
    }

    /// 読み全体を一度に入れて、予測ありで1回だけ変換する
    ///
    /// 新しい変換器を使うため、予測候補のキャッシュは空の状態で計算される
    ///
    /// - Parameter reading: 読み
    /// - Returns: 変換結果
    private func suggestOnce(_ reading: String) -> ConversionResult {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(reading, inputStyle: .direct)
        return converter.requestCandidates(composingText, options: self.requestOptions(.manualMix))
    }

    /// 1文字ずつのサジェスト → 予測なしの変換 → サジェストの順に要求し、前後の予測候補の表記を返す
    ///
    /// - Parameter reading: 読み
    /// - Returns: 予測なしの変換の前と後の、予測候補の表記の列
    private func predictionsAroundDisabledRequest(_ reading: String) -> (before: [String], after: [String]) {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        var composingText = ComposingText()
        let before = self.typeWithSuggestions(converter, composingText: &composingText, reading: reading)
        _ = converter.requestCandidates(composingText, options: self.requestOptions(.disabled))
        let after = converter.requestCandidates(composingText, options: self.requestOptions(.manualMix))
        return (before.predictionResults.map(\.text), after.predictionResults.map(\.text))
    }

    /// 入力の途中で予測なしの要求を挟んでも、その後の打鍵の予測候補が変わらない
    ///
    /// [Space] → [Esc] の後に入力を続ける場面にあたる
    ///
    /// ちゅうしゃじょ の時点で作った予測候補 (駐車上記) は、う を打った後もキャッシュから持ち越される
    ///
    /// 修正前は予測なしの要求でキャッシュが消え、続けて う を打つと予測候補が0件になった
    func testDisabledPredictionRequestKeepsStablePredictionCache() {
        let prefix = "ちゅうしゃじょ"
        let suffix = "う"

        // 予測なしの要求を挟まない基準
        let baselineConverter = KanaKanjiConverter.withDefaultDictionary()
        var baselineText = ComposingText()
        _ = self.typeWithSuggestions(baselineConverter, composingText: &baselineText, reading: prefix)
        let baseline = self.typeWithSuggestions(baselineConverter, composingText: &baselineText, reading: suffix)
            .predictionResults.map(\.text)
        // 前提: 基準には、キャッシュから持ち越した予測候補がある
        let once = self.suggestOnce(prefix + suffix).predictionResults.map(\.text)
        XCTAssertFalse(baseline.isEmpty, "\(prefix + suffix) を1文字ずつ要求しても予測候補が出ない")
        XCTAssertNotEqual(baseline, once, "\(prefix + suffix) の予測候補がキャッシュに依存しなくなった")

        let converter = KanaKanjiConverter.withDefaultDictionary()
        var composingText = ComposingText()
        _ = self.typeWithSuggestions(converter, composingText: &composingText, reading: prefix)
        _ = converter.requestCandidates(composingText, options: self.requestOptions(.disabled))
        let resumed = self.typeWithSuggestions(converter, composingText: &composingText, reading: suffix)
            .predictionResults.map(\.text)

        XCTAssertEqual(resumed, baseline)
    }

    /// 予測なしの要求を挟んでも、キャッシュにだけある予測候補が残る
    ///
    /// ちゅうしゃじょう は、1文字ずつ要求すると途中の ちゅうしゃじょ で作った予測候補 (駐車上記) がキャッシュから持ち越され、最後に1回だけ要求すると予測候補が出ない
    ///
    /// 修正前は予測なしの要求でキャッシュが消え、再要求すると予測候補が0件になった
    func testDisabledRequestRestoresHistoryDependentPredictions() {
        let reading = "ちゅうしゃじょう"
        let incremental = self.predictionsAroundDisabledRequest(reading)
        let once = self.suggestOnce(reading).predictionResults.map(\.text)
        // 前提: 1文字ずつ要求した場合だけ予測候補が出る
        XCTAssertFalse(incremental.before.isEmpty, "\(reading) を1文字ずつ要求しても予測候補が出ない")
        XCTAssertNotEqual(incremental.before, once, "\(reading) の予測候補がキャッシュに依存しなくなった")

        XCTAssertEqual(incremental.after, incremental.before)
    }

    /// 予測なしの要求の後に読みが分岐した場合、分岐後の読みに合わない予測候補を返さない
    ///
    /// キャッシュは残すが、使うたびに現在の読みとの整合を確かめるため、古い予測候補は出ない
    func testStaleCacheIsNotReturnedAfterReadingDiverges() {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        var composingText = ComposingText()
        let before = self.typeWithSuggestions(converter, composingText: &composingText, reading: "ちゅうしゃじょう")
        // 前提: 分岐前の予測候補に、分岐後の読みと合わない 駐車上記 (チュウシャジョウキ) がある
        XCTAssertTrue(before.predictionResults.map(\.text).contains("駐車上記"), "分岐前の予測候補に 駐車上記 が無い")
        _ = converter.requestCandidates(composingText, options: self.requestOptions(.disabled))

        // 末尾の う を お に置き換え、キャッシュ作成時の読みで始まらない読みにする
        composingText.deleteBackwardFromCursorPosition(count: 1)
        composingText.insertAtCursorPosition("お", inputStyle: .direct)
        let diverged = converter.requestCandidates(composingText, options: self.requestOptions(.manualMix))

        let currentRuby = composingText.convertTarget.toKatakana()
        for candidate in diverged.predictionResults {
            let ruby = candidate.data.reduce(into: "") { $0 += $1.ruby }
            XCTAssertTrue(ruby.hasPrefix(currentRuby), "読みの合わない予測候補 \(candidate.text) (\(ruby)) が返った")
        }
        XCTAssertFalse(diverged.predictionResults.map(\.text).contains("駐車上記"))
    }
}
