@testable import KanaKanjiConverterModule
import XCTest

/// jinen用プロファイル畳み込みの表テストをまとめる
///
/// jinenEvaluationModeがv3のプロファイルを左文脈の先頭へPとSとCの順で畳み込むことを検証する
///
/// 実モデルは使わず、ZenzPromptBuilderの生成プロンプト文字列で判定する
final class ZenzJinenPersonaTests: XCTestCase {
    /// 検証対象の区切り文字を返す
    ///
    /// 製品のjinenPersonaSeparatorと常に一致させ、区切り依存の期待値を組み立てる
    private var separator: String {
        ZenzCandidateEvaluator.jinenPersonaSeparator
    }

    /// 指定した設定の候補評価プロンプトを作る
    ///
    /// - Parameters:
    ///   - config: 畳み込み前または畳み込み後のv3設定
    ///   - input: プロンプトに載せる入力読み
    /// - Returns: 畳み込み結果を反映した評価プロンプト文字列
    private func prompt(
        for config: ConvertRequestOptions.ZenzaiVersionDependentMode,
        input: String = "カンジ"
    ) -> String {
        let mode = ZenzCandidateEvaluator.jinenEvaluationMode(config)
        return ZenzPromptBuilder.candidateEvaluationPrompt(
            input: input,
            userDictionaryPrompt: "",
            versionDependentConfig: mode
        )
    }

    /// 検証用のv3設定を作る
    ///
    /// - Parameters:
    ///   - profile: 左文脈の先頭へ畳み込む利用者像
    ///   - leftSideContext: 畳み込み対象の左文脈
    ///   - maxLeftSideContextLength: 左文脈の切り詰め上限
    /// - Returns: 指定した条件を持つv3設定
    private func v3(
        profile: String? = nil,
        leftSideContext: String? = nil,
        maxLeftSideContextLength: Int? = nil
    ) -> ConvertRequestOptions.ZenzaiVersionDependentMode {
        .v3(
            ConvertRequestOptions.ZenzaiV3DependentMode(
                profile: profile,
                leftSideContext: leftSideContext,
                maxLeftSideContextLength: maxLeftSideContextLength
            )
        )
    }

    /// 空のプロファイルが無処理であることを検証する (T1)
    ///
    /// プロファイルが空ならjinenEvaluationModeの結果はjinenAdjustedModeと同一になり、生成プロンプトも変わらない
    func testEmptyProfileReturnsAdjustedModeUnchanged() {
        for profile in [nil, "", "  "] as [String?] {
            let config = self.v3(profile: profile, leftSideContext: "今日は")
            XCTAssertEqual(
                ZenzCandidateEvaluator.jinenEvaluationMode(config),
                ZenzCandidateEvaluator.jinenAdjustedMode(config)
            )
            let folded = ZenzPromptBuilder.candidateEvaluationPrompt(
                input: "カンジ",
                userDictionaryPrompt: "",
                versionDependentConfig: ZenzCandidateEvaluator.jinenEvaluationMode(config)
            )
            let baseline = ZenzPromptBuilder.candidateEvaluationPrompt(
                input: "カンジ",
                userDictionaryPrompt: "",
                versionDependentConfig: ZenzCandidateEvaluator.jinenAdjustedMode(config)
            )
            XCTAssertEqual(folded, baseline)
            XCTAssertEqual(folded, "今日はカンジ")
        }
    }

    /// 左文脈が無いときはプロファイル全体が左文脈になることを検証する (T2)
    ///
    /// 畳み込み後の左文脈はプロファイルと区切りの結合になる
    func testProfileWithoutLeftContext() {
        let S = self.separator
        XCTAssertEqual(
            self.prompt(for: self.v3(profile: "情報系の大学生")),
            "情報系の大学生" + S + "カンジ"
        )
    }

    /// 長い左文脈でもプロファイルが保たれることを検証する (T3)
    ///
    /// 左文脈は末尾40文字に切り詰められ、プロファイルと区切りは削られない
    func testLongLeftContextKeepsPersonaIntact() {
        let S = self.separator
        let left = String(repeating: "あ", count: 60)
        let result = self.prompt(for: self.v3(profile: "情報系の大学生", leftSideContext: left))
        XCTAssertEqual(
            result,
            "情報系の大学生" + S + String(repeating: "あ", count: 40) + "カンジ"
        )
        if case .v3(let mode) = ZenzCandidateEvaluator.jinenEvaluationMode(
            self.v3(profile: "情報系の大学生", leftSideContext: left)
        ) {
            XCTAssertEqual(mode.maxLeftSideContextLength, ("情報系の大学生" + S + String(repeating: "あ", count: 40)).count)
        } else {
            XCTFail("expected .v3")
        }
    }

    /// 切り詰め上限が左文脈だけを縛ることを検証する (T4)
    ///
    /// 上限0では左文脈が消えてプロファイルと区切りだけが残る
    func testMaxLeftSideContextLengthBoundsContextOnly() {
        let S = self.separator
        XCTAssertEqual(
            self.prompt(
                for: self.v3(
                    profile: "医師",
                    leftSideContext: "昨日の会議で",
                    maxLeftSideContextLength: 5
                )
            ),
            "医師" + S + "日の会議で" + "カンジ"
        )
        XCTAssertEqual(
            self.prompt(
                for: self.v3(profile: "医師", leftSideContext: "昨日の会議で", maxLeftSideContextLength: 0)
            ),
            "医師" + S + "カンジ"
        )
    }

    /// 書記素境界の左文脈でも切り詰めがsuffixと一致することを検証する (T12)
    ///
    /// 結合文字やZWJ絵文字を含む左文脈でもプロファイルと区切りは保たれる
    func testGraphemeBoundaryLeftContext() {
        let S = self.separator
        let combining = String(repeating: "あ", count: 59) + "あ\u{3099}"
        let combiningResult = self.prompt(for: self.v3(profile: "医師", leftSideContext: combining))
        XCTAssertTrue(combiningResult.hasPrefix("医師" + S))
        XCTAssertEqual(combiningResult, "医師" + S + String(combining.suffix(40)) + "カンジ")
        let zwj = String(repeating: "あ", count: 39) + "👨\u{200D}👩\u{200D}👧"
        XCTAssertEqual(zwj.count, 40)
        let zwjResult = self.prompt(for: self.v3(profile: "医師", leftSideContext: zwj))
        XCTAssertEqual(zwjResult, "医師" + S + zwj + "カンジ")
    }

    /// プロファイルが末尾25文字に切り詰められることを検証する (T5)
    ///
    /// 切り口の空白は取り除き、空になる場合は畳み込み自体を行わない
    func testProfileCappedAtTwentyFiveCharacters() {
        let S = self.separator
        XCTAssertEqual(
            self.prompt(for: self.v3(profile: String(repeating: "あ", count: 30))),
            "" + String(repeating: "あ", count: 25) + S + "カンジ"
        )
        let cutSpace = String(repeating: "あ", count: 5) + " " + String(repeating: "あ", count: 24)
        XCTAssertEqual(cutSpace.count, 30)
        XCTAssertEqual(
            self.prompt(for: self.v3(profile: cutSpace)),
            "" + String(repeating: "あ", count: 24) + S + "カンジ"
        )
    }

    /// 文末記号で終わるプロファイルでは区切りを重ねないことを検証する (T6)
    ///
    /// 区切りが句点の場合に限り、既に文末記号で終わるプロファイルの後ろには区切りを足さない
    func testSentenceFinalProfileSkipsSeparator() {
        if self.separator == "。" {
            XCTAssertEqual(
                self.prompt(for: self.v3(profile: "学生です。")),
                "学生です。カンジ"
            )
            // NFKCで全角感嘆符は半角に正規化されるため、文末記号として扱う
            XCTAssertEqual(
                self.prompt(for: self.v3(profile: "学生です！")),
                "学生です!カンジ"
            )
        } else {
            XCTAssertEqual(
                self.prompt(for: self.v3(profile: "学生です。")),
                "学生です。" + self.separator + "カンジ"
            )
        }
    }

    /// プロファイルがNFKC正規化と前後空白除去を受けることを検証する (T7)
    ///
    /// 中間空白は残り、1文字が複数文字に広がる場合も正規化後の25文字で切る
    func testProfileNormalization() {
        let S = self.separator
        XCTAssertEqual(
            self.prompt(for: self.v3(profile: "　ＡＢＣ　エンジニア ")),
            "ABC エンジニア" + S + "カンジ"
        )
        // ㍿はNFKCで4文字に広がるため、25個並べると正規化後の25文字で切れる
        let many = String(repeating: "㍿", count: 25)
        let expectedP = String((many.precomposedStringWithCompatibilityMapping).suffix(25))
        XCTAssertEqual(expectedP.count, 25)
        XCTAssertEqual(
            self.prompt(for: self.v3(profile: many)),
            "" + expectedP + S + "カンジ"
        )
    }

    /// プロファイル以外の条件が除去されたままであることを検証する (T8)
    ///
    /// 話題と文体と好みと右文脈と区切り有効化はjinen評価に渡さない
    func testOtherConditionsStayStripped() {
        let mode = ConvertRequestOptions.ZenzaiV3DependentMode(
            profile: "医師",
            topic: "topic",
            style: "style",
            preference: "preference",
            leftSideContext: "今日は",
            rightSideContext: "right",
            enableAlignmentSeparator: true
        )
        let folded = ZenzCandidateEvaluator.jinenEvaluationMode(.v3(mode))
        guard case .v3(let out) = folded else {
            XCTFail("expected .v3")
            return
        }
        XCTAssertNil(out.topic)
        XCTAssertNil(out.style)
        XCTAssertNil(out.preference)
        XCTAssertNil(out.rightSideContext)
        XCTAssertFalse(out.enableAlignmentSeparator)
    }

    /// v2設定はそのまま通ることを検証する (T9)
    ///
    /// プロファイル畳み込みはv3専用のため、v2には何もしない
    func testV2PassesThrough() {
        let config = ConvertRequestOptions.ZenzaiVersionDependentMode.v2(
            ConvertRequestOptions.ZenzaiV2DependentMode(profile: "医師", leftSideContext: "今日は")
        )
        XCTAssertEqual(ZenzCandidateEvaluator.jinenEvaluationMode(config), config)
    }

    /// 調整済みモードがプロファイルを捨てることを検証する (T10)
    ///
    /// 生成側の経路は畳み込み前と同じくプロファイルを持たない
    func testAdjustedModeStillDropsProfile() {
        let config = self.v3(profile: "医師", leftSideContext: "今日は", maxLeftSideContextLength: 5)
        let adjusted = ZenzCandidateEvaluator.jinenAdjustedMode(config)
        guard case .v3(let mode) = adjusted else {
            XCTFail("expected .v3")
            return
        }
        XCTAssertNil(mode.profile)
        XCTAssertEqual(mode.leftSideContext, "今日は")
        XCTAssertEqual(mode.maxLeftSideContextLength, 5)
    }

    /// プロファイルが違えばプロンプトも違うことを検証する (T11)
    ///
    /// 畳み込み後の左文脈がキーに含まれるため、別プロファイルの結果を共有しない
    func testDifferentProfilesGiveDifferentPrompts() {
        XCTAssertNotEqual(
            self.prompt(for: self.v3(profile: "医師")),
            self.prompt(for: self.v3(profile: "プログラマ"))
        )
    }
}
