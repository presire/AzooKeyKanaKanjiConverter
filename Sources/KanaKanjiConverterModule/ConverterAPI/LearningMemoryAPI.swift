public import Foundation

/// 永続化済み学習メモリの1行です。
public struct LearningMemoryEntry: Sendable, Hashable {
    public let data: DicdataElement
    public let count: UInt8
    public let lastUsed: Date
    public let lastUpdated: Date

    public init(data: DicdataElement, count: UInt8, lastUsed: Date, lastUpdated: Date) {
        self.data = data
        self.count = count
        self.lastUsed = lastUsed
        self.lastUpdated = lastUpdated
    }
}

/// 永続化済み学習メモリのページです。
public struct LearningMemoryPage: Sendable {
    public let entries: [LearningMemoryEntry]
    public let totalCount: Int
    public let nextOffset: Int?

    public init(entries: [LearningMemoryEntry], totalCount: Int, nextOffset: Int?) {
        self.entries = entries
        self.totalCount = totalCount
        self.nextOffset = nextOffset
    }
}

/// 永続化済み学習メモリの1行を一意に識別するキーです。
///
/// 同じ (読み, 表記) でも接続ID (lcid/rcid) が異なる行は別エントリとして保存されるため、
/// 削除やアノテーションを同一の照会結果から導けるよう接続IDまで含めます。
public struct PersistedLearningMemoryKey: Sendable, Hashable {
    public let reading: String
    public let word: String
    public let lcid: Int
    public let rcid: Int

    public init(reading: String, word: String, lcid: Int, rcid: Int) {
        self.reading = reading
        self.word = word
        self.lcid = lcid
        self.rcid = rcid
    }
}

/// 学習メモリの列挙時に検出される永続化スナップショットのエラーです。
public enum LearningMemoryEnumerationError: Error, Equatable, Sendable {
    case pausedSnapshot
    case directoryMissing
    case memoryDirectoryUnavailable
    case invalidOffset
    case malformedMetadata
    case malformedShard
    case inconsistentSnapshot
}

struct LearningMemoryKey: Hashable, Sendable {
    let reading: String
    let word: String
    let lcid: Int
    let rcid: Int

    func matches(_ element: DicdataElement) -> Bool {
        element.ruby == reading
            && element.word == word
            && element.lcid == lcid
            && element.rcid == rcid
    }
}
