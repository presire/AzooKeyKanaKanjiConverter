import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

// [hazkey-community patch] Zenzai 要求中でカーソル途中の変換を、カーソルまでの読みで後処理することを検査する。
// 実モデルは使わず、`SharedZenzModelCache.modelConstructor` を常に失敗するクロージャへ差し替えて
// 非Zenzai経路へのフォールバックを再現する (llama-mockのモデル読込はfatalErrorになるため)。
final class HazkeyMidCursorConversionTargetTests: XCTestCase {
    private struct SentinelConstructionError: Error {}

    override func setUp() {
        SharedZenzModelCache.modelConstructor = { _, _ in
            throw SentinelConstructionError()
        }
        super.setUp()
    }

    override func tearDown() {
        SharedZenzModelCache.modelConstructor = SharedZenzModel.init
        super.tearDown()
    }

    /// 「にほんご」のカーソルを2文字戻す (カーソルまでの読みは「にほ」)。
    private func midCursorComposingText() -> ComposingText {
        var c = ComposingText()
        c.insertAtCursorPosition("にほんご", inputStyle: .direct)
        _ = c.moveCursorFromCursorPosition(count: -2)
        return c
    }

    private func endCursorComposingText() -> ComposingText {
        var c = ComposingText()
        c.insertAtCursorPosition("にほんご", inputStyle: .direct)
        return c
    }

    private func zenzaiModeOn() -> ConvertRequestOptions.ZenzaiMode {
        .on(
            weight: URL(fileURLWithPath: "/tmp/hazkey-mid-cursor-conversion-target-\(UUID().uuidString).gguf"),
            personalizationMode: nil
        )
    }

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

    /// (a) Zenzai要求中・カーソル途中・モデル読込失敗のとき、候補はカーソルまでの読みに収まる。
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

    /// (b) 同じセッションで、カーソル途中のZenzai要求の後にZenzai OFFの要求をしても、
    /// セッション状態が不整合にならず、新規変換器と同じ結果になる。
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

        // 同じ変換器で全文・カーソル途中のZenzai要求を2回続けると、2回目の結果が1回目と一致する。
        let repeatConverter = KanaKanjiConverter.withDefaultDictionary()
        let first = repeatConverter.requestCandidates(input, options: requestOptions(zenzaiMode: zenzaiModeOn()))
        let secondOfSameRequest = repeatConverter.requestCandidates(input, options: requestOptions(zenzaiMode: zenzaiModeOn()))
        XCTAssertEqual(
            secondOfSameRequest.mainResults.map(\.text),
            first.mainResults.map(\.text),
            "同一セッションで同じZenzai要求を2回行ったとき、結果が変化してはならない"
        )
    }

    /// (c) Zenzai OFFのときは、カーソル途中でも全文の読みの候補が保たれる (上流の挙動の回帰ガード)。
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

    private func composingText(_ string: String) -> ComposingText {
        var c = ComposingText()
        c.insertAtCursorPosition(string, inputStyle: .direct)
        return c
    }

    /// (e) Zenzai由来ラティスを破棄する再構築では確定状態も破棄することの回帰検査。
    /// 部分確定 → フォールバック再構築 → 編集の順で、破棄済みZenzaiラティスに属する
    /// 古い completedData が kana2lattice_afterComplete に再利用されないことを検査する。
    func testDiscardingZenzaiLatticeAlsoClearsCompletedData() {
        let options = requestOptions(zenzaiMode: .off)
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let full = composingText("わたしはがくせいです")
        let first = converter.requestCandidates(full, options: options)
        XCTAssertFalse(first.mainResults.isEmpty, "前提: 全文の変換候補が空であってはならない")
        // 部分確定を再現する: 先頭候補を確定状態として積む。
        converter.setCompletedData(first.mainResults[0])
        // Zenzai由来ラティスが残っている状態を再現する (実モデルは使えないため印だけ立てる)。
        converter.updateCurrentSessionState { $0.latticeIsFromZenzai = true }
        // フォールバック再構築: 非Zenzai要求で編集済み入力を変換する。
        let truncated = composingText("わたしはがくせい")
        _ = converter.requestCandidates(truncated, options: options)
        // 次の編集は再構築後入力の接尾辞 → 古い確定状態が残っていると afterComplete 経路に入る。
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

    /// (d) 変換対象の選択の純関数の表検査。
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
