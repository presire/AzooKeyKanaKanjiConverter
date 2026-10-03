// [Hazkey Community Patch]
// リッチ評価で前回のロジット行を使い回す範囲 (A7) を検証する
// 範囲はプロンプトが同じかどうかではなく、トークン列が実際に一致した長さで決まる
@testable import KanaKanjiConverterModule
import XCTest

/// `ZenzContext.richLogitsReusePlan(previousTokens:previousLogitsStart:tokens:logitsStart:)` の回帰テストをまとめる
final class HazkeyRichLogitsReusePlanTests: XCTestCase {
    private func plan(
        previous: [Int32],
        previousStart: Int,
        tokens: [Int32],
        start: Int
    ) -> ZenzContext.RichLogitsReusePlan? {
        ZenzContext.richLogitsReusePlan(
            previousTokens: previous,
            previousLogitsStart: previousStart,
            tokens: tokens,
            logitsStart: start
        )
    }

    /// 一致した長さまで使い回し、それ以降の位置から読ませる
    func testReusesUpToTheActuallyMatchedTokenLength() {
        let result = plan(previous: [1, 2, 3, 4, 5, 6], previousStart: 2, tokens: [1, 2, 3, 4, 9, 9, 9], start: 2)
        XCTAssertEqual(result, .init(feedStart: 4))
    }

    /// 今回のトークン列が前回の先頭部分なら、全ての位置で使い回す (モデルを実行しない)
    func testReusesEveryRowWhenTokensArePrefixOfPrevious() {
        let result = plan(previous: [1, 2, 3, 4, 5, 6], previousStart: 2, tokens: [1, 2, 3, 4], start: 2)
        XCTAssertEqual(result, .init(feedStart: 4))
        let identical = plan(previous: [1, 2, 3, 4], previousStart: 2, tokens: [1, 2, 3, 4], start: 2)
        XCTAssertEqual(identical, .init(feedStart: 4))
    }

    /// 一致がロジットの開始位置を越えなければ使い回さない (同じプロンプトでも候補の先頭が違えば使えない)
    func testDoesNotReuseWhenMatchDoesNotPassTheLogitsStart() {
        XCTAssertNil(plan(previous: [1, 2, 3, 4, 5], previousStart: 2, tokens: [1, 2, 3, 7, 8], start: 3))
        XCTAssertNil(plan(previous: [1, 2, 3, 4, 5], previousStart: 2, tokens: [1, 2, 9, 9, 9], start: 2))
        XCTAssertNil(plan(previous: [], previousStart: 0, tokens: [1, 2, 3], start: 0))
    }

    /// 前回の行が今回の開始位置より後ろからしか無いときは使い回さない
    func testDoesNotReuseWhenPreviousRowsStartLater() {
        XCTAssertNil(plan(previous: [1, 2, 3, 4, 5, 6], previousStart: 3, tokens: [1, 2, 3, 4, 5, 6], start: 2))
    }

    /// 前回より後ろの開始位置でも、一致した範囲の行を使い回す
    func testReusesWhenCurrentStartIsLaterThanPrevious() {
        let result = plan(previous: [1, 2, 3, 4, 5, 6], previousStart: 1, tokens: [1, 2, 3, 4, 5, 7], start: 3)
        XCTAssertEqual(result, .init(feedStart: 5))
    }
}

/// `RichLogitsRowStore` (リッチ評価のロジット行の保持) の回帰テストをまとめる
///
/// 位置 `p` の行の値は `p * 100 + 列` とし、集めた行が正しい位置のものかを値で確かめる
final class HazkeyRichLogitsRowStoreTests: XCTestCase {
    private let width = 3

    /// 位置 `positions` の行を並べた値
    private func rows(_ positions: Range<Int>) -> [Float] {
        positions.flatMap { position in (0..<width).map { Float(position * 100 + $0) } }
    }

    /// 領域の先頭から `count` 行を読む
    private func read(_ buffer: UnsafeMutablePointer<Float>?, rowCount count: Int) -> [Float]? {
        buffer.map { Array(UnsafeBufferPointer(start: $0, count: count * width)) }
    }

    /// 位置 `logitsStart..<tokens.count` の行を、使い回す行と今回計算した行から集める
    private func assemble(
        _ store: RichLogitsRowStore,
        tokens: [Int32],
        start: Int,
        reused: RichLogitsRowStore.ReusedRows?
    ) -> UnsafeMutablePointer<Float>? {
        let freshStart = start + (reused?.rowCount ?? 0)
        let fresh = rows(freshStart..<tokens.count)
        return fresh.withUnsafeBufferPointer {
            store.assemble(tokens: tokens, logitsStart: start, reusedRows: reused, freshRows: fresh.isEmpty ? nil : $0.baseAddress)
        }
    }

    /// 使い回さないときは、今回計算した行をそのまま並べて記録する
    func testAssembleWithoutReuseCopiesFreshRows() {
        let store = RichLogitsRowStore(rowWidth: width)
        let buffer = assemble(store, tokens: [1, 2, 3, 4], start: 1, reused: nil)
        XCTAssertEqual(read(buffer, rowCount: 3), rows(1..<4))
        XCTAssertEqual(store.record?.tokens, [1, 2, 3, 4])
        XCTAssertEqual(store.record?.logitsStart, 1)
    }

    /// 領域を広げ直しても使い回す行が残り、その後ろに今回計算した行が並ぶ
    func testGrowingTheBufferKeepsReusedRows() {
        let store = RichLogitsRowStore(rowWidth: width)
        _ = assemble(store, tokens: [1, 2, 3], start: 1, reused: nil)
        XCTAssertEqual(store.capacity, 2 * width)
        let buffer = assemble(store, tokens: [1, 2, 3, 4, 5, 6], start: 1, reused: .init(previousLogitsStart: 1, rowCount: 2))
        XCTAssertEqual(store.capacity, 5 * width)
        XCTAssertEqual(read(buffer, rowCount: 5), rows(1..<6))
    }

    /// 今回の開始位置が後ろへずれたときは、前回の行を詰めてから今回計算した行を並べる (広げ直しも同時に起きる)
    func testShiftedStartMovesReusedRowsToTheFront() {
        let store = RichLogitsRowStore(rowWidth: width)
        _ = assemble(store, tokens: [1, 2, 3, 4, 5], start: 1, reused: nil)
        let buffer = assemble(store, tokens: [1, 2, 3, 4, 5, 6, 7, 8, 9], start: 3, reused: .init(previousLogitsStart: 1, rowCount: 2))
        XCTAssertEqual(read(buffer, rowCount: 6), rows(3..<9))
    }

    /// 全ての行を使い回すときは、今回計算した行が無くてよい
    func testFullReuseNeedsNoFreshRows() {
        let store = RichLogitsRowStore(rowWidth: width)
        _ = assemble(store, tokens: [1, 2, 3, 4, 5], start: 1, reused: nil)
        let buffer = store.assemble(tokens: [1, 2, 3, 4], logitsStart: 2, reusedRows: .init(previousLogitsStart: 1, rowCount: 2), freshRows: nil)
        XCTAssertEqual(read(buffer, rowCount: 2), rows(2..<4))
    }

    /// 前回の行が足りない、または今回計算した行が無いときは集めず、記録も捨てる
    func testAssembleRejectsMissingRows() {
        let store = RichLogitsRowStore(rowWidth: width)
        _ = assemble(store, tokens: [1, 2, 3], start: 1, reused: nil)
        XCTAssertNil(store.assemble(tokens: [1, 2, 3, 4, 5], logitsStart: 1, reusedRows: .init(previousLogitsStart: 1, rowCount: 3), freshRows: nil))
        XCTAssertNil(store.record)
        _ = assemble(store, tokens: [1, 2, 3], start: 1, reused: nil)
        XCTAssertNil(store.assemble(tokens: [1, 2, 3, 4], logitsStart: 1, reusedRows: .init(previousLogitsStart: 1, rowCount: 2), freshRows: nil))
        XCTAssertNil(store.assemble(tokens: [1, 2, 3, 4], logitsStart: 1, reusedRows: .init(previousLogitsStart: 2, rowCount: 1), freshRows: nil))
    }

    /// 解放した後は前回の行が無いため、使い回そうとしても集めない
    func testReleaseDropsRowsAndRecord() {
        let store = RichLogitsRowStore(rowWidth: width)
        _ = assemble(store, tokens: [1, 2, 3], start: 1, reused: nil)
        store.release()
        XCTAssertEqual(store.capacity, 0)
        XCTAssertNil(store.record)
        XCTAssertNil(assemble(store, tokens: [1, 2, 3, 4], start: 1, reused: .init(previousLogitsStart: 1, rowCount: 2)))
    }

    /// リッチ評価が続くときは、一致した範囲を使い回す計画を返し、記録を捨てる
    func testRichEvaluationAfterRichEvaluationReuses() {
        let store = RichLogitsRowStore(rowWidth: width)
        _ = assemble(store, tokens: [1, 2, 3, 4, 5], start: 1, reused: nil)
        let start = store.beginInference(isEvaluationSequence: true, isRichEvaluation: true, reuseEnabled: true, kvTokens: [1, 2, 3, 4, 5], tokens: [1, 2, 3, 9], logitsStart: 1)
        XCTAssertEqual(start, .init(keepsRows: true, reusePlan: .init(feedStart: 3), previousLogitsStart: 1))
        XCTAssertNil(store.record)
    }

    /// 通常の評価を挟むと、記録を捨てて領域も解放し、次のリッチ評価では使い回さない
    func testNonRichEvaluationDiscardsRecordAndReleasesBuffer() {
        let store = RichLogitsRowStore(rowWidth: width)
        _ = assemble(store, tokens: [1, 2, 3, 4, 5], start: 1, reused: nil)
        let plain = store.beginInference(isEvaluationSequence: true, isRichEvaluation: false, reuseEnabled: true, kvTokens: [1, 2, 3, 4, 5], tokens: [1, 2, 3, 4, 5], logitsStart: 1)
        XCTAssertEqual(plain, .init(keepsRows: false, reusePlan: nil, previousLogitsStart: nil))
        XCTAssertEqual(store.capacity, 0)
        let rich = store.beginInference(isEvaluationSequence: true, isRichEvaluation: true, reuseEnabled: true, kvTokens: [1, 2, 3, 4, 5], tokens: [1, 2, 3, 4, 5], logitsStart: 1)
        XCTAssertEqual(rich, .init(keepsRows: true, reusePlan: nil, previousLogitsStart: nil))
    }

    /// 使い回しを無効にすると、行を保持せず領域も解放する (元の llama_get_logits をそのまま使う)
    func testDisabledReuseKeepsNoRows() {
        let store = RichLogitsRowStore(rowWidth: width)
        _ = assemble(store, tokens: [1, 2, 3, 4, 5], start: 1, reused: nil)
        let start = store.beginInference(isEvaluationSequence: true, isRichEvaluation: true, reuseEnabled: false, kvTokens: [1, 2, 3, 4, 5], tokens: [1, 2, 3, 4, 5], logitsStart: 1)
        XCTAssertEqual(start, .init(keepsRows: false, reusePlan: nil, previousLogitsStart: nil))
        XCTAssertEqual(store.capacity, 0)
        XCTAssertNil(store.record)
    }

    /// 入力予測用シーケンスの推論を挟んでも、記録と行は残り、次のリッチ評価で使い回す
    func testInputPredictionSequenceKeepsRecord() {
        let store = RichLogitsRowStore(rowWidth: width)
        _ = assemble(store, tokens: [1, 2, 3, 4, 5], start: 1, reused: nil)
        let other = store.beginInference(isEvaluationSequence: false, isRichEvaluation: false, reuseEnabled: true, kvTokens: [7, 8], tokens: [7, 8, 9], logitsStart: 2)
        XCTAssertEqual(other, .init(keepsRows: false, reusePlan: nil, previousLogitsStart: nil))
        XCTAssertEqual(store.record?.tokens, [1, 2, 3, 4, 5])
        let rich = store.beginInference(isEvaluationSequence: true, isRichEvaluation: true, reuseEnabled: true, kvTokens: [1, 2, 3, 4, 5], tokens: [1, 2, 3, 4, 5], logitsStart: 1)
        XCTAssertEqual(rich.reusePlan, .init(feedStart: 5))
    }

    /// KVキャッシュの内容が記録と食い違う (別のシーケンスから写した、失敗で巻き戻したなど) ときは使い回さない
    func testMismatchedKVCacheIsNotReused() {
        let store = RichLogitsRowStore(rowWidth: width)
        _ = assemble(store, tokens: [1, 2, 3, 4, 5], start: 1, reused: nil)
        let start = store.beginInference(isEvaluationSequence: true, isRichEvaluation: true, reuseEnabled: true, kvTokens: [1, 2], tokens: [1, 2, 3, 4, 5], logitsStart: 1)
        XCTAssertEqual(start, .init(keepsRows: true, reusePlan: nil, previousLogitsStart: nil))
    }
}
