@testable import KanaKanjiConverterModule
import XCTest

final class ZenzJinenPersonaTests: XCTestCase {
    private var separator: String {
        ZenzCandidateEvaluator.jinenPersonaSeparator
    }

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

    // T1: empty profile is a no-op (mode and prompt identical to jinenAdjustedMode).
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

    // T2: profile with no left context becomes the whole left context.
    func testProfileWithoutLeftContext() {
        let S = self.separator
        XCTAssertEqual(
            self.prompt(for: self.v3(profile: "情報系の大学生")),
            "情報系の大学生" + S + "カンジ"
        )
    }

    // T3: long left context is trimmed to the same 40 chars, persona is intact.
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

    // T4: maxLeftSideContextLength bounds C only; 0 leaves P + S.
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

    // T12: grapheme-boundary left contexts keep P + S and match suffix semantics.
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

    // T5: profile capped at 25 chars; cut-point whitespace is trimmed.
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

    // T6: sentence-final P avoids a doubled separator (only when S is 。).
    func testSentenceFinalProfileSkipsSeparator() {
        if self.separator == "。" {
            XCTAssertEqual(
                self.prompt(for: self.v3(profile: "学生です。")),
                "学生です。カンジ"
            )
            // NFKC maps ！ to !, which also counts as sentence-final.
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

    // T7: NFKC + trim shape P; inner spaces survive.
    func testProfileNormalization() {
        let S = self.separator
        XCTAssertEqual(
            self.prompt(for: self.v3(profile: "　ＡＢＣ　エンジニア ")),
            "ABC エンジニア" + S + "カンジ"
        )
        // ㍿ (U+337F) becomes 4 chars under NFKC; 25 in a row cap at 25 NFKC chars.
        let many = String(repeating: "㍿", count: 25)
        let expectedP = String((many.precomposedStringWithCompatibilityMapping).suffix(25))
        XCTAssertEqual(expectedP.count, 25)
        XCTAssertEqual(
            self.prompt(for: self.v3(profile: many)),
            "" + expectedP + S + "カンジ"
        )
    }

    // T8: conditions other than profile stay stripped.
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

    // T9: v2 passes through untouched.
    func testV2PassesThrough() {
        let config = ConvertRequestOptions.ZenzaiVersionDependentMode.v2(
            ConvertRequestOptions.ZenzaiV2DependentMode(profile: "医師", leftSideContext: "今日は")
        )
        XCTAssertEqual(ZenzCandidateEvaluator.jinenEvaluationMode(config), config)
    }

    // T10: jinenAdjustedMode still drops the profile (generator path unchanged).
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

    // T11: different profiles give different prompts (cache separation).
    func testDifferentProfilesGiveDifferentPrompts() {
        XCTAssertNotEqual(
            self.prompt(for: self.v3(profile: "医師")),
            self.prompt(for: self.v3(profile: "プログラマ"))
        )
    }
}
