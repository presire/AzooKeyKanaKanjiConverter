@testable import KanaKanjiConverterModule
import XCTest

/// Zenzaiの候補評価で、ユーザ辞書の語のトークンを不合格にしないことを検証する
///
/// 実モデルは使わず、トークンごとの判定 (`ZenzCandidateEvaluator.candidateTokenDecision(...)`)、
/// 保護するトークンの範囲と、返す制約での元の表記への復元 (`ZenzCandidateEvaluator.userDictionaryProtection(...)`)、
/// 評価キャッシュのキー (`ZenzEvaluationCacheKey.CandidateSegment`) を直接検証する
final class HazkeyZenzaiUserDictionaryTokenTests: XCTestCase {
    private let identity: (String) -> String = { $0 }
    /// jinen (`ZenzContext.normalizeForModel(_:)`) と同じNFKC
    private let nfkc: (String) -> String = { $0.precomposedStringWithCompatibilityMapping }
    /// zenz (`ZenzContext.normalizeForModel(_:)`) と同じ空白と改行の置換
    private let zenzNormalize: (String) -> String = {
        $0.replacingOccurrences(of: " ", with: "\u{3000}").replacingOccurrences(of: "\n", with: "")
    }

    private func element(_ word: String, _ ruby: String, _ metadata: DicdataElementMetadata = .empty) -> DicdataElement {
        DicdataElement(word: word, ruby: ruby, cid: CIDData.固有名詞.cid, mid: 100, value: -5, metadata: metadata)
    }

    private func userDictionary(_ word: String, _ ruby: String) -> DicdataElement {
        element(word, ruby, .isFromUserDictionary)
    }

    private func pieces(_ parts: [String]) -> [[UInt8]] {
        parts.map { Array($0.utf8) }
    }

    private func protection(
        _ text: String,
        _ data: [DicdataElement],
        _ pieces: [[UInt8]],
        normalize: ((String) -> String)? = nil
    ) -> ZenzCandidateEvaluator.UserDictionaryProtection? {
        ZenzCandidateEvaluator.userDictionaryProtection(
            candidateText: text,
            data: data,
            candidateTokenPieces: pieces,
            normalize: normalize ?? identity
        )
    }

    private func mask(
        _ text: String,
        _ data: [DicdataElement],
        _ pieces: [[UInt8]],
        normalize: ((String) -> String)? = nil
    ) -> [Bool]? {
        protection(text, data, pieces, normalize: normalize)?.tokenMask
    }

    /// 先頭 `tokenCount` 個のトークンを復号した列から作る制約 (評価で不合格になった位置までの表記)
    private func restoredPrefix(_ protection: ZenzCandidateEvaluator.UserDictionaryProtection?, _ pieces: [[UInt8]], tokenCount: Int) -> String {
        let decoded = pieces.prefix(tokenCount).flatMap { $0 }
        return String(decoding: protection?.restoringSurface(decoded) ?? decoded, as: UTF8.self)
    }

    // MARK: - 保護するトークンの範囲

    func testMaskProtectsTokensInsideUserDictionaryWord() {
        let data = [element("今日は", "キョウハ"), userDictionary("間桐臓硯", "マトウゾウケン"), element("です", "デス")]
        XCTAssertEqual(
            mask("今日は間桐臓硯です", data, pieces(["今日", "は", "間桐", "臓", "硯", "です"])),
            [false, false, true, true, true, false]
        )
    }

    func testMaskDoesNotProtectTokenStraddlingUserDictionaryAndNormalWord() {
        let data = [element("今日", "キョウ"), userDictionary("正確", "セイカク"), element("な", "ナ")]
        XCTAssertEqual(
            mask("今日正確な", data, pieces(["今日", "正", "確な"])),
            [false, true, false]
        )
    }

    func testMaskProtectsTokenStraddlingAdjacentUserDictionaryWords() {
        let data = [userDictionary("間桐", "マトウ"), userDictionary("臓硯", "ゾウケン")]
        XCTAssertEqual(
            mask("間桐臓硯", data, pieces(["間", "桐臓", "硯"])),
            [true, true, true]
        )
    }

    func testMaskHandlesByteFallbackPieces() {
        let data = [userDictionary("正確", "セイカク"), element("に", "ニ")]
        // 正 = E6 AD A3、確 = E7 A2 BA、に = E3 81 AB
        XCTAssertEqual(
            mask("正確に", data, [[0xE6], [0xAD, 0xA3], [0xE7, 0xA2, 0xBA], [0xE3, 0x81, 0xAB]]),
            [true, true, true, false]
        )
        XCTAssertEqual(
            mask("正確に", data, [[0xE6, 0xAD, 0xA3], [0xE7, 0xA2, 0xBA, 0xE3], [0x81, 0xAB]]),
            [true, false, false]
        )
    }

    func testMaskUsesNormalizedOffsetsForNFKCExpansion() {
        // jinenはNFKCで㍻を平成 (3バイト→6バイト) に展開してから符号化する
        let data = [userDictionary("㍻", "ヘイセイ"), element("元年", "ガンネン")]
        XCTAssertEqual(
            mask("㍻元年", data, pieces(["平成", "元年"]), normalize: nfkc),
            [true, false]
        )
        let reversed = [element("元年", "ガンネン"), userDictionary("㍻", "ヘイセイ")]
        XCTAssertEqual(
            mask("元年㍻", reversed, pieces(["元年", "平", "成"]), normalize: nfkc),
            [false, true, true]
        )
    }

    func testMaskUsesNormalizedOffsetsForZenzSpaceReplacement() {
        // zenzは半角空白 (1バイト) を全角空白 (3バイト) に置換してから符号化する
        let data = [userDictionary("Hazkey Community", "ハズキーコミュニティ"), element("です", "デス")]
        XCTAssertEqual(
            mask("Hazkey Communityです", data, pieces(["Haz", "key", "\u{3000}", "Community", "です"]), normalize: zenzNormalize),
            [true, true, true, true, false]
        )
    }

    func testMaskLeavesUserDictionaryWordUnprotectedWhenItsBoundaryIsInsideACharacter() {
        // ｶ + ﾞ は1文字 (書記素) なので、その間にある語の境界は符号化後の列に対応させない
        // (このNFKCは カ + U+3099 を返し、正規化後の先頭部分の比較だけでは境界を検出できない)
        let data = [userDictionary("ｶ", "カ"), element("ﾞｰ", "ー")]
        XCTAssertEqual(
            mask("ｶﾞｰ", data, pieces(["カ", "\u{3099}ー"]), normalize: nfkc),
            [false, false]
        )
        XCTAssertEqual(
            mask("ｶﾞｰ", data, pieces(["ガ", "ー"]), normalize: { _ in "ガー" }),
            [false, false]
        )
    }

    func testMaskProtectsRemainderOfPartiallyFixedUserDictionaryWord() {
        // 固定された表記 (間桐) を除いた残りを評価する場合、dataの先頭の語は固定部分を含む
        let data = [userDictionary("間桐臓硯", "マトウゾウケン"), element("です", "デス")]
        XCTAssertEqual(
            mask("臓硯です", data, pieces(["臓", "硯", "です"])),
            [true, true, false]
        )
        let normalFirst = [element("今日は", "キョウハ"), userDictionary("正確", "セイカク")]
        XCTAssertEqual(
            mask("は正確", normalFirst, pieces(["は", "正確"])),
            [false, true]
        )
    }

    func testMaskNeverProtectsAlignmentSeparator() {
        let data = [userDictionary("正確", "セイカク")]
        XCTAssertEqual(
            mask("正確", data, pieces(["正確", ZenzPromptBuilder.alignmentSeparator])),
            [true, false]
        )
        // 制御トークンは空の表記に復号される
        XCTAssertEqual(
            mask("正確", data, pieces(["正確", ""])),
            [true, false]
        )
        XCTAssertEqual(
            mask("正確", data, pieces(["正確" + ZenzPromptBuilder.alignmentSeparator])),
            [false]
        )
    }

    func testMaskProtectsOnlyUserDictionaryWordWhenMixedWithLearnedWord() {
        let data = [element("今日", "キョウ", .isLearned), userDictionary("正確", "セイカク")]
        XCTAssertEqual(
            mask("今日正確", data, pieces(["今日", "正確"])),
            [false, true]
        )
    }

    func testMaskIsNilWithoutUserDictionaryWord() {
        let data = [element("今日", "キョウ", .isLearned), element("正確", "セイカク")]
        XCTAssertNil(mask("今日正確", data, pieces(["今日", "正確"])))
    }

    func testMaskIsNilWhenTokensOrDataDoNotMatchText() {
        let data = [userDictionary("正確", "セイカク")]
        XCTAssertNil(mask("正確", data, pieces([" 正確"])))
        XCTAssertNil(mask("正確", data, pieces(["正"])))
        XCTAssertNil(mask("性格", data, pieces(["性格"])))
    }

    // MARK: - 返す制約での元の表記への復元

    func testConstraintRestoresNFKCExpandedUserDictionaryWord() {
        // jinenで ㍻ (UD) の後の通常の語が不合格になると、制約は 平成 + モデルのトークン になる
        // ラティスの語の表記は ㍻ なので、元の表記へ戻さないと ㍻ を含む経路が制約を満たせない
        let data = [userDictionary("㍻", "ヘイセイ"), element("です", "デス")]
        let tokens = pieces(["平成", "で", "す"])
        let p = protection("㍻です", data, tokens, normalize: nfkc)
        XCTAssertEqual(p?.tokenMask, [true, false, false])
        XCTAssertEqual(restoredPrefix(p, tokens, tokenCount: 1), "㍻")
        XCTAssertEqual(restoredPrefix(p, tokens, tokenCount: 2), "㍻で")
    }

    func testConstraintRestoresZenzSpaceInUserDictionaryWord() {
        let data = [userDictionary("Hazkey Community", "ハズキーコミュニティ"), element("です", "デス")]
        let tokens = pieces(["Haz", "key", "\u{3000}", "Community", "で", "す"])
        let p = protection("Hazkey Communityです", data, tokens, normalize: zenzNormalize)
        XCTAssertEqual(restoredPrefix(p, tokens, tokenCount: 4), "Hazkey Community")
        XCTAssertEqual(restoredPrefix(p, tokens, tokenCount: 5), "Hazkey Communityで")
    }

    func testConstraintKeepsPartiallyDecodedUserDictionaryWordAndNormalWords() {
        // 語の途中までしか復号していない範囲と、通常の語は従来どおり正規化後の表記のまま
        let data = [element("ＡＢ", "エービー"), userDictionary("㍻", "ヘイセイ"), element("です", "デス")]
        let tokens = pieces(["AB", "平", "成", "です"])
        let p = protection("ＡＢ㍻です", data, tokens, normalize: nfkc)
        XCTAssertEqual(p?.tokenMask, [false, true, true, false])
        XCTAssertEqual(restoredPrefix(p, tokens, tokenCount: 2), "AB平")
        XCTAssertEqual(restoredPrefix(p, tokens, tokenCount: 3), "AB㍻")
        XCTAssertEqual(restoredPrefix(p, tokens, tokenCount: 4), "AB㍻です")
    }

    func testConstraintRestoresEveryUserDictionaryRun() {
        let data = [userDictionary("㍻", "ヘイセイ"), element("と", "ト"), userDictionary("㍼", "ショウワ"), element("だ", "ダ")]
        let tokens = pieces(["平成", "と", "昭和", "だ"])
        let p = protection("㍻と㍼だ", data, tokens, normalize: nfkc)
        XCTAssertEqual(restoredPrefix(p, tokens, tokenCount: 4), "㍻と㍼だ")
    }

    func testConstraintRestoresRemainderOfPartiallyFixedUserDictionaryWord() {
        // 固定された表記 (Hazkey) を除いた残り ( Community) は、元の表記の残りへ戻す
        let data = [userDictionary("Hazkey Community", "ハズキーコミュニティ"), element("です", "デス")]
        let tokens = pieces(["\u{3000}", "Community", "で", "す"])
        let p = protection(" Communityです", data, tokens, normalize: zenzNormalize)
        XCTAssertEqual(p?.tokenMask, [true, true, false, false])
        XCTAssertEqual(restoredPrefix(p, tokens, tokenCount: 3), " Communityで")
    }

    func testConstraintIsUnchangedWhenNormalizationKeepsUserDictionaryWord() {
        let data = [element("今日", "キョウ"), userDictionary("正確", "セイカク"), element("な", "ナ")]
        let tokens = pieces(["今日", "正確", "な"])
        let p = protection("今日正確な", data, tokens, normalize: nfkc)
        XCTAssertEqual(restoredPrefix(p, tokens, tokenCount: 3), "今日正確な")
        XCTAssertEqual(
            p?.restoringSurface(Array(("今日正確な" + ZenzPromptBuilder.alignmentSeparator).utf8)),
            Array(("今日正確な" + ZenzPromptBuilder.alignmentSeparator).utf8)
        )
    }

    // MARK: - トークンごとの判定

    private func decide(
        candidate: Int32 = 10,
        candidateLogit: Float = 1,
        max: Int32,
        maxLogit: Float = 5,
        eos: Int32 = 2,
        learnedPriority: Float = 0,
        userDictionary: Bool = false
    ) -> ZenzCandidateEvaluator.CandidateTokenDecision {
        ZenzCandidateEvaluator.candidateTokenDecision(
            candidateToken: candidate,
            candidateLogit: candidateLogit,
            maxToken: max,
            maxLogit: maxLogit,
            eosToken: eos,
            learnedPriority: learnedPriority,
            isUserDictionaryToken: userDictionary
        )
    }

    func testUserDictionaryTokenIsAcceptedWhenModelPrefersAnotherToken() {
        XCTAssertEqual(decide(max: 20, maxLogit: 100, userDictionary: true), .accept(collectsAlternatives: false))
    }

    func testUserDictionaryTokenIsAcceptedWhenModelPrefersEOS() {
        XCTAssertEqual(decide(max: 2, maxLogit: 100, eos: 2, userDictionary: true), .accept(collectsAlternatives: false))
    }

    func testUserDictionaryTokenDoesNotCollectAlternativesWhenItIsTheMaxToken() {
        // リッチな候補の代替の制約は、保護した範囲を別の表記へ変えてしまうため集めない
        XCTAssertEqual(decide(max: 10, maxLogit: 1, userDictionary: true), .accept(collectsAlternatives: false))
    }

    func testNormalTokenDecisionIsUnchanged() {
        XCTAssertEqual(decide(max: 10, maxLogit: 1), .accept(collectsAlternatives: true))
        XCTAssertEqual(decide(max: 2, eos: 2), .wholeResult)
        XCTAssertEqual(decide(max: 20), .fixRequired)
    }

    func testLearnedTokenDecisionIsUnchanged() {
        XCTAssertEqual(decide(candidateLogit: 1, max: 20, maxLogit: 5, learnedPriority: 4.5), .accept(collectsAlternatives: false))
        XCTAssertEqual(decide(candidateLogit: 1, max: 20, maxLogit: 5, learnedPriority: 4), .fixRequired)
        XCTAssertEqual(decide(candidateLogit: 1, max: 2, maxLogit: 5, eos: 2, learnedPriority: 100), .wholeResult)
        XCTAssertEqual(decide(max: 10, maxLogit: 1, learnedPriority: 3), .accept(collectsAlternatives: true))
    }

    // MARK: - 評価キャッシュのキー

    private func cacheKey(_ data: [DicdataElement]) -> ZenzEvaluationCacheKey {
        ZenzEvaluationCacheKey(
            prompt: "",
            candidateTextForEvaluation: "正確",
            originalCandidateText: "正確",
            prefixConstraint: Kana2Kanji.PrefixConstraint([]),
            requestRichCandidates: false,
            reusesAddressedPrefix: false,
            candidateSegments: data.map(ZenzEvaluationCacheKey.CandidateSegment.init)
        )
    }

    func testCandidateSegmentDistinguishesUserDictionaryFlag() {
        XCTAssertNotEqual(
            ZenzEvaluationCacheKey.CandidateSegment(userDictionary("正確", "セイカク")),
            ZenzEvaluationCacheKey.CandidateSegment(element("正確", "セイカク"))
        )
        XCTAssertEqual(
            ZenzEvaluationCacheKey.CandidateSegment(userDictionary("正確", "セイカク")),
            ZenzEvaluationCacheKey.CandidateSegment(userDictionary("正確", "セイカク"))
        )
    }

    func testEvaluationCacheDoesNotShareResultAcrossUserDictionaryFlag() {
        // jinenは辞書をプロンプトに入れないため、プロンプトが同じでもユーザ辞書の語かどうかで結果が変わる
        let cache = ZenzEvaluationCache(capacity: 4)
        cache.insert(.fixRequired(prefixConstraint: Array("性".utf8)), for: cacheKey([element("正確", "セイカク")]))
        XCTAssertNil(cache.value(for: cacheKey([userDictionary("正確", "セイカク")])))
        XCTAssertNotNil(cache.value(for: cacheKey([element("正確", "セイカク")])))
    }
}
