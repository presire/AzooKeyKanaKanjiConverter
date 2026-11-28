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

    // [Hazkey Community Patch]
    /// JinenのNFKC制約照合で使う比較用セグメントを呼び出し単位で保持するキャッシュ
    ///
    /// 同じラティスでも経路ごとに直前までの比較バイト数が異なるため、ノード単体ではなく
    /// ノードと分割位置の組でセグメントを再利用する
    ///
    /// 保存先は変換呼び出しごとに生成するローカル値であり、変換結果には影響しない
    struct JinenComparisonSegmentCache {
        /// 分割セグメントのキー
        ///
        /// 同じノードでもfixedPrefixの境界で切り取る位置が異なれば別のセグメントになる
        private struct SplitKey: Hashable {
            /// 対象ノードの識別子
            let nodeID: ObjectIdentifier
            /// ノード表記の生UTF-8先頭から境界までに含めるバイト数
            let rawTakeCount: Int
        }

        /// 全セグメントを連結して保持する追記専用のバイト列
        ///
        /// 全体セグメントと分割セグメントの両方を格納する
        ///
        /// 分割セグメントの登録は preparedFullSegmentStorage による全体セグメント用の容量確保より先に起きる場合がある
        ///
        /// Zenz経路は全体セグメントも分割セグメントも書かないため、キャッシュ生成だけではヒープ確保を発生させない
        ///
        /// ヒット時は範囲を取り出すだけでヒープ確保と配列の参照カウント操作を発生させない
        private var storage: [UInt8] = []

        /// ノード識別子から全体セグメント範囲を引く呼び出し単位の表
        ///
        /// 標準の辞書はハッシュ計算とバケット管理の分だけ引き当てが重く、同じ変換呼び出しで
        /// 何万回も引かれるため、識別子をそのまま索引にできる開番地法の表を自前で持つ
        private var fullRangeTable = NodeRangeTable()

        /// ノード表記の生UTF-8バイト列ごとの全体セグメント範囲
        ///
        /// FoundationのNFKC出力は、Swiftが正準等価とみなす文字列の間でも異なるバイト列になる場合がある
        ///
        /// 文字列の等値判定をキーにすると異なる生バイト列が同じ範囲へ統合されるため、生UTF-8バイト列をキーにする
        ///
        /// まず fullRangeTable を引き、外れた場合だけ生UTF-8バイト列をキーにこの表を引く
        ///
        /// 容量は最初の全体セグメント登録まで確保しない
        private var fullRangeByRawUTF8: [[UInt8]: Range<Int>] = [:]

        /// ノード識別子と切り取り位置の組ごとの分割セグメント範囲
        private var splitRangeByKey: [SplitKey: Range<Int>] = [:]

        /// 全体セグメント用の容量を確保済みかを示す印
        ///
        /// 確保を最初の全体セグメント登録まで遅らせ、Zenz経路の生成コストを増やさない
        private var preparedFullSegmentStorage = false

        /// ノード識別子から全体セグメント範囲を引く呼び出し単位の表
        ///
        /// 標準の辞書と同じ識別子キーでも、呼び出しごとに捨てる表ではハッシュの汎用処理が
        /// そのまま費用になるため、識別子のビット列を直接索引へ写す表を持つ
        ///
        /// 表は最初の登録まで配列を確保せず、Zenz経路では生成するだけでヒープを使わない
        private struct NodeRangeTable {
            /// 格納済みのノード識別子で、0を空きスロットの番人にする
            private var keys: [UInt] = []

            /// keysと同じ位置に並ぶセグメント範囲
            private var ranges: [Range<Int>] = []

            /// 格納済みの件数
            private var count = 0

            /// 最初の登録時に確保するスロット数
            private static let initialCapacity = 2048

            /// キーを容量内の開始スロットへ写す
            ///
            /// 容量は2の冪なので、64ビットの黄金比乗算の上位ビットだけで一様な索引になる
            ///
            /// 乗算とシフトの前に UInt64 へ広げるため、UInt が32ビットの環境 (Android armv7 など) でも桁あふれしない
            ///
            /// - Parameters:
            ///   - key: 写像するノード識別子
            ///   - capacity: 現在のスロット数
            /// - Returns: 探索を始めるスロット番号
            private static func bucketIndex(for key: UInt, capacity: Int) -> Int {
                let shift = 64 - capacity.trailingZeroBitCount
                return Int((UInt64(key) &* 0x9E37_79B9_7F4A_7C15) >> shift)
            }

            /// 登録済みのセグメント範囲を返す
            ///
            /// 開始スロットから線形に進み、空きスロットに達したら未登録と判断する
            ///
            /// - Parameter node: 照合対象のラティスノード
            /// - Returns: 登録済みの範囲またはnil
            func range(for node: LatticeNode) -> Range<Int>? {
                let key = UInt(bitPattern: ObjectIdentifier(node))
                guard key != 0, !self.keys.isEmpty else {
                    return nil
                }
                let mask = self.keys.count - 1
                var index = Self.bucketIndex(for: key, capacity: self.keys.count)
                while true {
                    let storedKey = self.keys[index]
                    if storedKey == key {
                        return self.ranges[index]
                    }
                    if storedKey == 0 {
                        return nil
                    }
                    index = (index + 1) & mask
                }
            }

            /// セグメント範囲を登録する
            ///
            /// 件数が容量の半分に達したら倍へ広げ、既存の全件を移し直して引き当てを保つ
            ///
            /// - Parameters:
            ///   - range: 登録するセグメント範囲
            ///   - node: 範囲の対象となるラティスノード
            mutating func insert(_ range: Range<Int>, for node: LatticeNode) {
                let key = UInt(bitPattern: ObjectIdentifier(node))
                guard key != 0 else {
                    return
                }
                if self.keys.isEmpty {
                    self.resize(to: Self.initialCapacity)
                } else if self.count * 2 >= self.keys.count {
                    self.resize(to: self.keys.count * 2)
                }
                self.store(range, key: key)
            }

            /// 空きスロットが見つかるまで線形に探して書き込む
            ///
            /// 書き込みの前に件数が容量の半分未満であるため空きスロットは必ず存在する
            ///
            /// - Parameters:
            ///   - range: 登録するセグメント範囲
            ///   - key: 登録するノード識別子
            private mutating func store(_ range: Range<Int>, key: UInt) {
                let mask = self.keys.count - 1
                var index = Self.bucketIndex(for: key, capacity: self.keys.count)
                while self.keys[index] != 0, self.keys[index] != key {
                    index = (index + 1) & mask
                }
                if self.keys[index] == 0 {
                    self.keys[index] = key
                    self.count += 1
                }
                self.ranges[index] = range
            }

            /// 容量を指定値へ広げて全件を移し直す
            ///
            /// 移し直しは既存のキーを順に再配置するため、元の並び順に依存しない
            ///
            /// - Parameter newCapacity: 新しいスロット数
            private mutating func resize(to newCapacity: Int) {
                let oldKeys = self.keys
                let oldRanges = self.ranges
                self.keys = Array(repeating: 0, count: newCapacity)
                self.ranges = Array(repeating: 0 ..< 0, count: newCapacity)
                self.count = 0
                let mask = newCapacity - 1
                for index in oldKeys.indices where oldKeys[index] != 0 {
                    let key = oldKeys[index]
                    var newIndex = Self.bucketIndex(for: key, capacity: newCapacity)
                    while self.keys[newIndex] != 0 {
                        newIndex = (newIndex + 1) & mask
                    }
                    self.keys[newIndex] = key
                    self.ranges[newIndex] = oldRanges[index]
                    self.count += 1
                }
            }
        }

        /// 指定ノードの比較用セグメント範囲を返す
        ///
        /// ノード全体がfixedPrefixの外にある場合はNFKC適用後のセグメントを返す
        ///
        /// prevTotalと生UTF-8バイト数の和がfixedByteCount以下になる場合はnilを返し、呼び出し側に生UTF-8の直接照合を委ねる
        ///
        /// ノードがfixedPrefixの境界をまたぐ場合は境界の手前を生UTF-8、後ろをNFKCにしたセグメントを返す
        ///
        /// 境界が文字の内側を切る場合は生バイトのまま保持し、境界をまたいで文字を合成しない (normalizedComparisonSegment と同じ規則)
        ///
        /// - Parameters:
        ///   - node: 比較対象のラティスノード
        ///   - prevTotal: 直前ノードまでの比較空間における累積バイト数
        ///   - fixedByteCount: 先頭の生UTF-8固定区間のバイト数
        /// - Returns: セグメントの格納範囲またはnil
        mutating func segmentRange(for node: LatticeNode, prevTotal: Int, fixedByteCount: Int) -> Range<Int>? {
            let word = node.data.word
            if fixedByteCount == 0 || prevTotal >= fixedByteCount {
                if let range = self.fullRangeTable.range(for: node) {
                    return range
                }
                let rawBytes = Array(word.utf8)
                if let range = self.fullRangeByRawUTF8[rawBytes] {
                    self.fullRangeTable.insert(range, for: node)
                    return range
                }
                if !self.preparedFullSegmentStorage {
                    self.preparedFullSegmentStorage = true
                    self.storage.reserveCapacity(4096)
                    self.fullRangeByRawUTF8.reserveCapacity(512)
                }
                let start = self.storage.count
                if rawBytes.allSatisfy({ $0 < 0x80 }) {
                    self.storage.append(contentsOf: rawBytes)
                } else {
                    self.storage.append(contentsOf: word.precomposedStringWithCompatibilityMapping.utf8)
                }
                let range = start ..< self.storage.count
                self.fullRangeByRawUTF8[rawBytes] = range
                self.fullRangeTable.insert(range, for: node)
                return range
            }
            let rawCount = word.utf8.count
            if prevTotal + rawCount <= fixedByteCount {
                return nil
            }
            let rawTakeCount = fixedByteCount - prevTotal
            let key = SplitKey(nodeID: ObjectIdentifier(node), rawTakeCount: rawTakeCount)
            if let range = self.splitRangeByKey[key] {
                return range
            }
            let segment = Kana2Kanji.normalizedComparisonSegment(
                prevTotal: prevTotal,
                word: word,
                fixedByteCount: fixedByteCount
            )
            let start = self.storage.count
            self.storage.append(contentsOf: segment)
            let range = start ..< self.storage.count
            self.splitRangeByKey[key] = range
            return range
        }

        /// 全体セグメント範囲の表に指定ノードが登録済みかを返す
        ///
        /// 表から引けないノードは生UTF-8バイト列の表からの引き当てへ進むため、表の保持を直接確かめられるようにする
        ///
        /// - Parameter node: 対象のラティスノード
        /// - Returns: 全体セグメント範囲を保持していればtrue
        internal func containsFullRangeNode(_ node: LatticeNode) -> Bool {
            self.fullRangeTable.range(for: node) != nil
        }

        /// 格納範囲に対応するセグメントのバイト列を返す
        ///
        /// - Parameter range: segmentRangeで取得した格納範囲
        /// - Returns: セグメントのバイト列
        func bytes(in range: Range<Int>) -> ArraySlice<UInt8> {
            self.storage[range]
        }
    }

    /// 制約と候補の一致バイト数と累積バイト数を計算する
    ///
    /// Zenz経路は生UTF-8のまま照合し、Jinen経路だけが比較用セグメントを使う
    ///
    /// Jinen経路のセグメントは呼び出し単位のキャッシュから取得し、同じノードと同じ境界の再計算を避ける
    ///
    /// - Parameters:
    ///   - prev: 直前の登録ノード
    ///   - currentWord: 現在ノードの辞書表記
    ///   - currentNode: 現在のラティスノード
    ///   - constraintBytes: 照合空間へ変換済みの実効制約バイト列
    ///   - normalizesUnfixedForJinen: JinenのNFKC照合が有効か
    ///   - fixedByteCount: 先頭の生UTF-8固定区間のバイト数
    ///   - segmentCache: 比較用セグメントの呼び出し単位キャッシュ
    /// - Returns: 一致バイト数と累積バイト数
    private func computeMatchedAndTotalLength(
        prev: borrowing RegisteredNode?,
        currentWord: borrowing String,
        currentNode: borrowing LatticeNode,
        constraintBytes: borrowing [UInt8],
        normalizesUnfixedForJinen: Bool,
        fixedByteCount: Int,
        segmentCache: inout JinenComparisonSegmentCache
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
        // 一致数が制約長へ達し累積も固定区間を越えた後は、後続バイトの比較で一致数は増えない
        // 一致判定と終端判定も変わらないため、セグメントを作らずに素通しする
        // 返す累積長はNFKC後の正確な長さではなく生UTF-8バイト数になる
        // 下流の判定は制約長と固定区間長との比較だけを行い、NFKCは空でない表記を空へ写さないため挙動は変わらない
        if matched >= constraintBytes.count, previousTotal >= max(fixedByteCount, constraintBytes.count) {
            return (matched, previousTotal + currentNode.data.word.utf8.count)
        }
        // [Hazkey Community Patch]
        // Jinenの未固定制約はNFKC空間で比較し、fixedPrefix区間だけは生UTF-8を維持する
        // セグメントは呼び出し単位のキャッシュから取得し、同じノードと同じ境界の再計算を避ける
        if let segmentRange = segmentCache.segmentRange(
            for: currentNode,
            prevTotal: previousTotal,
            fixedByteCount: fixedByteCount
        ) {
            let segment = segmentCache.bytes(in: segmentRange)
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
        // ノード全体がfixedPrefixの内側にある場合は生UTF-8を確保せずに直接照合する
        let rawBytes = currentNode.data.word.utf8
        let total = previousTotal + rawBytes.count
        guard matched == min(previousTotal, constraintBytes.count) else {
            return (matched, total)
        }
        for byte in rawBytes {
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

    /// 次のノードを加えたときの一致バイト数と加算バイト数を計算する
    ///
    /// Zenz経路は生UTF-8のまま照合し、Jinen経路だけが比較用セグメントを使う
    ///
    /// Jinen経路のセグメントは呼び出し単位のキャッシュから取得し、computeMatchedAndTotalLengthと同じ比較空間を共有する
    ///
    /// - Parameters:
    ///   - matched: 直前ノードまでの一致バイト数
    ///   - previousTotal: 直前ノードまでの比較空間における累積バイト数
    ///   - nextWord: 次ノードの辞書表記
    ///   - nextNode: 次のラティスノード
    ///   - constraintBytes: 照合空間へ変換済みの実効制約バイト列
    ///   - normalizesUnfixedForJinen: JinenのNFKC照合が有効か
    ///   - fixedByteCount: 先頭の生UTF-8固定区間のバイト数
    ///   - segmentCache: 比較用セグメントの呼び出し単位キャッシュ
    /// - Returns: 一致バイト数、不一致の有無、加算バイト数
    private func extendMatched(
        matched: Int,
        previousTotal: Int,
        nextWord: borrowing String,
        nextNode: borrowing LatticeNode,
        constraintBytes: borrowing [UInt8],
        normalizesUnfixedForJinen: Bool,
        fixedByteCount: Int,
        segmentCache: inout JinenComparisonSegmentCache
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
        // 一致数が制約長へ達し累積も固定区間を越えた後は、後続バイトの比較で一致数は増えず
        // 不一致にもならないため、セグメントを作らずに素通しする
        // 返す加算長はNFKC後の正確な長さではなく生UTF-8バイト数になる
        // 下流の判定は制約長と固定区間長との比較だけを行い、NFKCは空でない表記を空へ写さないため挙動は変わらない
        if matched >= constraintBytes.count, previousTotal >= max(fixedByteCount, constraintBytes.count) {
            return (matched, false, nextNode.data.word.utf8.count)
        }
        // [Hazkey Community Patch]
        // Jinen時はcomputeMatchedAndTotalLengthと同一の比較空間で一致と加算バイト数を算出する
        // セグメントは呼び出し単位のキャッシュから取得し、同じノードと同じ境界の再計算を避ける
        if let segmentRange = segmentCache.segmentRange(
            for: nextNode,
            prevTotal: previousTotal,
            fixedByteCount: fixedByteCount
        ) {
            let segment = segmentCache.bytes(in: segmentRange)
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
        // ノード全体がfixedPrefixの内側にある場合は生UTF-8を確保せずに直接照合する
        let rawBytes = nextNode.data.word.utf8
        let nextLength = rawBytes.count
        var ci = matched
        if ci >= constraintBytes.count {
            return (ci, false, nextLength)
        }
        for b in rawBytes {
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
        // Jinenの比較用セグメントはこの変換呼び出しの中だけで共有する
        // 同じノードと同じ境界の再計算を避けつつ、呼び出しをまたぐ状態を持たないため変換結果は変わらない
        var jinenSegmentCache = JinenComparisonSegmentCache()
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
                        currentNode: node,
                        constraintBytes: constraintBytes,
                        normalizesUnfixedForJinen: normalizesUnfixedForJinen,
                        fixedByteCount: fixedByteCount,
                        segmentCache: &jinenSegmentCache
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
                                nextNode: nextNode,
                                constraintBytes: constraintBytes,
                                normalizesUnfixedForJinen: normalizesUnfixedForJinen,
                                fixedByteCount: fixedByteCount,
                                segmentCache: &jinenSegmentCache
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
                                nextNode: nextNode,
                                constraintBytes: constraintBytes,
                                normalizesUnfixedForJinen: normalizesUnfixedForJinen,
                                fixedByteCount: fixedByteCount,
                                segmentCache: &jinenSegmentCache
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
                            currentNode: node,
                            constraintBytes: constraintBytes,
                            normalizesUnfixedForJinen: normalizesUnfixedForJinen,
                            fixedByteCount: fixedByteCount,
                            segmentCache: &jinenSegmentCache
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
                            currentNode: node,
                            constraintBytes: constraintBytes,
                            normalizesUnfixedForJinen: normalizesUnfixedForJinen,
                            fixedByteCount: fixedByteCount,
                            segmentCache: &jinenSegmentCache
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
                                    nextNode: nextnode,
                                    constraintBytes: constraintBytes,
                                    normalizesUnfixedForJinen: normalizesUnfixedForJinen,
                                    fixedByteCount: fixedByteCount,
                                    segmentCache: &jinenSegmentCache
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
                                    nextNode: nextnode,
                                    constraintBytes: constraintBytes,
                                    normalizesUnfixedForJinen: normalizesUnfixedForJinen,
                                    fixedByteCount: fixedByteCount,
                                    segmentCache: &jinenSegmentCache
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
