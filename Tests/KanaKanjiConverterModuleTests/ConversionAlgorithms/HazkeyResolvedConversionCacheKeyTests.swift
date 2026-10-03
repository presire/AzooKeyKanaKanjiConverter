// [Hazkey Community Patch]
// Zenzaiの解決済み変換キャッシュのキーが評価に使った全文の読みを含むことを検証する
// カーソルより前の読みが同じでも右側の読みが違えば別のキーになり、別入力の変換結果を誤って共有しない
@testable import KanaKanjiConverterModule
import XCTest

/// 解決済み変換キャッシュのキーが評価全文を含むことの回帰テストをまとめる
///
/// カーソル途中の変換では変換対象がカーソルまでの読みになる一方、評価は全文で行う
///
/// 両者をキーに含めないと、右側だけが違う別入力の結果を誤って共有する
final class HazkeyResolvedConversionCacheKeyTests: XCTestCase {
    /// カーソル途中の入力Aを作る
    ///
    /// きょうはいいてんきの6文字目の後にカーソルを置く
    private func midCursorTextA() -> ComposingText {
        Self.composingText("きょうはいいてんき", cursorOffset: -3)
    }

    /// カーソル途中の入力Bを作る
    ///
    /// きょうはいいてんぷらの6文字目の後にカーソルを置き、カーソルより前はAと同じで右側だけを変える
    private func midCursorTextB() -> ComposingText {
        Self.composingText("きょうはいいてんぷら", cursorOffset: -4)
    }

    /// 右側だけが違う入力でキーが共有されないことを検証する
    ///
    /// カーソルより前の読みとカーソル位置が同じでも、評価全文が違えば別のキーになる
    func testResolvedKeyDiffersWhenOnlyTheRightHandReadingDiffers() {
        let keyA = Self.cacheKey(for: self.midCursorTextA())
        let keyB = Self.cacheKey(for: self.midCursorTextB())

        // カーソルより前 (ラティス入力) は同一であることを前提に固定する
        XCTAssertEqual(keyA.convertTarget, keyB.convertTarget)
        XCTAssertEqual(keyA.convertTargetCursorPosition, keyB.convertTargetCursorPosition)
        XCTAssertEqual(keyA.input, keyB.input)
        // 右側の読みだけが違うため、キー全体は共有されてはならない
        XCTAssertNotEqual(keyA.evaluationConvertTarget, keyB.evaluationConvertTarget)
        XCTAssertNotEqual(keyA, keyB)
    }

    /// 同じ入力からは同じキーが作られることを検証する
    ///
    /// 同一性が安定しないと毎回再評価になり、キャッシュが役に立たない
    func testResolvedKeyIsStableForTheSameInput() {
        let input = self.midCursorTextA()
        XCTAssertEqual(Self.cacheKey(for: input), Self.cacheKey(for: input))
    }

    /// カーソル末尾では評価対象と変換対象が同じ読みになることを検証する
    ///
    /// 区切りが無い通常変換では全文がそのまま使われ、二重管理にならない
    func testResolvedKeyForCursorAtEndUsesTheSameReadingTwice() {
        let key = Self.cacheKey(for: Self.composingText("きょうはいいてんき"))
        XCTAssertEqual(key.evaluationConvertTarget, key.convertTarget)
    }

    /// 指定した読みのComposingTextを作る
    ///
    /// - Parameter text: カーソル末尾に挿入する読み
    /// - Parameter cursorOffset: 挿入後にカーソルを動かす文字数 (負数は左へ)
    /// - Returns: 指定したカーソル位置を持つComposingText
    private static func composingText(_ text: String, cursorOffset: Int = 0) -> ComposingText {
        var composing = ComposingText()
        composing.insertAtCursorPosition(text, inputStyle: .direct)
        if cursorOffset != 0 {
            _ = composing.moveCursorFromCursorPosition(count: cursorOffset)
        }
        return composing
    }

    /// 指定した入力の解決済み変換キャッシュキーを作る
    ///
    /// - Parameter inputData: キー化する入力
    /// - Returns: 製品と同じ条件で解決したキャッシュキー
    private static func cacheKey(for inputData: ComposingText) -> ZenzResolvedConversionCacheKey {
        Kana2Kanji.resolvedConversionCacheKey(
            for: inputData,
            keyboardLanguage: .ja_JP,
            versionDependentConfig: .v3(.init()),
            prefixConstraint: .init([]),
            inferenceLimit: 1
        )
    }
}
