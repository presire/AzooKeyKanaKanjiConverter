import Algorithms
import EfficientNGram
import Foundation
import SwiftUtils

extension Kana2Kanji {
    struct ZenzaiCache {
        init(
            _ inputData: ComposingText,
            constraint: PrefixConstraint,
            satisfyingCandidate: Candidate?,
            evaluatedSatisfyingCandidate: Candidate? = nil,
            prefixCandidate: Candidate? = nil,
            lattice: Lattice? = nil
        ) {
            self.inputData = inputData
            self.prefixConstraint = constraint
            self.satisfyingCandidate = satisfyingCandidate
            self.evaluatedSatisfyingCandidate = evaluatedSatisfyingCandidate
            self.prefixCandidate = prefixCandidate
            self.cachedLattice = lattice
            self.cachedLatticeInputData = lattice == nil ? nil : inputData
        }

        private init(
            _ inputData: ComposingText,
            constraint: PrefixConstraint,
            satisfyingCandidate: Candidate?,
            evaluatedSatisfyingCandidate: Candidate?,
            prefixCandidate: Candidate?,
            cachedLattice: Lattice?,
            cachedLatticeInputData: ComposingText?
        ) {
            self.inputData = inputData
            self.prefixConstraint = constraint
            self.satisfyingCandidate = satisfyingCandidate
            self.evaluatedSatisfyingCandidate = evaluatedSatisfyingCandidate
            self.prefixCandidate = prefixCandidate
            self.cachedLattice = cachedLattice
            self.cachedLatticeInputData = cachedLatticeInputData
        }

        private var prefixConstraint: PrefixConstraint
        private var satisfyingCandidate: Candidate?
        private(set) var evaluatedSatisfyingCandidate: Candidate?
        /// 入力の先頭が決まっている候補。読みが入力の先頭に残っている間、表記を固定部分にする。
        private(set) var prefixCandidate: Candidate?
        private var inputData: ComposingText
        private var cachedLattice: Lattice?
        private var cachedLatticeInputData: ComposingText?

        /// 共有済みの変換結果を使う場合、現在の制約だけを更新し、直近の完全な
        /// ラティスは次の未キャッシュ入力の差分構築用アンカーとして保持する。
        func updatingResult(
            for newInputData: ComposingText,
            constraint: PrefixConstraint,
            satisfyingCandidate: Candidate
        ) -> ZenzaiCache {
            ZenzaiCache(
                newInputData,
                constraint: constraint,
                satisfyingCandidate: satisfyingCandidate,
                evaluatedSatisfyingCandidate: satisfyingCandidate,
                prefixCandidate: self.prefixCandidate(remainingIn: newInputData),
                cachedLattice: self.cachedLattice,
                cachedLatticeInputData: self.cachedLatticeInputData
            )
        }

        /// 先頭の候補を設定し、以降の変換で先頭の制約として使う。
        /// 直近のラティスは差分構築用に保持する。
        func settingPrefixCandidate(_ candidate: Candidate) -> ZenzaiCache {
            ZenzaiCache(
                self.inputData,
                constraint: self.prefixConstraint,
                satisfyingCandidate: candidate,
                evaluatedSatisfyingCandidate: candidate,
                prefixCandidate: candidate,
                cachedLattice: self.cachedLattice,
                cachedLatticeInputData: self.cachedLatticeInputData
            )
        }

        /// 明示的に受け入れた先頭候補だけを残し他のキャッシュ内容を破棄したコピーを返す
        ///
        /// 補助辞書の切替などで辞書由来の変換結果が無効になる場合に使い制約と確定候補とラティスは捨てる
        ///
        /// - Returns: 受け入れた先頭候補だけを持つZenzaiCache
        func keepingOnlyAcceptedPrefix() -> ZenzaiCache {
            ZenzaiCache(
                self.inputData,
                constraint: PrefixConstraint([]),
                satisfyingCandidate: nil,
                evaluatedSatisfyingCandidate: nil,
                prefixCandidate: self.prefixCandidate,
                cachedLattice: nil,
                cachedLatticeInputData: nil
            )
        }

        func getNewConstraint(for newInputData: ComposingText, userDictionary: [DicdataElement]) -> PrefixConstraint {
            self.fixingPrefix(self.getReplaceableConstraint(for: newInputData, userDictionary: userDictionary), for: newInputData)
        }

        /// 先頭の候補の読みが入力の先頭にそのまま残っていればその候補。残っていなければ nil で、以降は引き継がない。
        func prefixCandidate(remainingIn newInputData: ComposingText) -> Candidate? {
            guard let prefixCandidate,
                  newInputData.convertTarget.toKatakana().hasPrefix(prefixCandidate.data.map(\.ruby).joined()) else {
                return nil
            }
            return prefixCandidate
        }

        /// 先頭の候補の読みが入力の先頭にそのまま残っている間、その表記を固定部分にする。
        /// 制約が表記で始まっていればその長さを固定し、始まっていなければ表記で置き換える。
        private func fixingPrefix(_ constraint: PrefixConstraint, for newInputData: ComposingText) -> PrefixConstraint {
            guard let prefixCandidate = self.prefixCandidate(remainingIn: newInputData) else {
                return constraint
            }
            let fixed = Array(prefixCandidate.data.map(\.word).joined().utf8)
            let fixedPrefix = PrefixConstraint.FixedPrefix(
                byteCount: fixed.count,
                rubyCount: prefixCandidate.data.map(\.ruby).joined().count
            )
            if constraint.constraint.hasPrefix(fixed) {
                var fixedConstraint = constraint
                fixedConstraint.fixedPrefix = fixedPrefix
                return fixedConstraint
            }
            return PrefixConstraint(fixed, fixedPrefix: fixedPrefix)
        }

        /// モデルの評価で置き換わりうる制約。
        private func getReplaceableConstraint(for newInputData: ComposingText, userDictionary: [DicdataElement]) -> PrefixConstraint {
            let newReading = Array(newInputData.convertTarget.toKatakana())
            if let satisfyingCandidate {
                let evaluatedReading = satisfyingCandidate.data.map(\.ruby).joined()
                let cutoff = Self.userDictionaryWordStart(
                    in: newReading,
                    completedAfter: Self.commonPrefixCount(newReading, evaluatedReading),
                    userDictionary: userDictionary
                )
                var current = newReading[...]
                var consumedCount = 0
                var constraint = [UInt8]()
                for item in satisfyingCandidate.data {
                    if current.starts(with: item.ruby) {
                        if let cutoff, consumedCount + item.ruby.count > cutoff {
                            break
                        }
                        constraint += item.word.utf8
                        current = current.dropFirst(item.ruby.count)
                        consumedCount += item.ruby.count
                    }
                }
                return PrefixConstraint(constraint)
            } else if newInputData.convertTarget.hasPrefix(inputData.convertTarget) {
                let evaluatedCount = inputData.convertTarget.count
                if let cutoff = Self.userDictionaryWordStart(in: newReading, completedAfter: evaluatedCount, userDictionary: userDictionary),
                   cutoff < evaluatedCount {
                    // 制約の表記と読みの対応が分からないため、語の手前で切れない
                    return PrefixConstraint([])
                }
                // hasEOSの場合は落とすために改めて作り直す
                return PrefixConstraint(self.prefixConstraint.constraint)
            } else {
                return PrefixConstraint([])
            }
        }

        // [Hazkey Community Patch]
        // 前回の評価の後で読みが揃ったユーザ辞書の語の開始位置 (該当する語が無ければ nil)
        // 前回の評価ではその語が候補に現れず、モデルに辞書の語として示されていない
        // そのまま前回の表記 (ひらがなのことが多い) を制約に残すと、制約がラティスからその語を締め出し、
        // 以後の評価でも語が候補に現れず、表記が固定される
        // 語の開始位置より前だけを制約に残し、語の部分はモデルに評価し直させる
        static func userDictionaryWordStart(in reading: [Character], completedAfter evaluatedCount: Int, userDictionary: [DicdataElement]) -> Int? {
            var earliest: Int?
            for element in userDictionary {
                let ruby = Array(element.ruby)
                guard !ruby.isEmpty, ruby.count <= reading.count else {
                    continue
                }
                // 語の終端が前回の評価済みの読みを越える開始位置だけを調べる
                let lowerBound = max(0, evaluatedCount - ruby.count + 1)
                let upperBound = min(reading.count - ruby.count, (earliest ?? reading.count) - 1)
                guard lowerBound <= upperBound else {
                    continue
                }
                for start in lowerBound ... upperBound where reading[start ..< start + ruby.count].elementsEqual(ruby) {
                    earliest = start
                    break
                }
            }
            return earliest
        }

        private static func commonPrefixCount(_ lhs: [Character], _ rhs: String) -> Int {
            zip(lhs, rhs).prefix { $0 == $1 }.count
        }

        func getPreprocessedLattice(for newInputData: ComposingText, kanaKanji: Kana2Kanji, dicdataStoreState: DicdataStoreState) -> Lattice? {
            guard let cachedLattice, let cachedLatticeInputData else { return nil }

            // 同じComposingTextなら既存のlatticeをそのまま返す
            if newInputData.input == cachedLatticeInputData.input
                && newInputData.convertTarget == cachedLatticeInputData.convertTarget {
                cachedLattice.resetNodeStates()
                return cachedLattice
            }

            // 逐次入力の場合は差分更新でlatticeを構築
            return kanaKanji.buildLatticeWithIncrementalCache(
                inputData: newInputData,
                inputCount: newInputData.input.count,
                surfaceCount: newInputData.convertTarget.count,
                incrementalCacheInfo: (inputData: cachedLatticeInputData, lattice: cachedLattice),
                dicdataStoreState: dicdataStoreState
            )
        }
    }

    struct PrefixConstraint: Sendable, Equatable, Hashable, CustomStringConvertible {
        /// 先頭の決まっている部分。モデルはこの表記を左文脈、この読みを入力済みとして扱い、評価しない。
        struct FixedPrefix: Sendable, Equatable, Hashable {
            /// `constraint` の先頭のうち、固定された表記の byte 数
            var byteCount: Int
            /// 入力 (カタカナ) の先頭のうち、その表記が読んだ文字数
            var rubyCount: Int
        }

        init(_ constraint: [UInt8], hasEOS: Bool = false, ignoreMemoryAndUserDictionary: Bool = false, fixedPrefix: FixedPrefix? = nil) {
            self.constraint = constraint
            self.hasEOS = hasEOS
            self.ignoreMemoryAndUserDictionary = ignoreMemoryAndUserDictionary
            self.fixedPrefix = fixedPrefix
        }

        var constraint: [UInt8]
        var hasEOS: Bool
        var ignoreMemoryAndUserDictionary: Bool
        var fixedPrefix: FixedPrefix?

        var description: String {
            "PrefixConstraint(constraint: \"\(String(decoding: self.constraint, as: UTF8.self))\", hasEOS: \(self.hasEOS), ignoreMemoryAndUserDictionary: \(self.ignoreMemoryAndUserDictionary), fixedPrefix: \(String(describing: self.fixedPrefix)))"
        }

        var isEmpty: Bool {
            self.constraint.isEmpty && !self.hasEOS
        }
    }

    /// zenzaiシステムによる完全変換。
    func all_zenzai(
        _ inputData: ComposingText,
        zenz: Zenz,
        zenzaiCache: ZenzaiCache?,
        zenzaiMemoizationCache: ZenzaiMemoizationCache,
        inferenceLimit: Int,
        requestRichCandidates: Bool,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        dicdataStoreState: DicdataStoreState
    ) -> (result: LatticeNode, lattice: Lattice, cache: ZenzaiCache) {
        // [Hazkey Community Patch]
        // 任意のCPU遅延期限 (HAZKEY_ZENZAI_DEADLINE_MS) の監視窓を開く
        ZenzInferencePerf.shared.beginDeadlineWindow()
        // [Hazkey Community Patch]
        // jinen (Qwen3) はNFKC正規化空間で出力するため、辞書表記との制約比較をNFKC正規化して行う (fixRequired/wholeResultの空振り防止)
        let isJinen = zenz.isJinenModel
        let latticeInputData = Self.zenzaiLatticeInputData(for: inputData)
        let zenzInputCursorPosition = Self.zenzaiInputCursorPosition(for: inputData)
        let inputStyle = inputData.input.last?.inputStyle ?? .direct
        let defersEvaluationForPendingInput = !requestRichCandidates
            && personalizationMode == nil
            && self.resolvePredictiveInputSource(
                composingText: inputData,
                inputStyle: inputStyle
            ).droppedSuffixCount > 0
        var constraint = zenzaiCache?.getNewConstraint(
            for: latticeInputData,
            userDictionary: dicdataStoreState.dynamicUserDictionary
        ) ?? PrefixConstraint([])
        let prefixCandidate = zenzaiCache?.prefixCandidate(remainingIn: latticeInputData)
        let resolvedConversionCacheKey: ZenzResolvedConversionCacheKey? =
            if !requestRichCandidates,
               personalizationMode == nil,
               dicdataStoreState.canShareStaticConversionResults() {
                Self.resolvedConversionCacheKey(
                    for: inputData,
                    keyboardLanguage: dicdataStoreState.keyboardLanguage,
                    versionDependentConfig: versionDependentConfig,
                    prefixConstraint: constraint,
                    inferenceLimit: inferenceLimit
                )
            } else {
                nil
        }
        if let resolvedConversionCacheKey,
           let cached = zenzaiMemoizationCache.cachedResolvedConversion(
               for: resolvedConversionCacheKey
           ) {
            // 全文経路とは別にprocessResultが参照する先頭辞書ノードだけを復元する。
            // 可変な探索状態を持つラティス本体は共有しない。
            let lattice = Lattice(
                inputCount: latticeInputData.input.count,
                surfaceCount: latticeInputData.convertTarget.count,
                rawNodes: [
                    cached.resultLatticeHead.nodes.map {
                        LatticeNode(data: $0.data, range: $0.range)
                    }
                ]
            )
            let eosNode = LatticeNode.EOSNode
            eosNode.prevs = cached.resultPrevs
            let nextCache = zenzaiCache?.updatingResult(
                for: latticeInputData,
                constraint: cached.prefixConstraint,
                satisfyingCandidate: cached.satisfyingCandidate
            ) ?? ZenzaiCache(
                latticeInputData,
                constraint: cached.prefixConstraint,
                satisfyingCandidate: cached.satisfyingCandidate,
                evaluatedSatisfyingCandidate: cached.satisfyingCandidate
            )
            return (
                eosNode,
                lattice,
                nextCache
            )
        }
        debug("initial constraint", constraint)
        let eosNode = LatticeNode.EOSNode
        var lattice: Lattice = Lattice()
        var latticeIsComplete = true
        var constructedCandidates: [(RegisteredNode, Candidate)] = []
        var insertedCandidates: [(RegisteredNode, Candidate)] = []
        func makeCache(
            constraint: PrefixConstraint,
            satisfyingCandidate: Candidate?,
            evaluatedSatisfyingCandidate: Candidate? = nil
        ) -> ZenzaiCache {
            ZenzaiCache(
                latticeInputData,
                constraint: constraint,
                satisfyingCandidate: satisfyingCandidate,
                evaluatedSatisfyingCandidate: evaluatedSatisfyingCandidate,
                prefixCandidate: prefixCandidate,
                lattice: latticeIsComplete ? lattice : nil
            )
        }
        defer {
            eosNode.prevs = insertedCandidates.map(\.0)
        }
        var inferenceLimit = inferenceLimit
        var draftIteration = 0
        while true {
            let start = Date()
            // 学習・ユーザ辞書・personalizationの影響がなく、入力と制約が完全一致する
            // 初回draftだけを共有する。後続draftは直前の探索状態に依存するため対象外。
            let draftCacheKey: ZenzDraftConversionCacheKey? = if draftIteration == 0,
                                                                 !requestRichCandidates,
                                                                 personalizationMode == nil,
                                                                 dicdataStoreState.canShareStaticConversionResults() {
                ZenzDraftConversionCacheKey(
                    input: latticeInputData.input,
                    convertTarget: latticeInputData.convertTarget,
                    convertTargetCursorPosition: zenzInputCursorPosition,
                    keyboardLanguage: dicdataStoreState.keyboardLanguage,
                    versionDependentConfig: versionDependentConfig,
                    prefixConstraint: constraint
                )
            } else {
                nil
            }
            let cachedDraft = draftCacheKey.flatMap {
                zenzaiMemoizationCache.cachedDraftConversion(for: $0)
            }
            let preprocessedLattice: Lattice?
            if cachedDraft != nil {
                preprocessedLattice = nil
            } else if !lattice.isEmpty {
                // 今回の`all_zenzai`の呼び出し内部で使われているキャッシュ（lattice）が存在する場合はそちらを優先する
                lattice.resetNodeStates()
                preprocessedLattice = lattice
            } else {
                // latticeがまだemptyの場合、zenzaiCache側に存在するキャッシュの活用を試みる
                preprocessedLattice = zenzaiCache?.getPreprocessedLattice(
                    for: latticeInputData,
                    kanaKanji: self,
                    dicdataStoreState: dicdataStoreState
                )
            }
            let draftResult: (result: LatticeNode, lattice: Lattice)
            let draftStartedAt = ZenzInferencePerf.shared.now()
            if let cachedDraft {
                let cachedLattice = Lattice(
                    inputCount: latticeInputData.input.count,
                    surfaceCount: latticeInputData.convertTarget.count,
                    rawNodes: [
                        cachedDraft.resultLatticeHead.nodes.map {
                            LatticeNode(data: $0.data, range: $0.range)
                        }
                    ]
                )
                let cachedResult = LatticeNode.EOSNode
                cachedResult.prevs = cachedDraft.resultPrevs
                draftResult = (cachedResult, cachedLattice)
                // processResultが参照する先頭ノードだけを復元しているため、
                // 後続draftのpreprocessed latticeとしては利用できない。
                latticeIsComplete = false
            } else if constraint.isEmpty {
                draftResult = self.kana2lattice_all(
                    latticeInputData,
                    N_best: 2,
                    needTypoCorrection: false,
                    preprocessedLattice: preprocessedLattice,
                    dicdataStoreState: dicdataStoreState
                )
            } else {
                // rich候補を要求しない通常モードでは最良経路しか消費しない。
                // rich候補用の代替制約探索では従来どおり3-bestを保持する。
                let constrainedNBest = requestRichCandidates ? 3 : 1
                draftResult = self.kana2lattice_all_with_prefix_constraint(
                    latticeInputData,
                    N_best: constrainedNBest,
                    constraint: constraint,
                    preprocessedLattice: preprocessedLattice,
                    dicdataStoreState: dicdataStoreState
                )
            }
            if cachedDraft == nil {
                let draftNanoseconds = ZenzInferencePerf.shared.elapsed(since: draftStartedAt)
                ZenzInferencePerf.shared.count {
                    $0.draftCount += 1
                    $0.draftNanoseconds &+= draftNanoseconds
                }
            }
            if let draftCacheKey, cachedDraft == nil {
                zenzaiMemoizationCache.cacheDraftConversion(
                    ZenzDraftConversion(
                        resultPrevs: draftResult.result.prevs,
                        resultLatticeHead: ZenzResolvedLatticeHead(
                            nodes: draftResult.lattice[
                                index: .bothIndex(inputIndex: 0, surfaceIndex: 0)
                            ].map {
                                ZenzResolvedLatticeNode(data: $0.data, range: $0.range)
                            }
                        )
                    ),
                    for: draftCacheKey
                )
            }
            if lattice.isEmpty {
                // 初回のみ
                lattice = draftResult.lattice
            }
            let candidates = draftResult.result.getCandidateData().map(self.processClauseCandidate)
            constructedCandidates.append(contentsOf: zip(draftResult.result.prevs, candidates))
            var best: (Int, Candidate)?
            for (i, cand) in candidates.enumerated() {
                if let (_, c) = best, cand.value > c.value {
                    best = (i, cand)
                } else if best == nil {
                    best = (i, cand)
                }
            }
            draftIteration += 1
            guard var (index, candidate) = best else {
                debug("best was not found!")
                // Emptyの場合
                // 制約が満たせない場合は無視する
                return (eosNode, lattice, makeCache(constraint: PrefixConstraint([]), satisfyingCandidate: nil))
            }

            debug("Constrained draft modeling", -start.timeIntervalSinceNow)
            reviewLoop: while true {
                // resultsを更新
                // ここでN-Bestも並び変えていることになる
                insertedCandidates.insert((draftResult.result.prevs[index], candidate), at: 0)
                if inferenceLimit == 0 {
                    debug("inference limit! \(candidate.text) is used for excuse")
                    // When inference occurs more than maximum times, then just return result at this point
                    return (eosNode, lattice, makeCache(constraint: constraint, satisfyingCandidate: candidate))
                }
                // [Hazkey Community Patch]
                // 任意のCPU遅延期限 (HAZKEY_ZENZAI_DEADLINE_MS) が切れたら非ニューラル候補へフォールバックする
                // 直前のinferenceLimit==0分岐と同じ早期復帰の形を取る
                if ZenzInferencePerf.shared.deadlineExpired() {
                    debug("HAZKEY_ZENZAI_DEADLINE_MS exceeded! \(candidate.text) is used for excuse")
                    return (eosNode, lattice, makeCache(constraint: constraint, satisfyingCandidate: candidate))
                }
                if defersEvaluationForPendingInput {
                    // ローマ字表で未確定のsuffixは、次のキーでかなへ置換される。
                    // モデルが未確定ASCIIを評価しても結果を再利用できないため、
                    // かな列が確定するまで評価を省略する。未評価のdraftは制約へ
                    // 昇格させず、現在の入力にも適用できた直前のLM承認候補だけを
                    // stable prefixとして引き継ぐ。
                    let evaluatedCandidate = constraint.isEmpty
                        ? nil
                        : zenzaiCache?.evaluatedSatisfyingCandidate
                    return (
                        eosNode,
                        lattice,
                        makeCache(
                            constraint: constraint,
                            satisfyingCandidate: evaluatedCandidate,
                            evaluatedSatisfyingCandidate: evaluatedCandidate
                        )
                    )
                }
                let reviewResult = zenz.candidateEvaluate(
                    convertTarget: inputData.convertTarget,
                    convertTargetCursorPosition: zenzInputCursorPosition,
                    candidates: [candidate],
                    requestRichCandidates: requestRichCandidates,
                    prefixConstraint: constraint,
                    personalizationMode: personalizationMode,
                    versionDependentConfig: versionDependentConfig,
                    memoizationCache: zenzaiMemoizationCache
                )
                inferenceLimit -= 1
                ZenzInferencePerf.shared.count { $0.evaluationCount += 1 }
                let nextAction = self.review(
                    candidateIndex: index,
                    candidates: candidates,
                    reviewResult: reviewResult,
                    constraint: &constraint,
                    isJinen: isJinen
                )
                switch nextAction {
                case .return(let constraint, let alternativeConstraints, let satisfied):
                    if requestRichCandidates {
                        // alternativeConstraintsに従い、insertedCandidatesにデータを追加する
                        for alternativeConstraint in alternativeConstraints.reversed() where alternativeConstraint.probabilityRatio > 0.25 {
                            let normalizedAlternativeConstraint = Self.normalizedZenzConstraint(
                                alternativeConstraint.prefixConstraint,
                                defaultHasEOS: false,
                                ignoreMemoryAndUserDictionary: false
                            )
                            // constructed candidatesのうちalternativeConstraint.prefixConstraintを満たすものを列挙する
                            let mostLiklyCandidate = constructedCandidates.filter {
                                self.candidate($0.1, satisfies: normalizedAlternativeConstraint, isJinen: isJinen)
                            }.max {
                                $0.1.value < $1.1.value
                            }
                            if let mostLiklyCandidate {
                                // 0番目は最良候補
                                insertedCandidates.insert(mostLiklyCandidate, at: 1)
                            } else if alternativeConstraint.probabilityRatio > 0.5 {
                                // 十分に高い確率の場合、変換器を実際に呼び出して候補を作ってもらう
                                lattice.resetNodeStates()
                                let alternativeDraftStartedAt = ZenzInferencePerf.shared.now()
                                let draftResult = self.kana2lattice_all_with_prefix_constraint(
                                    latticeInputData,
                                    N_best: 3,
                                    constraint: normalizedAlternativeConstraint,
                                    preprocessedLattice: lattice,
                                    dicdataStoreState: dicdataStoreState
                                )
                                let alternativeDraftNanoseconds = ZenzInferencePerf.shared.elapsed(since: alternativeDraftStartedAt)
                                ZenzInferencePerf.shared.count {
                                    $0.alternativeDraftCount += 1
                                    $0.draftNanoseconds &+= alternativeDraftNanoseconds
                                }
                                let candidates = draftResult.result.getCandidateData().map(self.processClauseCandidate)
                                let best: (Int, Candidate)? = candidates.enumerated().reduce(into: (Int, Candidate)?.none) { best, pair in
                                    if let (_, c) = best, pair.1.value > c.value {
                                        best = pair
                                    } else if best == nil {
                                        best = pair
                                    }
                                }
                                if let (index, candidate) = best {
                                    insertedCandidates.insert((draftResult.result.prevs[index], candidate), at: 1)
                                }
                            }
                        }
                    }
                    if satisfied {
                        if let resolvedConversionCacheKey,
                           insertedCandidates.allSatisfy({
                               $0.1.data.allSatisfy {
                                   $0.metadata.isDisjoint(
                                       with: [.isLearned, .isFromUserDictionary]
                                   )
                               }
                           }) {
                            zenzaiMemoizationCache.cacheResolvedConversion(
                                ZenzResolvedConversion(
                                    resultPrevs: insertedCandidates.map(\.0),
                                    resultLatticeHead: ZenzResolvedLatticeHead(
                                        nodes: lattice[
                                            index: .bothIndex(inputIndex: 0, surfaceIndex: 0)
                                        ].map {
                                            ZenzResolvedLatticeNode(
                                                data: $0.data,
                                                range: $0.range
                                            )
                                        }
                                    ),
                                    prefixConstraint: constraint,
                                    satisfyingCandidate: candidate
                                ),
                                for: resolvedConversionCacheKey
                            )
                        }
                        return (
                            eosNode,
                            lattice,
                            makeCache(
                                constraint: constraint,
                                satisfyingCandidate: candidate,
                                evaluatedSatisfyingCandidate: candidate
                            )
                        )
                    } else {
                        return (eosNode, lattice, makeCache(constraint: constraint, satisfyingCandidate: nil))
                    }
                case .continue:
                    ZenzInferencePerf.shared.count { $0.redraftCount += 1 }
                    if !latticeIsComplete {
                        lattice = Lattice()
                        latticeIsComplete = true
                    }
                    break reviewLoop
                case .retry(let candidateIndex):
                    ZenzInferencePerf.shared.count { $0.retryCount += 1 }
                    index = candidateIndex
                    candidate = candidates[candidateIndex]
                }
            }
        }
    }

    private enum NextAction {
        case `return`(constraint: PrefixConstraint, alternativeConstraints: [CandidateEvaluationResult.AlternativeConstraint], satisfied: Bool)
        case `continue`
        case `retry`(candidateIndex: Int)
    }

    static func zenzaiLatticeInputData(for inputData: ComposingText) -> ComposingText {
        inputData.isAtEndIndex ? inputData : inputData.prefixToCursorPosition()
    }

    static func zenzaiInputCursorPosition(for inputData: ComposingText) -> Int? {
        inputData.isAtEndIndex ? nil : inputData.convertTargetCursorPosition
    }

    /// 解決済み変換キャッシュのキーを組み立てる
    ///
    /// ラティス入力 (カーソルまで) だけをキーにするとカーソルより前の読みが同じで右側の読みが違う入力が同じ結果を共有してしまうため評価に使った全文の読みも含める
    ///
    /// - Parameters:
    ///   - inputData: 変換対象の入力
    ///   - keyboardLanguage: キーボード言語
    ///   - versionDependentConfig: バージョン別モード
    ///   - prefixConstraint: 先頭制約
    ///   - inferenceLimit: 推論回数の上限
    /// - Returns: 解決済み変換キャッシュのキー
    /// - Note: [Hazkey Community Patch]
    static func resolvedConversionCacheKey(
        for inputData: ComposingText,
        keyboardLanguage: KeyboardLanguage,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        prefixConstraint: PrefixConstraint,
        inferenceLimit: Int
    ) -> ZenzResolvedConversionCacheKey {
        let latticeInputData = Self.zenzaiLatticeInputData(for: inputData)
        return ZenzResolvedConversionCacheKey(
            input: latticeInputData.input,
            convertTarget: latticeInputData.convertTarget,
            convertTargetCursorPosition: Self.zenzaiInputCursorPosition(for: inputData),
            keyboardLanguage: keyboardLanguage,
            versionDependentConfig: versionDependentConfig,
            prefixConstraint: prefixConstraint,
            inferenceLimit: inferenceLimit,
            evaluationConvertTarget: inputData.convertTarget
        )
    }

    private func review(
        candidateIndex: Int,
        candidates: [Candidate],
        reviewResult: consuming CandidateEvaluationResult,
        constraint: inout PrefixConstraint,
        isJinen: Bool
    ) -> NextAction {
        switch reviewResult {
        case .error:
            // 何らかのエラーが発生
            debug("error")
            return .return(constraint: constraint, alternativeConstraints: [], satisfied: false)
        case .pass(let score, let alternativeConstraints):
            // 合格
            debug("passed:", score)
            return .return(constraint: constraint, alternativeConstraints: alternativeConstraints, satisfied: true)
        case .fixRequired(let prefixConstraint):
            let newConstraint = Self.normalizedZenzConstraint(
                prefixConstraint,
                defaultHasEOS: false,
                ignoreMemoryAndUserDictionary: constraint.ignoreMemoryAndUserDictionary,
                fixedPrefix: constraint.fixedPrefix
            )
            if constraint == newConstraint {
                if !constraint.ignoreMemoryAndUserDictionary,
                   candidates[candidateIndex].data.contains(where: { !$0.metadata.isDisjoint(with: [.isLearned]) }),
                   candidates[candidateIndex].data.allSatisfy({ $0.metadata.isDisjoint(with: [.isFromUserDictionary]) }) {
                    // [Hazkey Community Patch]
                    // 明示的に登録されたユーザ辞書候補を保持する
                    // 同じ制約の繰り返しはユーザ辞書エントリを含む場合既存の諦め経路を使い学習エントリだけがこのリトライを残す
                    // ignoreMemoryAndUserDictionaryでない場合、学習候補がモデルにリジェクトされた可能性を検討する
                    debug("same constraint (fixRequired), but retry without memory and user dictionary:", newConstraint)
                    constraint.ignoreMemoryAndUserDictionary = true
                    for (i, candidate) in candidates.indexed() where i != candidateIndex {
                        if self.candidate(candidate, satisfies: newConstraint, isJinen: isJinen) && self.heuristicRetryValidation(candidate.text) {
                            debug("found \(candidate.text) as another retry")
                            return .retry(candidateIndex: i)
                        }
                    }
                    return .continue
                } else {
                    // それ以外の場合で同じ制約が2回連続で出てきたら諦める
                    debug("same constraint (fixRequired):", newConstraint)
                    return .return(constraint: PrefixConstraint([]), alternativeConstraints: [], satisfied: false)
                }
            }
            // 制約が得られたので、更新する
            let isIncrementalUpdate = newConstraint.constraint.hasPrefix(constraint.constraint)
            constraint = newConstraint
            debug("update constraint:", constraint)
            if isIncrementalUpdate {
                // もし制約を満たす候補があるならそれを使って再レビューチャレンジを戦うことで、推論を減らせる
                // この処理の正当性は、prefix constraintが漸進的に更新され、candidatesの構築時に可能な候補がすべて確認されたことに由来する
                // このため、学習候補などが最終ドラフトとして採択され、prefix constraintが漸進的更新になっていない場合（!isIncrementalUpdate）この処理は行わない
                for (i, candidate) in candidates.indexed() where i != candidateIndex {
                    if self.candidate(candidate, satisfies: newConstraint, isJinen: isJinen) && self.heuristicRetryValidation(candidate.text) {
                        debug("found \(candidate.text) as another retry")
                        return .retry(candidateIndex: i)
                    }
                }
            }
            return .continue
        case .wholeResult(let wholeConstraint):
            let newConstraint = Self.normalizedZenzConstraint(
                Array(wholeConstraint.utf8),
                defaultHasEOS: true,
                ignoreMemoryAndUserDictionary: constraint.ignoreMemoryAndUserDictionary,
                fixedPrefix: constraint.fixedPrefix
            )
            // 同じ制約が2回連続で出てきたら諦める
            if constraint == newConstraint {
                if !constraint.ignoreMemoryAndUserDictionary,
                   candidates[candidateIndex].data.contains(where: { !$0.metadata.isDisjoint(with: [.isLearned]) }),
                   candidates[candidateIndex].data.allSatisfy({ $0.metadata.isDisjoint(with: [.isFromUserDictionary]) }) {
                    // [Hazkey Community Patch]
                    // 明示的に登録されたユーザ辞書候補を保持する
                    // 同じ制約の繰り返しはユーザ辞書エントリを含む場合既存の諦め経路を使い学習エントリだけがこのリトライを残す
                    // ignoreMemoryAndUserDictionaryでない場合、学習候補がモデルにリジェクトされた可能性を検討する
                    debug("same constraint (wholeResult), but retry without memory and user dictionary:", constraint)
                    constraint.ignoreMemoryAndUserDictionary = true
                    for (i, candidate) in candidates.indexed() where i != candidateIndex {
                        if self.candidate(candidate, satisfies: newConstraint, isJinen: isJinen) && self.heuristicRetryValidation(candidate.text) {
                            debug("found \(candidate.text) as another retry")
                            return .retry(candidateIndex: i)
                        }
                    }
                    return .continue
                } else {
                    // それ以外の場合で同じ制約が2回連続で出てきたら諦める
                    debug("same constraint (wholeResult):", constraint)
                    return .return(constraint: PrefixConstraint([]), alternativeConstraints: [], satisfied: false)
                }
            }
            // 制約が得られたので、更新する
            debug("update whole constraint:", wholeConstraint)
            let isIncrementalUpdate = newConstraint.constraint.hasPrefix(constraint.constraint)
            constraint = newConstraint
            if isIncrementalUpdate {
                // もし制約を満たす候補があるならそれを使って再レビューチャレンジを戦うことで、推論を減らせる
                // 上記と同様に、prefix constraintが漸進的更新になっていない場合（!isIncrementalUpdate）この処理は行わない
                for (i, candidate) in candidates.indexed() where i != candidateIndex {
                    if self.candidate(candidate, satisfies: newConstraint, isJinen: isJinen) && self.heuristicRetryValidation(candidate.text) {
                        debug("found \(candidate.text) as another retry")
                        return .retry(candidateIndex: i)
                    }
                }
            }
            return .continue
        }
    }

    static func normalizedZenzConstraint(
        _ constraintBytes: [UInt8],
        defaultHasEOS: Bool,
        ignoreMemoryAndUserDictionary: Bool,
        fixedPrefix: PrefixConstraint.FixedPrefix? = nil
    ) -> PrefixConstraint {
        // fixedPrefixの byte 数をそのまま引き継げるのは、ZenzCandidateEvaluator.evaluate が結果の先頭に固定された表記を戻すため
        if let prefix = self.prefixBeforeAlignmentSeparator(in: constraintBytes) {
            return PrefixConstraint(prefix, hasEOS: true, ignoreMemoryAndUserDictionary: ignoreMemoryAndUserDictionary, fixedPrefix: fixedPrefix)
        }
        return PrefixConstraint(constraintBytes, hasEOS: defaultHasEOS, ignoreMemoryAndUserDictionary: ignoreMemoryAndUserDictionary, fixedPrefix: fixedPrefix)
    }

    private static func prefixBeforeAlignmentSeparator(in bytes: [UInt8]) -> [UInt8]? {
        let separator = Array(ZenzPromptBuilder.alignmentSeparator.utf8)
        guard bytes.count >= separator.count else {
            return nil
        }
        for index in 0 ... (bytes.count - separator.count) {
            if bytes[index ..< index + separator.count].elementsEqual(separator) {
                return Array(bytes[..<index])
            }
        }
        return nil
    }

    private func candidate(_ candidate: Candidate, satisfies constraint: PrefixConstraint, isJinen: Bool = false) -> Bool {
        if !isJinen {
            // zenz は従来どおり生バイト比較 (挙動不変)。
            if constraint.hasEOS {
                return candidate.text.utf8.elementsEqual(constraint.constraint)
            } else {
                return candidate.text.utf8.hasPrefix(constraint.constraint)
            }
        }
        // [Hazkey Community Patch]
        // jinen (Qwen3) はNFKC正規化空間で出力するため、モデル出力由来の制約バイトと辞書候補表記をNFKC正規化して比較する
        let candidateText = candidate.text.precomposedStringWithCompatibilityMapping
        let constraintText = String(decoding: constraint.constraint, as: UTF8.self)
            .precomposedStringWithCompatibilityMapping
        if constraint.hasEOS {
            return candidateText.utf8.elementsEqual(constraintText.utf8)
        } else {
            return candidateText.utf8.hasPrefix(constraintText.utf8)
        }
    }

    /// リトライの候補に対して恣意的なバリデーションを実施する
    private func heuristicRetryValidation(_ text: String) -> Bool {
        // 合成濁点・半濁点
        if text.unicodeScalars.contains("\u{3099}") || text.unicodeScalars.contains("\u{309A}") {
            return false
        }
        return true
    }
}
