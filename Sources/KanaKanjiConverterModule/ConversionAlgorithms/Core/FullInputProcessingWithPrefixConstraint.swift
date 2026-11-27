import Algorithms
import Foundation
import SwiftUtils

extension Kana2Kanji {
    // [Hazkey Community Patch]
    /// UTF-8バイト列をNFKC正規化後のUTF-8バイト列へ変換する
    ///
    /// 純ASCII列はNFKC不変のためそのまま返し、不正なUTF-8バイト列は生バイトへフォールバックする
    ///
    /// - Parameter bytes: 変換対象のUTF-8バイト列
    /// - Returns: NFKC正規化後のUTF-8バイト列
    static func normalizedNFKCBytes(_ bytes: [UInt8]) -> [UInt8] {
        if bytes.allSatisfy({ $0 < 0x80 }) {
            return bytes
        }
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            return bytes
        }
        return Array(string.precomposedStringWithCompatibilityMapping.utf8)
    }

    // [Hazkey Community Patch]
    /// 文字列をNFKC正規化後のUTF-8バイト列へ変換する
    ///
    /// 純ASCII文字列はNFKC不変のためFoundation正規化を省略する
    ///
    /// - Parameter string: 変換対象の文字列
    /// - Returns: NFKC正規化後のUTF-8バイト列
    private static func normalizedNFKCBytes(of string: String) -> [UInt8] {
        if string.utf8.allSatisfy({ $0 < 0x80 }) {
            return Array(string.utf8)
        }
        return Array(string.precomposedStringWithCompatibilityMapping.utf8)
    }

    // [Hazkey Community Patch]
    /// ラティス制約照合で使用する実効制約バイト列を構築する
    ///
    /// Jinenの未固定制約照合が有効な場合、先頭のfixedPrefix区間は生UTF-8のまま保持し、
    /// fixedPrefixより後ろのモデル制約区間だけをNFKC正規化バイト列へ変換する
    ///
    /// - Parameters:
    ///   - constraint: 照合対象のPrefixConstraint
    ///   - fixedByteCount: 先頭の生UTF-8固定区間のバイト数
    /// - Returns: 照合空間へ変換済みの実効制約バイト列
    private static func effectiveConstraintBytes(
        for constraint: PrefixConstraint,
        fixedByteCount: Int
    ) -> [UInt8] {
        guard constraint.normalizesUnfixedConstraintForJinen else {
            return constraint.constraint
        }
        let clampedFixedCount = min(fixedByteCount, constraint.constraint.count)
        guard clampedFixedCount > 0 else {
            return Self.normalizedNFKCBytes(constraint.constraint)
        }
        var result = Array(constraint.constraint.prefix(clampedFixedCount))
        result.append(contentsOf: Self.normalizedNFKCBytes(Array(constraint.constraint.dropFirst(clampedFixedCount))))
        return result
    }

    // [Hazkey Community Patch]
    /// JinenのNFKC制約照合時にノード表記を比較用バイト列へ変換する
    ///
    /// fixedPrefix区間内に収まる部分は生UTF-8のまま返し、fixedPrefixより後ろの部分だけをNFKC正規化する
    ///
    /// ノードがfixedPrefixの境界をまたぐ場合は、境界の手前を生UTF-8、後ろをNFKCとして連結する
    ///
    /// - Parameters:
    ///   - prevTotal: 直前ノードまでの比較空間における累積バイト数
    ///   - word: 現在ノードの辞書表記
    ///   - fixedByteCount: 先頭の生UTF-8固定区間のバイト数
    /// - Returns: 実効制約バイト列と同じ比較空間上のバイト列
    static func normalizedComparisonSegment(
        prevTotal: Int,
        word: String,
        fixedByteCount: Int
    ) -> [UInt8] {
        if fixedByteCount == 0 || prevTotal >= fixedByteCount {
            return Self.normalizedNFKCBytes(of: word)
        }
        let rawCount = word.utf8.count
        if prevTotal + rawCount <= fixedByteCount {
            return Array(word.utf8)
        }
        let rawTakeCount = fixedByteCount - prevTotal
        let utf8View = word.utf8
        let splitUTF8Index = utf8View.index(utf8View.startIndex, offsetBy: rawTakeCount)
        var segment = Array(utf8View[..<splitUTF8Index])
        if let splitIndex = String.Index(splitUTF8Index, within: word) {
            segment.append(contentsOf: Self.normalizedNFKCBytes(of: String(word[splitIndex...])))
        } else {
            segment.append(contentsOf: utf8View[splitUTF8Index...])
        }
        return segment
    }

    // Compute matched bytes with constraint and total candidate bytes for (prev-chain + currentWord)
    private func computeMatchedAndTotalLength(
        prev: borrowing RegisteredNode?,
        currentWord: borrowing String,
        constraintBytes: borrowing [UInt8],
        normalizesUnfixedForJinen: Bool,
        fixedByteCount: Int
    ) -> (matched: Int, total: Int) {
        let previousTotal = prev.map { Int($0.candidateUTF8Count) } ?? 0
        var matched = prev.map { Int($0.constraintMatchedUTF8Count) } ?? 0
        if !normalizesUnfixedForJinen {
            let total = previousTotal + currentWord.utf8.count

            // 直前までに不一致がなければ、今回追加する単語だけを照合する。
            // RegisteredNode生成時に累積値を保持するため、経路全体の再走査は不要。
            guard matched == min(previousTotal, constraintBytes.count) else {
                return (matched, total)
            }
            for byte in currentWord.utf8 {
                guard matched < constraintBytes.count, byte == constraintBytes[matched] else {
                    break
                }
                matched += 1
            }
            return (matched, total)
        }
        // [Hazkey Community Patch]
        // Jinenの未固定制約はNFKC空間で比較し、fixedPrefix区間だけは生UTF-8を維持する
        let segment = Self.normalizedComparisonSegment(
            prevTotal: previousTotal,
            word: currentWord,
            fixedByteCount: fixedByteCount
        )
        let total = previousTotal + segment.count
        guard matched == min(previousTotal, constraintBytes.count) else {
            return (matched, total)
        }
        for byte in segment {
            guard matched < constraintBytes.count, byte == constraintBytes[matched] else {
                break
            }
            matched += 1
        }
        return (matched, total)
    }

    /// 固定された表記は、学習データやユーザ辞書由来のノードにも制約として掛ける。
    /// 経路の表記が固定された byte 数に達するまで、制約と一致していることを求める。
    private func matchesFixedPrefix(matched: Int, total: Int, fixedByteCount: Int) -> Bool {
        matched >= min(total, fixedByteCount)
    }

    // Extend match with next word starting from current matched index
    private func extendMatched(
        matched: Int,
        previousTotal: Int,
        nextWord: borrowing String,
        constraintBytes: borrowing [UInt8],
        normalizesUnfixedForJinen: Bool,
        fixedByteCount: Int
    ) -> (matched: Int, mismatch: Bool, addedLength: Int) {
        if !normalizesUnfixedForJinen {
            let nextLength = nextWord.utf8.count
            var ci = matched
            if ci >= constraintBytes.count {
                return (ci, false, nextLength)
            }
            for b in nextWord.utf8 {
                if ci >= constraintBytes.count {
                    return (ci, false, nextLength)
                }
                if b != constraintBytes[ci] {
                    return (ci, true, nextLength)
                }
                ci += 1
            }
            return (ci, false, nextLength)
        }
        // [Hazkey Community Patch]
        // Jinen時はcomputeMatchedAndTotalLengthと同一の比較空間で一致と加算バイト数を算出する
        let segment = Self.normalizedComparisonSegment(
            prevTotal: previousTotal,
            word: nextWord,
            fixedByteCount: fixedByteCount
        )
        let nextLength = segment.count
        var ci = matched
        if ci >= constraintBytes.count {
            return (ci, false, nextLength)
        }
        for b in segment {
            if ci >= constraintBytes.count {
                return (ci, false, nextLength)
            }
            if b != constraintBytes[ci] {
                return (ci, true, nextLength)
            }
            ci += 1
        }
        return (ci, false, nextLength)
    }

    /// カナを漢字に変換する関数, 前提はなくかな列が与えられた場合。
    /// - Parameters:
    ///   - inputData: 入力データ。
    ///   - N_best: N_best。
    /// - Returns:
    ///   変換候補。
    /// ### 実装状況
    /// (0)多用する変数の宣言。
    ///
    /// (1)まず、追加された一文字に繋がるノードを列挙する。
    ///
    /// (2)次に、計算済みノードから、(1)で求めたノードにつながるようにregisterして、N_bestを求めていく。
    ///
    /// (3)(1)のregisterされた結果をresultノードに追加していく。この際EOSとの連接計算を行っておく。
    ///
    /// (4)ノードをアップデートした上で返却する。
    func kana2lattice_all_with_prefix_constraint(
        _ inputData: ComposingText,
        N_best: Int,
        constraint: PrefixConstraint,
        preprocessedLattice: Lattice? = nil,
        dicdataStoreState: DicdataStoreState
    ) -> (result: LatticeNode, lattice: Lattice) {
        debug("新規に計算を行います。inputされた文字列は\(inputData.input.count)文字分の\(inputData.convertTarget)。制約は\(constraint)")
        let result: LatticeNode = LatticeNode.EOSNode
        let inputCount: Int = inputData.input.count
        let surfaceCount = inputData.convertTarget.count
        let indexMap = LatticeDualIndexMap(inputData)
        let latticeIndices = indexMap.indices(inputCount: inputCount, surfaceCount: surfaceCount)
        let lattice: Lattice
        if let preprocessedLattice {
            lattice = preprocessedLattice
        } else {
            let rawNodes = latticeIndices.map { index in
                let inputRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let iIndex = index.inputIndex {
                    (iIndex, nil)
                } else {
                    nil
                }
                let surfaceRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let sIndex = index.surfaceIndex {
                    (sIndex, nil)
                } else {
                    nil
                }
                return dicdataStore.lookupDicdata(
                    composingText: inputData,
                    inputRange: inputRange,
                    surfaceRange: surfaceRange,
                    needTypoCorrection: false,
                    state: dicdataStoreState
                )
            }
            lattice = Lattice(
                inputCount: inputCount,
                surfaceCount: surfaceCount,
                rawNodes: rawNodes
            )
        }
        let fixedByteCount = constraint.fixedPrefix?.byteCount ?? 0
        // [Hazkey Community Patch]
        // Jinen時はfixedPrefixより後ろの制約だけをNFKC正規化して照合空間を統一し、Zenz時は生UTF-8のまま維持する
        let normalizesUnfixedForJinen = constraint.normalizesUnfixedConstraintForJinen
        let constraintBytes = Self.effectiveConstraintBytes(for: constraint, fixedByteCount: fixedByteCount)
        let constraintLength = constraintBytes.count
        // [Hazkey Community Patch]
        // 学習語の制約免除を外して再試行するとき (ignoreMemoryAndUserDictionary) は学習語にも制約をかける。ユーザ辞書の語は従来どおりモデル由来の制約を免除する (固定表記は掛ける)。
        // 上流は再試行で全ノードの制約を外しており、同じ学習語が再び選ばれていた。
        let constraintExemptMetadata: DicdataElementMetadata = constraint.ignoreMemoryAndUserDictionary ? [.isFromUserDictionary] : [.isLearned, .isFromUserDictionary]
        // 「i文字目から始まるnodes」に対して
        for (isHead, nodeArray) in lattice.indexedNodes(indices: latticeIndices) {
            // それぞれのnodeに対して
            for node in nodeArray {
                if node.prevs.isEmpty {
                    continue
                }
                if N_best == 1, let previous = node.prevs.first {
                    let wValue = node.data.value()
                    let value = previous.totalValue + wValue + (
                        isHead
                            ? self.dicdataStore.getCCValue(previous.data.rcid, node.data.lcid)
                            : 0
                    )
                    let nextIndex = indexMap.dualIndex(for: node.range.endIndex)
                    let matchState = self.computeMatchedAndTotalLength(
                        prev: previous,
                        currentWord: node.data.word,
                        constraintBytes: constraintBytes,
                        normalizesUnfixedForJinen: normalizesUnfixedForJinen,
                        fixedByteCount: fixedByteCount
                    )
                    if nextIndex.surfaceIndex == surfaceCount {
                        if node.data.metadata.isDisjoint(with: constraintExemptMetadata) {
                            let condition = if constraint.hasEOS {
                                matchState.matched == constraintLength
                                    && matchState.total == constraintLength
                            } else {
                                matchState.matched == constraintLength
                            }
                            guard condition else {
                                continue
                            }
                        } else if !self.matchesFixedPrefix(matched: matchState.matched, total: matchState.total, fixedByteCount: fixedByteCount) {
                            continue
                        }
                        let newNode = node.getRegisteredNode(
                            0,
                            value: value,
                            constraintState: matchState
                        )
                        // [Hazkey Community Patch]
                        // 文末に達した経路は全て登録し、最良候補は呼び出し側 (all_zenzai) が候補の評価値で選ぶ
                        // 評価値は意味連接のコストを含み、累積値 (totalValue) と順位が入れ替わり得る
                        // 累積値が最大の1本だけを残すと、ユーザ辞書の語などで N_best: 3 と異なる候補が選ばれていた
                        result.prevs.append(newNode)
                        continue
                    }

                    let ccLatter = self.dicdataStore.getCCLatter(node.data.rcid)
                    for nextNode in lattice[index: nextIndex] {
                        let newValue = value + ccLatter.get(nextNode.data.lcid)
                        if let current = nextNode.prevs.first,
                           current.totalValue >= newValue {
                            continue
                        }
                        if nextNode.data.metadata.isDisjoint(with: constraintExemptMetadata) {
                            guard matchState.matched
                                == min(matchState.total, constraintLength) else {
                                continue
                            }
                            let (matched, mismatch, nextLength) = self.extendMatched(
                                matched: matchState.matched,
                                previousTotal: matchState.total,
                                nextWord: nextNode.data.word,
                                constraintBytes: constraintBytes,
                                normalizesUnfixedForJinen: normalizesUnfixedForJinen,
                                fixedByteCount: fixedByteCount
                            )
                            if mismatch {
                                continue
                            }
                            let newTotal = matchState.total + nextLength
                            // [Hazkey Community Patch] 末尾ノードでは制約との完全一致を許す。末尾でない経路は厳密なprefixのままにする。
                            let isFinalNextNode = indexMap.dualIndex(for: nextNode.range.endIndex).surfaceIndex == surfaceCount
                            let isCompatible = if constraint.hasEOS {
                                matched == newTotal && (newTotal < constraintLength || (newTotal == constraintLength && isFinalNextNode))
                            } else {
                                matched == constraintLength
                                    || (newTotal <= constraintLength && matched == newTotal)
                            }
                            guard isCompatible else {
                                continue
                            }
                        } else {
                            let (matched, _, nextLength) = self.extendMatched(
                                matched: matchState.matched,
                                previousTotal: matchState.total,
                                nextWord: nextNode.data.word,
                                constraintBytes: constraintBytes,
                                normalizesUnfixedForJinen: normalizesUnfixedForJinen,
                                fixedByteCount: fixedByteCount
                            )
                            let newTotal = matchState.total + nextLength
                            guard self.matchesFixedPrefix(matched: matched, total: newTotal, fixedByteCount: fixedByteCount) else {
                                continue
                            }
                        }
                        let newNode = node.getRegisteredNode(
                            0,
                            value: newValue,
                            constraintState: matchState
                        )
                        if nextNode.prevs.isEmpty {
                            nextNode.prevs.append(newNode)
                        } else {
                            nextNode.prevs[0] = newNode
                        }
                    }
                    continue
                }
                // 生起確率を取得する。
                let wValue: PValue = node.data.value()
                if isHead {
                    // valuesを更新する
                    node.values = node.prevs.map {$0.totalValue + wValue + self.dicdataStore.getCCValue($0.data.rcid, node.data.lcid)}
                } else {
                    // valuesを更新する
                    node.values = node.prevs.map {$0.totalValue + wValue}
                }
                // 変換した文字数
                let nextIndex = indexMap.dualIndex(for: node.range.endIndex)
                // 文字数がcountと等しい場合登録する
                if nextIndex.surfaceIndex == surfaceCount {
                    // Precompute matched/total lengths per prev for (prev + current word)
                    let mtPerPrev: [(matched: Int, total: Int)] = node.prevs.indices.map { idx in
                        self.computeMatchedAndTotalLength(
                            prev: node.prevs[idx],
                            currentWord: node.data.word,
                            constraintBytes: constraintBytes,
                            normalizesUnfixedForJinen: normalizesUnfixedForJinen,
                            fixedByteCount: fixedByteCount
                        )
                    }
                    for index in node.prevs.indices {
                        // メタ情報が制約免除対象と重なる語はモデル制約を掛けない (ユーザ辞書の語は常に免除、学習語はignoreMemoryAndUserDictionaryが偽のときだけ免除)。ただし、固定表記は免除の語にも掛ける。
                        if node.data.metadata.isDisjoint(with: constraintExemptMetadata) {
                            let (matched, total) = mtPerPrev[index]
                            // 最終チェック（EOS時の条件に合わせる）
                            let condition = if constraint.hasEOS {
                                matched == constraintLength && total == constraintLength
                            } else {
                                matched == constraintLength
                            }
                            guard condition else {
                                continue
                            }
                        } else if !self.matchesFixedPrefix(matched: mtPerPrev[index].matched, total: mtPerPrev[index].total, fixedByteCount: fixedByteCount) {
                            continue
                        }
                        let newnode: RegisteredNode = node.getRegisteredNode(
                            index,
                            value: node.values[index],
                            constraintState: mtPerPrev[index]
                        )
                        if N_best == 1 {
                            if let current = result.prevs.first {
                                if newnode.totalValue > current.totalValue {
                                    result.prevs[0] = newnode
                                }
                            } else {
                                result.prevs.append(newnode)
                            }
                        } else {
                            result.prevs.append(newnode)
                        }
                    }
                } else {
                    // Precompute matched/total lengths per prev for (prev + current word)
                    let mtPerPrev: [(matched: Int, total: Int)] = node.prevs.indices.map { idx in
                        self.computeMatchedAndTotalLength(
                            prev: node.prevs[idx],
                            currentWord: node.data.word,
                            constraintBytes: constraintBytes,
                            normalizesUnfixedForJinen: normalizesUnfixedForJinen,
                            fixedByteCount: fixedByteCount
                        )
                    }
                    let ccLatter = self.dicdataStore.getCCLatter(node.data.rcid)
                    // nodeの繋がる次にあり得る全てのnextnodeに対して
                    for nextnode in lattice[index: nextIndex] {
                        // クラスの連続確率を計算する。
                        let ccValue: PValue = ccLatter.get(nextnode.data.lcid)
                        // nodeの持っている全てのprevnodeに対して
                        for (index, value) in node.values.enumerated() {
                            let newValue: PValue = ccValue + value
                            // 追加すべきindexを取得する
                            let lastindex: Int = (nextnode.prevs.lastIndex(where: {$0.totalValue >= newValue}) ?? -1) + 1
                            if lastindex == N_best {
                                continue
                            }
                            // 制約チェックは重いので、必要なものに対してのみ行う
                            // common prefixが単語か制約のどちらかに一致している必要
                            // 制約 AB 単語 ABC (OK)
                            // 制約 AB 単語 A   (OK)
                            // 制約 AB 単語 AC  (NG)
                            // メタ情報が制約免除対象と重なる語はモデル制約を掛けない (ユーザ辞書の語は常に免除、学習語はignoreMemoryAndUserDictionaryが偽のときだけ免除)。ただし、固定表記は免除の語にも掛ける。
                            if nextnode.data.metadata.isDisjoint(with: constraintExemptMetadata) {
                                let (matchedPrev, totalPrev) = mtPerPrev[index]
                                // ensure no prior mismatch
                                guard matchedPrev == min(totalPrev, constraintLength) else {
                                    continue
                                }
                                // matchedPrevまではconstraintBytesと一致しているので、その先をチェックする
                                let (matchedExt, mismatch, nextLen) = self.extendMatched(
                                    matched: matchedPrev,
                                    previousTotal: totalPrev,
                                    nextWord: nextnode.data.word,
                                    constraintBytes: constraintBytes,
                                    normalizesUnfixedForJinen: normalizesUnfixedForJinen,
                                    fixedByteCount: fixedByteCount
                                )
                                if mismatch {
                                    continue
                                }
                                let newTotal = totalPrev + nextLen
                                // [Hazkey Community Patch] 末尾ノードでは制約との完全一致を許す。末尾でない経路は厳密なprefixのままにする。
                                let isFinalNextNode = indexMap.dualIndex(for: nextnode.range.endIndex).surfaceIndex == surfaceCount
                                let ok: Bool = if constraint.hasEOS {
                                    // require strict prefix of constraint, except for the final node reaching EOS
                                    matchedExt == newTotal && (newTotal < constraintLength || (newTotal == constraintLength && isFinalNextNode))
                                } else {
                                    // accept either: constraint is prefix of candidate, or candidate is prefix of constraint
                                    (matchedExt == constraintLength)
                                        || (newTotal <= constraintLength && matchedExt == newTotal)
                                }
                                guard ok else {
                                    continue
                                }
                            } else {
                                let (matchedPrev, totalPrev) = mtPerPrev[index]
                                let (matchedExt, _, nextLen) = self.extendMatched(
                                    matched: matchedPrev,
                                    previousTotal: totalPrev,
                                    nextWord: nextnode.data.word,
                                    constraintBytes: constraintBytes,
                                    normalizesUnfixedForJinen: normalizesUnfixedForJinen,
                                    fixedByteCount: fixedByteCount
                                )
                                let newTotal = totalPrev + nextLen
                                guard self.matchesFixedPrefix(matched: matchedExt, total: newTotal, fixedByteCount: fixedByteCount) else {
                                    continue
                                }
                            }
                            // カウントがオーバーしている場合は除去する
                            if nextnode.prevs.count >= N_best {
                                nextnode.prevs.removeLast()
                            }
                            let newnode: RegisteredNode = node.getRegisteredNode(
                                index,
                                value: newValue,
                                constraintState: mtPerPrev[index]
                            )
                            // removeしてからinsertした方が速い (insertはO(N)なので)
                            nextnode.prevs.insert(newnode, at: lastindex)
                        }
                    }
                }
            }
        }
        return (result: result, lattice: lattice)
    }

    /// 逐次入力の差分更新を活用してLatticeを構築
    func buildLatticeWithIncrementalCache(
        inputData: ComposingText,
        inputCount: Int,
        surfaceCount: Int,
        incrementalCacheInfo: (inputData: ComposingText, lattice: Lattice)?,
        dicdataStoreState: DicdataStoreState
    ) -> Lattice {
        let indexMap = LatticeDualIndexMap(inputData)
        let latticeIndices = indexMap.indices(inputCount: inputCount, surfaceCount: surfaceCount)
        guard let incrementalCacheInfo else {
            // キャッシュがない場合は通常の辞書引き
            let rawNodes = latticeIndices.map { index in
                let inputRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let iIndex = index.inputIndex {
                    (iIndex, nil)
                } else {
                    nil
                }
                let surfaceRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let sIndex = index.surfaceIndex {
                    (sIndex, nil)
                } else {
                    nil
                }
                return dicdataStore.lookupDicdata(
                    composingText: inputData,
                    inputRange: inputRange,
                    surfaceRange: surfaceRange,
                    needTypoCorrection: false,
                    state: dicdataStoreState
                )
            }
            return Lattice(
                inputCount: inputCount,
                surfaceCount: surfaceCount,
                rawNodes: rawNodes
            )
        }

        // 差分を計算
        let oldInput = incrementalCacheInfo.inputData.input
        let newInput = inputData.input
        let oldSurface = incrementalCacheInfo.inputData.convertTarget
        let newSurface = inputData.convertTarget

        // 共通プレフィックスを計算
        let commonInputCount = zip(oldInput, newInput).prefix { $0 == $1 }.count
        let commonSurfaceCount = zip(oldSurface, newSurface).prefix { $0 == $1 }.count

        // inputの中間が変更された場合は通常の処理に戻す。
        // Roman/AZIKの逐次入力では、inputは単純なsuffix追加でも
        // convertTargetの未確定suffixが `k -> か` のように書き換わる。
        // そのケースは下で独立セグメント境界まで戻し、suffixだけ作り直す。
        if commonInputCount != oldInput.count {
            let rawNodes = latticeIndices.map { index in
                let inputRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let iIndex = index.inputIndex {
                    (iIndex, nil)
                } else {
                    nil
                }
                let surfaceRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let sIndex = index.surfaceIndex {
                    (sIndex, nil)
                } else {
                    nil
                }
                return dicdataStore.lookupDicdata(
                    composingText: inputData,
                    inputRange: inputRange,
                    surfaceRange: surfaceRange,
                    needTypoCorrection: false,
                    state: dicdataStoreState
                )
            }
            return Lattice(
                inputCount: inputCount,
                surfaceCount: surfaceCount,
                rawNodes: rawNodes
            )
        }

        // 逐次入力の場合：既存Latticeから共通部分を再利用し、新しい部分のみ辞書引き
        let cachedLattice = incrementalCacheInfo.lattice

        // surfaceの末尾書き換えがある場合、commonSurfaceCountがローマ字変換の
        // 独立セグメント内を指すことがある。その位置ではinput/surfaceの
        // 対応が一意でないため、直前の独立セグメント境界まで戻す。
        let reusableBoundary: (input: Int, surface: Int)
        if commonSurfaceCount == oldSurface.count {
            reusableBoundary = (commonInputCount, commonSurfaceCount)
        } else {
            reusableBoundary = incrementalCacheInfo.inputData
                .inputIndexToSurfaceIndexMap()
                .lazy
                .filter { $0.value <= commonSurfaceCount }
                .map { (input: $0.key, surface: $0.value) }
                .max {
                    if $0.surface == $1.surface {
                        $0.input < $1.input
                    } else {
                        $0.surface < $1.surface
                    }
                } ?? (0, 0)
        }
        let reusableInputCount = reusableBoundary.input
        let reusableSurfaceCount = reusableBoundary.surface

        // 純粋なsuffix追加では既存Latticeの全ノードがそのまま有効なので、
        // 各ノード配列のfilterと再構築を避ける。削除を伴う場合だけprefixを切り出す。
        var newLattice = if reusableInputCount == oldInput.count,
                            reusableSurfaceCount == oldSurface.count {
            cachedLattice
        } else {
            cachedLattice.prefix(
                inputCount: reusableInputCount,
                surfaceCount: reusableSurfaceCount
            )
        }
        newLattice.resetNodeStates()

        // 新規部分に関わる辞書引き（既存部分から新規部分にまたがる単語も含む）
        // lookupDicdata自体がmaxlengthより長い範囲を探索しないため、それより前から
        // 始まるノードは新規suffixへ到達できない。
        let earliestAffectedInputIndex = max(
            0,
            reusableInputCount + 1 - self.dicdataStore.maxlength
        )
        let earliestAffectedSurfaceIndex = max(
            0,
            reusableSurfaceCount + 1 - self.dicdataStore.maxlength
        )
        let additionalRawNodes = latticeIndices.map { index in
            let inputRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let iIndex = index.inputIndex,
                                                                              iIndex >= earliestAffectedInputIndex,
                                                                              max(reusableInputCount, iIndex) < inputCount {
                (iIndex, max(reusableInputCount, iIndex) ..< inputCount)
            } else {
                nil
            }
            let surfaceRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let sIndex = index.surfaceIndex,
                                                                                sIndex >= earliestAffectedSurfaceIndex,
                                                                                max(reusableSurfaceCount, sIndex) < surfaceCount {
                (sIndex, max(reusableSurfaceCount, sIndex) ..< surfaceCount)
            } else {
                nil
            }

            // 新規部分に関わる場合のみ辞書引き
            if inputRange != nil || surfaceRange != nil {
                return dicdataStore.lookupDicdata(
                    composingText: inputData,
                    inputRange: inputRange,
                    surfaceRange: surfaceRange,
                    needTypoCorrection: false,
                    state: dicdataStoreState
                )
            } else {
                // 完全に既存部分のみの場合は空配列
                return []
            }
        }

        // 追加部分をマージ
        let additionalLattice = Lattice(
            inputCount: inputCount,
            surfaceCount: surfaceCount,
            rawNodes: additionalRawNodes
        )

        newLattice.merge(additionalLattice)
        return newLattice
    }
}
