// [hazkey-community patch] Zenzaiの解決済み変換キャッシュのキーが、評価に使った
// 全文の読みを含むことを検証する。カーソルより前の読みが同じでも右側の読みが違えば
// 別のキーにならないと、別入力の変換結果を誤って共有する。
@testable import KanaKanjiConverterModule
import XCTest

final class HazkeyResolvedConversionCacheKeyTests: XCTestCase {
    /// A: 「きょうはいいてんき」のカーソルを先頭から6文字目の後に置く。
    private func midCursorTextA() -> ComposingText {
        Self.composingText("きょうはいいてんき", cursorOffset: -3)
    }

    /// B: 「きょうはいいてんぷら」のカーソルを同じく6文字目の後に置く。
    /// カーソルより前の読みはAと同じで、右側の読みだけが異なる。
    private func midCursorTextB() -> ComposingText {
        Self.composingText("きょうはいいてんぷら", cursorOffset: -4)
    }

    func testResolvedKeyDiffersWhenOnlyTheRightHandReadingDiffers() {
        let keyA = Self.cacheKey(for: self.midCursorTextA())
        let keyB = Self.cacheKey(for: self.midCursorTextB())

        // カーソルより前 (ラティス入力) は同一であることを前提に固定する。
        XCTAssertEqual(keyA.convertTarget, keyB.convertTarget)
        XCTAssertEqual(keyA.convertTargetCursorPosition, keyB.convertTargetCursorPosition)
        XCTAssertEqual(keyA.input, keyB.input)
        // 右側の読みだけが違うため、キー全体は共有されてはならない。
        XCTAssertNotEqual(keyA.evaluationConvertTarget, keyB.evaluationConvertTarget)
        XCTAssertNotEqual(keyA, keyB)
    }

    func testResolvedKeyIsStableForTheSameInput() {
        let input = self.midCursorTextA()
        XCTAssertEqual(Self.cacheKey(for: input), Self.cacheKey(for: input))
    }

    func testResolvedKeyForCursorAtEndUsesTheSameReadingTwice() {
        let key = Self.cacheKey(for: Self.composingText("きょうはいいてんき"))
        XCTAssertEqual(key.evaluationConvertTarget, key.convertTarget)
    }

    private static func composingText(_ text: String, cursorOffset: Int = 0) -> ComposingText {
        var composing = ComposingText()
        composing.insertAtCursorPosition(text, inputStyle: .direct)
        if cursorOffset != 0 {
            _ = composing.moveCursorFromCursorPosition(count: cursorOffset)
        }
        return composing
    }

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
