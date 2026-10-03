public import Foundation

/// 永続化済み学習メモリの1行
public struct LearningMemoryEntry: Sendable, Hashable {
    /// 学習した語の辞書要素
    public let data: DicdataElement
    /// 学習回数
    public let count: UInt8
    /// 最終使用日時
    public let lastUsed: Date
    /// 最終更新日時
    public let lastUpdated: Date

    /// 永続化済み学習メモリの1行を作る
    ///
    /// - Parameters:
    ///   - data: 学習した語の辞書要素
    ///   - count: 学習回数
    ///   - lastUsed: 最終使用日時
    ///   - lastUpdated: 最終更新日時
    public init(data: DicdataElement, count: UInt8, lastUsed: Date, lastUpdated: Date) {
        self.data = data
        self.count = count
        self.lastUsed = lastUsed
        self.lastUpdated = lastUpdated
    }
}

/// 永続化済み学習メモリのページ
public struct LearningMemoryPage: Sendable {
    /// 取得したエントリの一覧
    public let entries: [LearningMemoryEntry]
    /// 全体の件数
    public let totalCount: Int
    /// 次のページの開始位置 (最終ページの場合はnil)
    public let nextOffset: Int?

    /// 永続化済み学習メモリのページを作る
    ///
    /// - Parameters:
    ///   - entries: 取得したエントリの一覧
    ///   - totalCount: 全体の件数
    ///   - nextOffset: 次のページの開始位置 (最終ページの場合はnil)
    public init(entries: [LearningMemoryEntry], totalCount: Int, nextOffset: Int?) {
        self.entries = entries
        self.totalCount = totalCount
        self.nextOffset = nextOffset
    }
}

/// 永続化済み学習メモリの1行を一意に識別するキー
///
/// 同じ (読み,表記) でも接続ID (lcid/rcid) が異なる行は別エントリとして保存されるため、
/// 削除やアノテーションを同一の照会結果から導けるよう接続IDまで含める
public struct PersistedLearningMemoryKey: Sendable, Hashable {
    /// エントリの読み
    public let reading: String
    /// エントリの表記
    public let word: String
    /// 左接続ID
    public let lcid: Int
    /// 右接続ID
    public let rcid: Int

    /// 永続化済み学習メモリの1行を一意に識別するキーを作る
    ///
    /// - Parameters:
    ///   - reading: エントリの読み
    ///   - word: エントリの表記
    ///   - lcid: 左接続ID
    ///   - rcid: 右接続ID
    public init(reading: String, word: String, lcid: Int, rcid: Int) {
        self.reading = reading
        self.word = word
        self.lcid = lcid
        self.rcid = rcid
    }
}

/// 学習メモリの列挙時に検出される永続化スナップショットのエラー
public enum LearningMemoryEnumerationError: Error, Equatable, Sendable {
    /// 学習が一時停止中のため列挙と照会を拒否する
    case pausedSnapshot
    /// 学習メモリのディレクトリが存在しない
    case directoryMissing
    /// 学習メモリの保存先が設定されていない
    case memoryDirectoryUnavailable
    /// 取得開始位置が負である
    case invalidOffset
    /// メタデータのバイナリが壊れている
    case malformedMetadata
    /// シャードのファイルが欠落または切り詰められている
    case malformedShard
    /// データ件数とメタデータ件数が一致しない
    case inconsistentSnapshot
}

/// 一時記憶と永続化済み学習メモリの共通キー
struct LearningMemoryKey: Hashable, Sendable {
    /// エントリの読み
    let reading: String
    /// エントリの表記
    let word: String
    /// 左接続ID
    let lcid: Int
    /// 右接続ID
    let rcid: Int

    /// 指定した辞書要素と読みと表記と接続IDが全て一致するかどうかを示す
    ///
    /// - Parameter element: 照合対象の辞書要素
    /// - Returns: 全て一致する場合のみtrue
    func matches(_ element: DicdataElement) -> Bool {
        element.ruby == reading
            && element.word == word
            && element.lcid == lcid
            && element.rcid == rcid
    }
}
