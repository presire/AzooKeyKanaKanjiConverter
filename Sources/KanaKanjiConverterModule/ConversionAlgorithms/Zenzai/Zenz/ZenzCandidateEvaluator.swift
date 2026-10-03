#if Zenzai || ZenzaiCPU
import llama
#endif

import Algorithms
import EfficientNGram
import Foundation
import SwiftUtils

enum CandidateEvaluationResult: Sendable, Equatable, Hashable {
    case error
    case pass(score: Float, alternativeConstraints: [AlternativeConstraint])
    case fixRequired(prefixConstraint: [UInt8])
    case wholeResult(String)

    struct AlternativeConstraint: Sendable, Equatable, Hashable {
        var probabilityRatio: Float
        var prefixConstraint: [UInt8]
    }
}

struct ZenzEvaluationCacheKey: Sendable, Equatable, Hashable {
    struct CandidateSegment: Sendable, Equatable, Hashable {
        var word: String
        var ruby: String
        var isLearned: Bool
    }

    var prompt: String
    var candidateTextForEvaluation: String
    var originalCandidateText: String
    var prefixConstraint: Kana2Kanji.PrefixConstraint
    var requestRichCandidates: Bool
    var reusesAddressedPrefix: Bool
    var candidateSegments: [CandidateSegment]
}

/// モデル評価結果を少量だけ保持する、スレッドセーフなLRUキャッシュ。
final class ZenzEvaluationCache: @unchecked Sendable {
    private struct Entry {
        var result: CandidateEvaluationResult
        var accessIndex: UInt64
    }

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func value(for key: ZenzEvaluationCacheKey) -> CandidateEvaluationResult? {
        self.lock.withLock {
            guard var entry = self.entries[key] else {
                return nil
            }
            self.accessIndex &+= 1
            entry.accessIndex = self.accessIndex
            self.entries[key] = entry
            return entry.result
        }
    }

    func insert(_ result: CandidateEvaluationResult, for key: ZenzEvaluationCacheKey) {
        self.lock.withLock {
            self.accessIndex &+= 1
            if self.entries[key] == nil, self.entries.count >= self.capacity,
               let leastRecentlyUsedKey = self.entries.min(by: {
                   $0.value.accessIndex < $1.value.accessIndex
               })?.key {
                self.entries[leastRecentlyUsedKey] = nil
            }
            self.entries[key] = Entry(result: result, accessIndex: self.accessIndex)
        }
    }

    private let capacity: Int
    private var entries: [ZenzEvaluationCacheKey: Entry] = [:]
    private var accessIndex: UInt64 = 0
    private let lock = NSLock()
}

struct ZenzCandidateEvaluator {
    static func evaluate(
        context: ZenzContext,
        input: String,
        inputCursorPosition: Int? = nil,
        candidate: Candidate,
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        memoizationCache: ZenzaiMemoizationCache
    ) -> CandidateEvaluationResult {
        // 固定された部分は、表記を左文脈に移し、読みを入力から除いて、残りだけを評価する。
        // モデルは固定された表記が読みを消費したことを知らないので、残したまま評価すると続きの判断がずれる。
        guard let fixedPrefix = prefixConstraint.fixedPrefix,
              candidate.text.utf8.count >= fixedPrefix.byteCount,
              input.count >= fixedPrefix.rubyCount else {
            return self.evaluateAsIs(
                context: context,
                input: input,
                inputCursorPosition: inputCursorPosition,
                candidate: candidate,
                requestRichCandidates: requestRichCandidates,
                prefixConstraint: prefixConstraint,
                personalizationMode: personalizationMode,
                versionDependentConfig: versionDependentConfig,
                memoizationCache: memoizationCache
            )
        }
        let fixed = Array(prefixConstraint.constraint.prefix(fixedPrefix.byteCount))
        var remainingCandidate = candidate
        remainingCandidate.text = String(decoding: candidate.text.utf8.dropFirst(fixedPrefix.byteCount), as: UTF8.self)
        remainingCandidate.data = self.droppingFixedData(candidate.data, byteCount: fixedPrefix.byteCount)
        var remainingConstraint = prefixConstraint
        remainingConstraint.constraint = Array(prefixConstraint.constraint.dropFirst(fixedPrefix.byteCount))
        remainingConstraint.fixedPrefix = nil
        let result = self.evaluateAsIs(
            context: context,
            input: String(input.dropFirst(fixedPrefix.rubyCount)),
            inputCursorPosition: inputCursorPosition.map { $0 - fixedPrefix.rubyCount },
            candidate: remainingCandidate,
            requestRichCandidates: requestRichCandidates,
            prefixConstraint: remainingConstraint,
            personalizationMode: personalizationMode,
            versionDependentConfig: self.appendingLeftSideContext(String(decoding: fixed, as: UTF8.self), to: versionDependentConfig),
            memoizationCache: memoizationCache
        )
        return self.prepending(fixed, to: result)
    }

    private static func evaluateAsIs(
        context: ZenzContext,
        input: String,
        inputCursorPosition: Int? = nil,
        candidate: Candidate,
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        memoizationCache: ZenzaiMemoizationCache
    ) -> CandidateEvaluationResult {
        debug("Evaluate", candidate)
        var userDictionaryPrompt = ""
        if !context.isJinenModel {
            // [Hazkey Community Patch]
            // jinen (Qwen3) は「辞書:」条件プロンプト (U+EE03-EE06体系) を学習していないため条件を付与しない
            for item in candidate.data where item.metadata.contains(.isFromUserDictionary) {
                userDictionaryPrompt += "\(item.word)(\(item.ruby.toHiragana()))"
            }
        }
        // [Hazkey Community Patch]
        // jinenではprofile/topic/style/preferenceと右文脈とalignment separatorを落としprofileは左文脈の先頭へ畳み込む
        // zenz v3と同一のタグ構造 (EE02/EE00/EE01) にする
        let effectiveConfig = context.isJinenModel
            ? Self.jinenEvaluationMode(versionDependentConfig)
            : versionDependentConfig
        let prompt = ZenzPromptBuilder.candidateEvaluationPrompt(
            input: input,
            inputCursorPosition: inputCursorPosition,
            userDictionaryPrompt: userDictionaryPrompt,
            versionDependentConfig: effectiveConfig
        )
        let candidateTextForEvaluation = self.candidateTextForEvaluation(
            candidateText: candidate.text,
            input: input,
            inputCursorPosition: inputCursorPosition,
            versionDependentConfig: effectiveConfig
        )
        let normalizedPrompt = context.normalizeForModel(prompt)
        let prevPrompt = context.previousEvaluationPrompt()
        let reusesAddressedPrefix = prevPrompt == normalizedPrompt && !requestRichCandidates
        // A cache hit must produce the same subsequent incremental-evaluation state
        // as a model evaluation.
        defer {
            context.setPreviousEvaluationPrompt(normalizedPrompt)
        }
        let cacheKey: ZenzEvaluationCacheKey? = if personalizationMode == nil {
            ZenzEvaluationCacheKey(
                prompt: prompt,
                candidateTextForEvaluation: candidateTextForEvaluation,
                originalCandidateText: candidate.text,
                prefixConstraint: prefixConstraint,
                requestRichCandidates: requestRichCandidates,
                reusesAddressedPrefix: reusesAddressedPrefix,
                candidateSegments: candidate.data.map {
                    .init(
                        word: $0.word,
                        ruby: $0.ruby,
                        isLearned: $0.metadata.contains(.isLearned)
                    )
                }
            )
        } else {
            nil
        }
        if let cacheKey, let cached = memoizationCache.cachedEvaluation(for: cacheKey) {
            return cached
        }
        func finish(_ result: CandidateEvaluationResult) -> CandidateEvaluationResult {
            if let cacheKey, result != .error {
                memoizationCache.cacheEvaluation(result, for: cacheKey)
            }
            return result
        }

        let promptTokens = context.encodeEvaluationPrompt(
            prompt,
            memoizationCache: memoizationCache
        )
        let candidateTokens = context.encode(candidateTextForEvaluation, addBOS: false, addEOS: false)
        let addressedTokens: [llama_token]
        if reusesAddressedPrefix {
            var prefix = ""
            for character in candidate.text {
                let newPrefix = prefix + String(character)
                if prefixConstraint.constraint.hasPrefix(newPrefix.utf8) {
                    prefix = newPrefix
                } else {
                    break
                }
            }
            addressedTokens = context.encode(prefix, addBOS: false, addEOS: false)
        } else {
            addressedTokens = []
        }

        let tokens = promptTokens + candidateTokens
        let startOffset = promptTokens.count - 1 + addressedTokens.count
        let n_vocab = Int(context.vocabSize)
        let learnedTokenPriorities: [Float]?
        if candidate.data.contains(where: { $0.metadata.contains(.isLearned) }) {
            let candidateLearnedTokens = candidate.data.flatMap {
                Array(
                    repeating: $0.metadata.contains(.isLearned) ? logf(self.learningPriority(data: $0)) : 0,
                    count: context.encode($0.word, addBOS: false).count
                )
            }
            if candidateLearnedTokens.count >= candidateTokens.count {
                learnedTokenPriorities = Array(candidateLearnedTokens.prefix(candidateTokens.count))
            } else {
                learnedTokenPriorities = candidateLearnedTokens + Array(
                    repeating: 0,
                    count: candidateTokens.count - candidateLearnedTokens.count
                )
            }
        } else {
            learnedTokenPriorities = nil
        }

        var score: Float = 0

        struct AlternativeHighProbToken: Comparable {
            static func < (lhs: AlternativeHighProbToken, rhs: AlternativeHighProbToken) -> Bool {
                lhs.probabilityRatioToMaxProb < rhs.probabilityRatioToMaxProb
            }

            var token: llama_token
            var constraint: [UInt8]
            var probabilityRatioToMaxProb: Float
        }

        struct TokenAndLogit: Comparable {
            static func < (lhs: TokenAndLogit, rhs: TokenAndLogit) -> Bool {
                lhs.logit < rhs.logit
            }
            var token: llama_token
            var logit: Float
        }

        var altTokens = FixedSizeHeap<AlternativeHighProbToken>(size: requestRichCandidates ? 5 : 0)
        // [Hazkey Community Patch]
        // 候補側のトークンだけを復号する
        // jinenのU+EE00〜EE02はCONTROLトークンでllama_token_to_piece(special: false)が空文字列に復号するため、
        // プロンプトを含めて復号しdropFirst(normalizedPrompt)で落とす旧方式は生成の先頭を欠落させた
        // zenzでは復号結果がnormalizedPromptとバイト同一なので結果は変わらない
        // 同じトークンスライスの先例はpersonalization分岐 (tokens[..<i].dropFirst(promptTokens.count)) にある
        // [Hazkey Community Patch] 候補の先頭部分の復号を積み上げ式にする。
        // i は評価ループで単調増加するため、前回までの復号結果に tokens[decodedCandidateEnd ..< i] だけを足す。
        // 呼ばれた時にだけ伸ばすので、非 rich 経路の復号量は従来と変わらず、学習優先で次へ進む経路も自然に含まれる。
        var decodedCandidateBytes: [UInt8] = []
        var decodedCandidateEnd = promptTokens.count
        func appendPieces(of slice: ArraySlice<llama_token>, to bytes: inout [UInt8]) {
            for token in slice {
                bytes.append(contentsOf: context.tokenToPiece(token: token).map { UInt8(bitPattern: $0) })
            }
        }
        func decodeCandidatePieces(upTo i: Int) -> [UInt8] {
            guard i >= decodedCandidateEnd else {
                var bytes: [UInt8] = []
                appendPieces(of: tokens[promptTokens.count ..< i], to: &bytes)
                return bytes
            }
            appendPieces(of: tokens[decodedCandidateEnd ..< i], to: &decodedCandidateBytes)
            decodedCandidateEnd = i
            return decodedCandidateBytes
        }

        var vocabScanNanoseconds: UInt64 = 0
        defer {
            if vocabScanNanoseconds > 0 {
                ZenzInferencePerf.shared.count { $0.vocabScanNanoseconds &+= vocabScanNanoseconds }
            }
        }

        func evaluateTokenRange(
            _ range: Range<Int>,
            logits: UnsafeMutablePointer<Float>,
            logitsStartIndex: Int
        ) -> CandidateEvaluationResult? {
            for i in range {
                let tokenID = tokens[i]
                let startIndex = (i - 1 - logitsStartIndex) * n_vocab
                let endIndex = startIndex + n_vocab
                var tokenHeap = FixedSizeHeap<TokenAndLogit>(size: requestRichCandidates ? 3 : 0)
                let maxItem: TokenAndLogit
                let vocabScanStartedAt = ZenzInferencePerf.shared.now()

                if let (mode, baseLM, personalLM) = personalizationMode, mode.alpha > 0 {
                    let prefix = tokens[..<i].dropFirst(promptTokens.count).map(Int.init)
                    let baseProb: [Float]
                    let personalProb: [Float]
                    if !prefix.isEmpty {
                        baseProb = baseLM.bulkPredict(prefix).map { logf(Float($0) + 1e-7) }
                        personalProb = personalLM.bulkPredict(prefix).map { logf(Float($0) + 1e-7) }
                    } else {
                        baseProb = Array(repeating: 0, count: n_vocab)
                        personalProb = baseProb
                    }
                    if requestRichCandidates {
                        for (vocabIndex, (lpb, lpp)) in zip(
                            0 ..< n_vocab,
                            zip(baseProb, personalProb)
                        ) {
                            let personalizedLogit = logits[startIndex + vocabIndex]
                                + mode.alpha * (lpp - lpb)
                            tokenHeap.insertIfPossible(
                                TokenAndLogit(
                                    token: llama_token(vocabIndex),
                                    logit: personalizedLogit
                                )
                            )
                        }
                        guard let maximum = tokenHeap.max else {
                            debug("Max Item could not be found for unknown reason")
                            return .error
                        }
                        maxItem = maximum
                    } else {
                        var maximum = TokenAndLogit(
                            token: 0,
                            logit: logits[startIndex] + mode.alpha * (personalProb[0] - baseProb[0])
                        )
                        for vocabIndex in 1 ..< n_vocab {
                            let personalizedLogit = logits[startIndex + vocabIndex]
                                + mode.alpha * (personalProb[vocabIndex] - baseProb[vocabIndex])
                            if personalizedLogit > maximum.logit {
                                maximum = TokenAndLogit(
                                    token: llama_token(vocabIndex),
                                    logit: personalizedLogit
                                )
                            }
                        }
                        maxItem = maximum
                    }
                } else if requestRichCandidates {
                    for index in startIndex ..< endIndex {
                        tokenHeap.insertIfPossible(
                            TokenAndLogit(
                                token: llama_token(index - startIndex),
                                logit: logits[index]
                            )
                        )
                    }
                    guard let maximum = tokenHeap.max else {
                        debug("Max Item could not be found for unknown reason")
                        return .error
                    }
                    maxItem = maximum
                } else {
                    var maximumToken = 0
                    var maximumLogit = logits[startIndex]
                    for vocabIndex in 1 ..< n_vocab {
                        let logit = logits[startIndex + vocabIndex]
                        if logit > maximumLogit {
                            maximumToken = vocabIndex
                            maximumLogit = logit
                        }
                    }
                    maxItem = TokenAndLogit(
                        token: llama_token(maximumToken),
                        logit: maximumLogit
                    )
                }
                vocabScanNanoseconds &+= ZenzInferencePerf.shared.elapsed(since: vocabScanStartedAt)

                if maxItem.token != tokenID {
                    if maxItem.token == context.eosToken {
                        let data = Data(decodeCandidatePieces(upTo: i))
                        let wholeResult = String(data: data, encoding: .utf8) ?? ""
                        return finish(.wholeResult(wholeResult))
                    } else {
                        let candidateTokenIndex = i - promptTokens.count
                        let learnedPriority = learnedTokenPriorities.map {
                            candidateTokenIndex < $0.count ? $0[candidateTokenIndex] : 0
                        } ?? 0
                        // softmaxの正規化項は両辺で相殺されるため、logitのまま比較できる。
                        let preferLearnedToken = learnedPriority > 0
                            && logits[startIndex + Int(tokenID)] + learnedPriority > maxItem.logit
                        if !preferLearnedToken {
                            let bytes = decodeCandidatePieces(upTo: i)
                                + context.tokenToPiece(token: maxItem.token).map { UInt8(bitPattern: $0) }
                            return finish(
                                .fixRequired(
                                    prefixConstraint: bytes
                                )
                            )
                        }
                    }
                } else if requestRichCandidates {
                    tokenHeap.removeMax()
                    let prefix = decodeCandidatePieces(upTo: i)

                    for item in tokenHeap.unordered {
                        altTokens.insertIfPossible(
                            AlternativeHighProbToken(
                                token: item.token,
                                constraint: prefix
                                    + context.tokenToPiece(token: item.token).map { UInt8(bitPattern: $0) },
                                probabilityRatioToMaxProb: expf(item.logit - maxItem.logit)
                            )
                        )
                    }
                }
                // この値は順位付けには使われない。正規化項の全語彙走査を避けるため、
                // 等価な順位を持つ未正規化logitを蓄積する。
                score += maxItem.logit
            }
            return nil
        }

        let firstTokenIndex = startOffset + 1
        if firstTokenIndex < tokens.endIndex {
            // token i の判定に必要なのは token i - 1 のlogitsまでなので、
            // 最終候補token自体はdecodeしない。
            let evaluationTokens = Array(tokens.dropLast())
            guard let logits = context.evaluationLogits(
                tokens: evaluationTokens,
                startOffset: startOffset,
                isRichEvaluation: requestRichCandidates
            ) else {
                debug("logits unavailable")
                return .error
            }
            if let result = evaluateTokenRange(
                firstTokenIndex ..< tokens.endIndex,
                logits: logits,
                logitsStartIndex: startOffset
            ) {
                return result
            }
        }
        return finish(
            .pass(
                score: score,
                alternativeConstraints: altTokens.unordered.sorted(by: >).map {
                    .init(probabilityRatio: $0.probabilityRatioToMaxProb, prefixConstraint: $0.constraint)
                }
            )
        )
    }

    /// jinen (Qwen3) 用にv3条件 (profile/topic/style/preference) と右文脈とalignment separatorを除いたモードを返す
    ///
    /// 既存zenzのモードは無変更
    ///
    /// - Parameter config: 条件を取り除く対象のバージョン別モード
    /// - Returns: jinen向けに調整したバージョン別モード
    /// - Note: [Hazkey Community Patch]
    static func jinenAdjustedMode(
        _ config: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> ConvertRequestOptions.ZenzaiVersionDependentMode {
        switch config {
        case .v2:
            return config
        case .v3(var mode):
            mode.profile = nil
            mode.topic = nil
            mode.style = nil
            mode.preference = nil
            mode.rightSideContext = nil
            mode.enableAlignmentSeparator = false
            return .v3(mode)
        }
    }

    /// jinen用の区切り文字
    ///
    /// karukan (jinen作者のIME、karukan-im/core/src/core/engine/model.rs) はペルソナと文脈を半角空白でつなぐが、
    /// hazkeyが使うllama.cpp内蔵トークナイザではNFKC後のU+0020がバイトフォールバック (230,154,133) になり学習時のHF符号化 (260) と食い違うことをtodo 1の判定ゲートで実測した (S=" "は0/12一致、S="。"は12/12一致)
    ///
    /// そのため既定は句点とする
    ///
    /// - Note: [Hazkey Community Patch]
    static let jinenPersonaSeparator = "。"

    /// jinen (Qwen3) の候補評価用モード
    ///
    /// jinenAdjustedModeの結果に元のv3 profileを左文脈の先頭へ「P + S + C」として畳み込む
    ///
    /// PはNFKC→trim→末尾25文字→trim (karukanのpersona正規化と同じ順序に切り口のtrimを加えたもの)
    ///
    /// SはjinenPersonaSeparator (Pが既に文末記号。、.!?で終わるときは空にする)
    ///
    /// Cは従来の切り詰め (mode.maxLeftSideContextLength ?? 40、40の出所はZenzPromptBuilder.trimmedModeContextの既定値) を先に適用した左文脈
    ///
    /// 畳み込み後の全体長をmaxLeftSideContextLengthに固定するためペルソナは別枠で残り後段のsuffixで切られない
    ///
    /// profileが空なら調整済みモードをそのまま返す
    ///
    /// - Parameter config: 畳み込み元のバージョン別モード
    /// - Returns: profileを左文脈へ畳み込んだバージョン別モード
    /// - Note: [Hazkey Community Patch]
    static func jinenEvaluationMode(
        _ config: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> ConvertRequestOptions.ZenzaiVersionDependentMode {
        switch config {
        case .v2:
            return config
        case .v3(let original):
            let adjusted = Self.jinenAdjustedMode(config)
            guard case .v3(var mode) = adjusted else {
                return adjusted
            }
            guard let rawProfile = original.profile else {
                return adjusted
            }
            let trimmed = rawProfile.precomposedStringWithCompatibilityMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return adjusted
            }
            let persona = String(trimmed.suffix(25))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !persona.isEmpty else {
                return adjusted
            }
            let separator: String
            if Self.jinenPersonaSeparator == "。",
               persona.hasSuffix("。") || persona.hasSuffix(".") || persona.hasSuffix("!")
                || persona.hasSuffix("?") {
                separator = ""
            } else {
                separator = Self.jinenPersonaSeparator
            }
            let context = String((mode.leftSideContext ?? "").suffix(mode.maxLeftSideContextLength ?? 40))
            let combined = persona + separator + context
            mode.leftSideContext = combined
            mode.maxLeftSideContextLength = combined.count
            return .v3(mode)
        }
    }

    static func candidateTextForEvaluation(
        candidateText: String,
        input: String,
        inputCursorPosition: Int?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> String {
        switch versionDependentConfig {
        case .v2:
            return candidateText
        case .v3(let mode):
            if mode.enableAlignmentSeparator,
               ZenzPromptBuilder.shouldInsertAlignmentSeparator(input: input, cursorPosition: inputCursorPosition) {
                return candidateText + ZenzPromptBuilder.alignmentSeparator
            }
            return candidateText
        }
    }

    /// `data` の先頭から、表記全体が固定部分に収まる要素だけを落とす
    static func droppingFixedData(_ data: [DicdataElement], byteCount: Int) -> [DicdataElement] {
        var coveredByteCount = 0
        return Array(
            data.drop { element in
                let nextCoveredByteCount = coveredByteCount + element.word.utf8.count
                guard nextCoveredByteCount <= byteCount else {
                    return false
                }
                coveredByteCount = nextCoveredByteCount
                return true
            }
        )
    }

    private static func appendingLeftSideContext(_ text: String, to config: ConvertRequestOptions.ZenzaiVersionDependentMode) -> ConvertRequestOptions.ZenzaiVersionDependentMode {
        switch config {
        case .v2(var mode):
            mode.leftSideContext = (mode.leftSideContext ?? "") + text
            return .v2(mode)
        case .v3(var mode):
            mode.leftSideContext = (mode.leftSideContext ?? "") + text
            return .v3(mode)
        }
    }

    /// 固定された表記を除いて評価した結果の制約に、その表記を戻す
    private static func prepending(_ fixed: [UInt8], to result: CandidateEvaluationResult) -> CandidateEvaluationResult {
        switch result {
        case .error:
            return .error
        case .pass(let score, let alternativeConstraints):
            return .pass(
                score: score,
                alternativeConstraints: alternativeConstraints.map {
                    .init(probabilityRatio: $0.probabilityRatio, prefixConstraint: fixed + $0.prefixConstraint)
                }
            )
        case .fixRequired(let prefixConstraint):
            return .fixRequired(prefixConstraint: fixed + prefixConstraint)
        case .wholeResult(let wholeResult):
            return .wholeResult(String(decoding: fixed, as: UTF8.self) + wholeResult)
        }
    }

    private static func learningPriority(data: DicdataElement) -> Float {
        // 文字数の長い候補ほど優先的に適用されるようにする
        // 積極的な複合語化の効果を期待
        if 1 <= data.ruby.count && data.ruby.count <= 4 {
            Float(data.ruby.count + 2)
        } else if 5 <= data.ruby.count && data.ruby.count <= 15 {
            Float(data.ruby.count * 2)
        } else {
            30
        }
    }
}
