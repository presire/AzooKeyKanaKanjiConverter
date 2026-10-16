import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

// [Hazkey Community Patch]
// 一時学習 (保存前の学習) の語が、1文字ずつの差分変換でも全文変換と同じく使われることの回帰テストをまとめる
// 一時学習の木は0始まりの終端位置 (語の長さ - 1) をキーに返し、DicdataStoreは語の長さとして絞り込んでいた
// そのため、差分変換で最後に打った文字で終わる学習語が落ち、全文変換とだけ結果が食い違っていた
/// 一時学習の語の差分変換での参照の回帰テストをまとめる
///
/// 学習直後に1文字ずつ入力して変換しても、全文変換と同じく学習した表記が先頭になる
final class HazkeyTemporaryMemoryIncrementalLookupTests: XCTestCase {
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
            .appendingPathComponent("hazkey-temporary-memory-incremental-\(UUID().uuidString)", isDirectory: true)
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

    /// 検証用の変換要求を作る
    ///
    /// 学習は入出力とも有効にし、予測・誤字訂正・Zenzaiは無効にして本変換の辞書参照だけを比べる
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
            learningType: .inputAndOutput,
            maxMemoryCount: 100,
            shouldResetMemory: false,
            memoryDirectoryURL: self.memoryDirectoryURL,
            sharedContainerURL: URL(fileURLWithPath: ""),
            textReplacer: .empty,
            specialCandidateProviders: [],
            zenzaiMode: .off,
            typoCorrectionMode: .disabled,
            metadata: nil
        )
    }

    /// 読み全体を一度に入れた組成テキストを作る
    ///
    /// 新しい組成の最初の変換は全文変換 (kana2lattice_all) になる
    ///
    /// - Parameter reading: 読み
    /// - Returns: 読み全体を持つ組成テキスト
    private func wholeComposingText(_ reading: String) -> ComposingText {
        var c = ComposingText()
        c.insertAtCursorPosition(reading, inputStyle: .direct)
        return c
    }

    /// 1文字ずつ入力しながら毎回変換し、最後の変換結果を返す
    ///
    /// 2文字目以降は直前の入力との差分変換 (kana2lattice_changed) になる
    ///
    /// - Parameters:
    ///   - converter: 変換器
    ///   - reading: 読み
    ///   - options: 変換要求
    /// - Returns: 読み全体を入力した時点の変換結果
    private func incrementalConversion(
        _ converter: KanaKanjiConverter,
        reading: String,
        options: ConvertRequestOptions
    ) -> ConversionResult {
        var c = ComposingText()
        var result: ConversionResult?
        for char in reading {
            c.insertAtCursorPosition(String(char), inputStyle: .direct)
            result = converter.requestCandidates(c, options: options)
        }
        return result!
    }

    /// 学習前の先頭ではない1語の候補を選び直したものとして一時学習する
    ///
    /// 読み全体を1語で覆う候補から選び、学習の保存はしない
    ///
    /// - Parameters:
    ///   - reading: 検証する読み
    ///   - converter: 変換器
    ///   - options: 変換要求
    /// - Returns: 学習した候補と学習前の先頭の表記。前提を満たす候補が無ければ nil
    private func learnNonTopSingleWordCandidate(
        reading: String,
        converter: KanaKanjiConverter,
        options: ConvertRequestOptions,
        file: StaticString,
        line: UInt
    ) -> (chosen: Candidate, baselineTop: String)? {
        let baseline = converter.requestCandidates(self.wholeComposingText(reading), options: options)
        guard let baselineTop = baseline.mainResults.first else {
            XCTFail("前提: \(reading) の変換候補が空であってはならない", file: file, line: line)
            return nil
        }
        guard let chosen = baseline.mainResults.first(where: {
            $0.text != baselineTop.text && $0.data.count == 1 && $0.rubyCount == reading.count
        }) else {
            XCTFail("前提: \(reading) に先頭以外の1語の候補が無い", file: file, line: line)
            return nil
        }
        converter.updateLearningData(chosen)
        converter.stopComposition()
        return (chosen, baselineTop.text)
    }

    /// 学習前の先頭ではない1語の候補を学習し、全文変換と差分変換の先頭を比べる
    ///
    /// - Parameter reading: 検証する読み
    private func assertIncrementalConversionUsesTemporaryMemory(reading: String, file: StaticString = #filePath, line: UInt = #line) {
        let options = self.requestOptions()
        let converter = KanaKanjiConverter.withDefaultDictionary()
        guard let (chosen, baselineTop) = self.learnNonTopSingleWordCandidate(
            reading: reading, converter: converter, options: options, file: file, line: line
        ) else {
            return
        }

        let whole = converter.requestCandidates(self.wholeComposingText(reading), options: options)
        XCTAssertEqual(
            whole.mainResults.first?.text, chosen.text,
            "前提: 学習直後の全文変換では、学習した \(chosen.text) が先頭になるべき (学習前の先頭は \(baselineTop))",
            file: file, line: line
        )
        converter.stopComposition()

        let incremental = self.incrementalConversion(converter, reading: reading, options: options)
        XCTAssertEqual(
            incremental.mainResults.first?.text, chosen.text,
            "学習直後に1文字ずつ入力した差分変換でも、全文変換と同じく学習した \(chosen.text) が先頭になるべき",
            file: file, line: line
        )
    }

    /// 読みの最後に打った文字で終わる一時学習の語が、差分変換で落ちないことを検証する
    ///
    /// 修正前は語の長さと差分変換の最小の長さが等しいときに絞り込みで落ちていた
    func testIncrementalConversionUsesTemporaryMemoryEndingAtLastCharacter() {
        self.assertIncrementalConversionUsesTemporaryMemory(reading: "きかい")
        self.assertIncrementalConversionUsesTemporaryMemory(reading: "こうえん")
    }

    /// 長さ1の一時学習の語が、全文変換で落ちないことを検証する
    ///
    /// 修正前は長さ1の語のキーが0になり、全文変換でも絞り込み (minCount = 1) で落ちていた
    func testWholeConversionUsesSingleCharacterTemporaryMemory() {
        let options = self.requestOptions()
        let converter = KanaKanjiConverter.withDefaultDictionary()
        guard let (chosen, baselineTop) = self.learnNonTopSingleWordCandidate(
            reading: "き", converter: converter, options: options, file: #filePath, line: #line
        ) else {
            return
        }

        let whole = converter.requestCandidates(self.wholeComposingText("き"), options: options)
        XCTAssertEqual(
            whole.mainResults.first?.text, chosen.text,
            "学習直後の全文変換では、長さ1の学習語 \(chosen.text) が先頭になるべき (学習前の先頭は \(baselineTop))"
        )
    }

    /// 誤字訂正で得た読み (ペナルティが0でない読み) でも、最後の文字で終わる一時学習の語が落ちないことを検証する
    ///
    /// 辞書参照を直接呼び、終端位置の範囲を最後の1文字に限った差分変換と同じ条件で調べる
    func testLookupWithTypoCorrectionFindsTemporaryMemoryEndingAtLastCharacter() {
        let dicdataStore = DicdataStore.withDefaultDictionary()
        let state = dicdataStore.prepareState()
        state.updateLearningConfig(.init(learningType: .inputAndOutput, maxMemoryCount: 100, memoryURL: self.memoryDirectoryURL))
        // 辞書に無い表記にして、見つかった場合の出所を一時学習に限る
        let learned = DicdataElement(word: "儀考", ruby: "ギコウ", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        state.learningMemoryManager.update(data: [learned])

        /// 直接入力した読みを、終端位置を最後の1文字に限って辞書参照する
        func lookup(_ reading: String, needTypoCorrection: Bool) -> [String] {
            var c = ComposingText()
            c.insertAtCursorPosition(reading, inputStyle: .direct)
            return dicdataStore.lookupDicdata(
                composingText: c,
                inputRange: (0, c.input.endIndex - 1 ..< c.input.endIndex),
                surfaceRange: (0, c.convertTarget.count - 1 ..< c.convertTarget.count),
                needTypoCorrection: needTypoCorrection,
                state: state
            ).map(\.data.word)
        }

        XCTAssertTrue(
            lookup("ぎこう", needTypoCorrection: false).contains(learned.word),
            "ペナルティ0の読みで、最後の文字で終わる一時学習の語 \(learned.word) が見つかるべき"
        )
        XCTAssertFalse(
            lookup("きこう", needTypoCorrection: false).contains(learned.word),
            "前提: 誤字訂正なしでは、きこう から \(learned.word) は見つからない"
        )
        XCTAssertTrue(
            lookup("きこう", needTypoCorrection: true).contains(learned.word),
            "誤字訂正 (キ→ギ) で得たペナルティのある読みでも、最後の文字で終わる一時学習の語 \(learned.word) が見つかるべき"
        )
    }
}
