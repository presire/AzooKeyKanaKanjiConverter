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
