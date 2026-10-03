import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

// [Hazkey Community Patch]
// Zenzai要求中でカーソル途中の変換をカーソルまでの読みで後処理することの回帰テストをまとめる
// 実モデルは使わず、SharedZenzModelCacheのmodelConstructorを常に失敗する差し替えで非Zenzai経路へのフォールバックを再現する
// llama-mockのモデル読込はfatalErrorになるため
/// Zenzai要求中のカーソル途中変換の回帰テストをまとめる
///
/// モデル読込失敗時はカーソルまでの読みで後処理し、セッション状態を壊さない
final class HazkeyMidCursorConversionTargetTests: XCTestCase {
    /// 構築の差し替え口へ到達したことを観測するための送出用エラー
    ///
    /// わざと失敗させて非Zenzai経路へのフォールバックを再現する
    private struct SentinelConstructionError: Error {}

    /// 全テストでモデル構築を常に失敗する差し替えに置き換える
    ///
    /// モデル読込失敗時のフォールバック経路を実モデルなしで再現する
    override func setUp() {
        SharedZenzModelCache.modelConstructor = { _, _ in
            throw SentinelConstructionError()
        }
        super.setUp()
    }

    /// モデル構築を製品の初期化子へ戻す
    ///
    /// 他のテストへ差し替えが漏れないようにする
    override func tearDown() {
        SharedZenzModelCache.modelConstructor = SharedZenzModel.init
        super.tearDown()
    }

    /// カーソル途中の入力を作る
    ///
    /// にほんごのカーソルを2文字戻し、カーソルまでの読みをにほにする
    private func midCursorComposingText() -> ComposingText {
        var c = ComposingText()
        c.insertAtCursorPosition("にほんご", inputStyle: .direct)
        _ = c.moveCursorFromCursorPosition(count: -2)
        return c
    }

    /// カーソル末尾の入力を作る
    ///
    /// 全文変換の対照条件に使う
    private func endCursorComposingText() -> ComposingText {
        var c = ComposingText()
        c.insertAtCursorPosition("にほんご", inputStyle: .direct)
        return c
    }

    /// Zenzai有効の変換モードを作る
    ///
    /// 重みパスは実在しなくてもよく、差し替えの失敗でフォールバックに入る
    ///
    /// - Returns: 一時パスの重みを指すZenzai有効モード
    private func zenzaiModeOn() -> ConvertRequestOptions.ZenzaiMode {
        .on(
            weight: URL(fileURLWithPath: "/tmp/hazkey-mid-cursor-conversion-target-\(UUID().uuidString).gguf"),
            personalizationMode: nil
        )
    }

    /// 検証用の変換要求を作る
    ///
    /// Zenzai条件以外は固定し、学習や誤字訂正の影響を除く
    ///
    /// - Parameter zenzaiMode: 検証したいZenzai条件
    /// - Returns: 固定条件の変換要求
    private func requestOptions(zenzaiMode: ConvertRequestOptions.ZenzaiMode) -> ConvertRequestOptions {
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
            zenzaiMode: zenzaiMode,
            typoCorrectionMode: .disabled,
            metadata: nil
        )
    }

    /// モデル読込失敗時はカーソルまでの読みだけを変換することを検証する (a)
    ///
    /// 候補の読みがカーソル位置を超えず、カーソルまでの読みの新規変換と一致する
    func testZenzaiRequestWithMidCursorConvertsOnlyTheCursorPrefixWhenModelFailsToLoad() {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let input = midCursorComposingText()
        let result = converter.requestCandidates(input, options: requestOptions(zenzaiMode: zenzaiModeOn()))

        for candidate in result.mainResults {
            XCTAssertLessThanOrEqual(
                candidate.rubyCount, 2,
                "mainResultsの候補 \(candidate.text) の読みがカーソルまでの読み (2文字) を超えています"
            )
        }
        for candidate in result.firstClauseResults {
            XCTAssertLessThanOrEqual(
                candidate.rubyCount, 2,
                "firstClauseResultsの候補 \(candidate.text) の読みがカーソルまでの読み (2文字) を超えています"
            )
        }

        let reference = KanaKanjiConverter.withDefaultDictionary()
        let referenceResult = reference.requestCandidates(
            input.prefixToCursorPosition(),
            options: requestOptions(zenzaiMode: zenzaiModeOn())
        )
        XCTAssertEqual(
            result.mainResults.map(\.text),
            referenceResult.mainResults.map(\.text),
            "カーソル途中のZenzai要求の結果は、カーソルまでの読みだけを新規変換した結果と一致するべき"
        )
    }

    /// カーソル途中のZenzai要求後もセッション状態が保たれることを検証する (b)
    ///
    /// 続くZenzai OFF要求が新規変換器と同じ結果になり、同じZenzai要求の再送も結果を変えない
    func testSessionStateStaysConsistentAfterMidCursorZenzaiRequest() {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let input = midCursorComposingText()
        _ = converter.requestCandidates(input, options: requestOptions(zenzaiMode: zenzaiModeOn()))
        let second = converter.requestCandidates(
            input.prefixToCursorPosition(),
            options: requestOptions(zenzaiMode: .off)
        )

        let reference = KanaKanjiConverter.withDefaultDictionary()
        let referenceResult = reference.requestCandidates(
            input.prefixToCursorPosition(),
            options: requestOptions(zenzaiMode: .off)
        )
        XCTAssertEqual(
            second.mainResults.map(\.text),
            referenceResult.mainResults.map(\.text),
            "Zenzai要求の後のZenzai OFF変換は、新規変換器の結果と一致するべき"
        )
        XCTAssertEqual(
            second.mainResults.count,
            referenceResult.mainResults.count,
            "Zenzai要求の後のZenzai OFF変換は、新規変換器と同じ件数の候補を返すべき"
        )

        // 同じ変換器で全文・カーソル途中のZenzai要求を2回続けると、2回目の結果が1回目と一致する
        let repeatConverter = KanaKanjiConverter.withDefaultDictionary()
        let first = repeatConverter.requestCandidates(input, options: requestOptions(zenzaiMode: zenzaiModeOn()))
        let secondOfSameRequest = repeatConverter.requestCandidates(input, options: requestOptions(zenzaiMode: zenzaiModeOn()))
        XCTAssertEqual(
            secondOfSameRequest.mainResults.map(\.text),
            first.mainResults.map(\.text),
            "同一セッションで同じZenzai要求を2回行ったとき、結果が変化してはならない"
        )
    }

    /// Zenzai OFFではカーソル途中でも全文を変換することを検証する (c)
    ///
    /// 上流の挙動を保つ回帰ガードであり、全文読みの候補が少なくとも1つある
    func testZenzaiOffKeepsFullInputConversionForMidCursor() {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let result = converter.requestCandidates(
            midCursorComposingText(),
            options: requestOptions(zenzaiMode: .off)
        )
        XCTAssertTrue(
            result.mainResults.contains { $0.rubyCount == 4 },
            "Zenzai OFFでは全文 (4文字) の読みに対応する候補が少なくとも1つあるべき"
        )
    }

    /// 指定した読みのComposingTextを作る
    ///
    /// 部分確定後の接尾辞編集の再現に使う
    ///
    /// - Parameter string: カーソル末尾に挿入する読み
    /// - Returns: 指定した読みを持つComposingText
    private func composingText(_ string: String) -> ComposingText {
        var c = ComposingText()
        c.insertAtCursorPosition(string, inputStyle: .direct)
        return c
    }

    /// Zenzai由来ラティスの破棄再構築では確定状態も捨てることを検証する (e)
    ///
    /// 部分確定の後にフォールバック再構築と編集が続いても、破棄済みラティスに属する古い確定状態がkana2lattice_afterComplete経路に再利用されない
    func testDiscardingZenzaiLatticeAlsoClearsCompletedData() {
        let options = requestOptions(zenzaiMode: .off)
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let full = composingText("わたしはがくせいです")
        let first = converter.requestCandidates(full, options: options)
        XCTAssertFalse(first.mainResults.isEmpty, "前提: 全文の変換候補が空であってはならない")
        // 部分確定を再現する: 先頭候補を確定状態として積む
        converter.setCompletedData(first.mainResults[0])
        // Zenzai由来ラティスが残っている状態を再現する (実モデルは使えないため印だけ立てる)。
        converter.updateCurrentSessionState { $0.latticeIsFromZenzai = true }
        // フォールバック再構築: 非Zenzai要求で編集済み入力を変換する。
        let truncated = composingText("わたしはがくせい")
        _ = converter.requestCandidates(truncated, options: options)
        // 次の編集は再構築後入力の接尾辞であり、古い確定状態が残っているとafterComplete経路に入る
        let final = composingText("はがくせい")
        let actual = converter.requestCandidates(final, options: options)

        let reference = KanaKanjiConverter.withDefaultDictionary()
        let expected = reference.requestCandidates(final, options: options)
        XCTAssertEqual(
            actual.mainResults.map(\.text),
            expected.mainResults.map(\.text),
            "再構築後の接尾辞編集の結果は、新規変換器の結果と一致するべき"
        )
        XCTAssertEqual(
            actual.firstClauseResults.map(\.text),
            expected.firstClauseResults.map(\.text),
            "再構築後の接尾辞編集の firstClauseResults は、新規変換器の結果と一致するべき"
        )
    }

    /// 変換対象選択の純関数の対応表を検証する (d)
    ///
    /// Zenzai要求ありとカーソル途中の組み合わせだけがカーソルまでの読みになり、他は全文になる
    func testPureConversionTargetSelection() {
        let midCursor = midCursorComposingText()
        let endCursor = endCursorComposingText()

        // Zenzai要求あり + カーソル途中 → カーソルまでの読み
        XCTAssertEqual(
            Kana2Kanji.hazkeyConversionTarget(for: midCursor, zenzaiRequested: true),
            midCursor.prefixToCursorPosition()
        )
        // Zenzai要求なし → 全文 (カーソル位置は問わない)
        XCTAssertEqual(
            Kana2Kanji.hazkeyConversionTarget(for: midCursor, zenzaiRequested: false),
            midCursor
        )
        // カーソル末尾 → 全文 (isAtEndIndexで全文がそのまま返る)
        XCTAssertEqual(
            Kana2Kanji.hazkeyConversionTarget(for: endCursor, zenzaiRequested: true),
            endCursor
        )
        XCTAssertEqual(
            Kana2Kanji.hazkeyConversionTarget(for: endCursor, zenzaiRequested: false),
            endCursor
        )
    }
}
