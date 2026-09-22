//
//  extension Data.swift
//  Keyboard
//
//  Created by ensan on 2020/09/30.
//  Copyright © 2020 ensan. All rights reserved.
//

package import Foundation
import SwiftUtils

extension LOUDS {
    // MARK: - Unaligned-safe little-endian readers
    @inline(__always)
    private static func byte(_ data: borrowing Data, _ offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }

    @inline(__always)
    private static func readUInt16LE(_ data: borrowing Data, _ offset: Int) -> UInt16 {
        let b0 = UInt16(byte(data, offset))
        let b1 = UInt16(byte(data, offset + 1))
        return b0 | (b1 << 8)
    }

    @inline(__always)
    private static func readUInt32LE(_ data: borrowing Data, _ offset: Int) -> UInt32 {
        let b0 = UInt32(byte(data, offset))
        let b1 = UInt32(byte(data, offset + 1))
        let b2 = UInt32(byte(data, offset + 2))
        let b3 = UInt32(byte(data, offset + 3))
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    @inline(__always)
    private static func readFloat32LE(_ data: borrowing Data, _ offset: Int) -> Float32 {
        Float32(bitPattern: readUInt32LE(data, offset))
    }
    private static func loadLOUDSBinary(from url: URL) -> [UInt64]? {
        do {
            let binaryData = try Data(contentsOf: url, options: [.uncached, .mappedIfSafe]) // 2度読み込むことはないのでキャッシュ不要
            return binaryData.toArray(of: UInt64.self)
        } catch {
            debug(error)
            return nil
        }
    }

    /// LOUDSをファイルから読み込む関数
    /// - Parameter identifier: ファイル名
    /// - Returns: 存在すればLOUDSデータを返し、存在しなければ`nil`を返す。
    package static func load(_ identifier: String, dictionaryURL: URL) -> LOUDS? {
        let (charsURL, loudsURL) = (
            dictionaryURL.appendingPathComponent("louds/\(identifier).loudschars2", isDirectory: false),
            dictionaryURL.appendingPathComponent("louds/\(identifier).louds", isDirectory: false)
        )
        return load(charsURL: charsURL, loudsURL: loudsURL)
    }

    package static func loadMemory(memoryURL: URL) -> LOUDS? {
        let (charsURL, loudsURL) = (
            memoryURL.appendingPathComponent("memory.loudschars2", isDirectory: false),
            memoryURL.appendingPathComponent("memory.louds", isDirectory: false)
        )
        return load(charsURL: charsURL, loudsURL: loudsURL)
    }

    package static func loadUserDictionary(userDictionaryURL: URL) -> LOUDS? {
        let (charsURL, loudsURL) = (
            userDictionaryURL.appending(path: "user.loudschars2", directoryHint: .notDirectory),
            userDictionaryURL.appending(path: "user.louds", directoryHint: .notDirectory)
        )
        return load(charsURL: charsURL, loudsURL: loudsURL)
    }

    package static func loadUserShortcuts(userDictionaryURL: URL) -> LOUDS? {
        let (charsURL, loudsURL) = (
            userDictionaryURL.appending(path: "user_shortcuts.loudschars2", directoryHint: .notDirectory),
            userDictionaryURL.appending(path: "user_shortcuts.louds", directoryHint: .notDirectory)
        )
        return load(charsURL: charsURL, loudsURL: loudsURL)
    }

    private static func load(charsURL: URL, loudsURL: URL) -> LOUDS? {
        let nodeIndex2ID: [UInt8]
        do {
            nodeIndex2ID = try Array(Data(contentsOf: charsURL, options: [.uncached]))   // 2度読み込むことはないのでキャッシュ不要
        } catch {
            debug("Error: \(loudsURL)に対するLOUDSファイルが存在しません。このエラーは無視できる可能性があります。 Description: \(error)")
            return nil
        }

        if let bytes = LOUDS.loadLOUDSBinary(from: loudsURL) {
            return LOUDS(bytes: bytes.map {$0.littleEndian}, nodeIndex2ID: nodeIndex2ID)
        }
        return nil
    }

    @inlinable
    static func parseBinary(binary: borrowing Data) -> [DicdataElement] {
        // Fast parse without intermediate toArray allocations
        // 破損・切り詰められたシャードでも読み出しをトラップさせず空で縮退する
        guard binary.count >= 2 else {
            return []
        }
        let count = Int(readUInt16LE(binary, 0))
        guard binary.count >= 2 + count * 10 else {
            return []
        }
        var offset = 2
        var dicdata: [DicdataElement] = []
        dicdata.reserveCapacity(count)
        if count > 0 {
            // Each entry: 2B*3 (UInt16) + 4B (Float32) = 10B
            for _ in 0 ..< count {
                let lcid = Int(readUInt16LE(binary, offset + 0))
                let rcid = Int(readUInt16LE(binary, offset + 2))
                let mid = Int(readUInt16LE(binary, offset + 4))
                let value = PValue(readFloat32LE(binary, offset + 6))
                dicdata.append(DicdataElement(word: "", ruby: "", lcid: lcid, rcid: rcid, mid: mid, value: value))
                offset += 10
            }
        }

        let strStart = binary.index(binary.startIndex, offsetBy: offset)
        var rangeStart = strStart
        var ruby: String = ""
        var i = dicdata.startIndex

        binary.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            let count = binary.count
            var offset = strStart + 1 - binary.startIndex
            while offset <= count {
                if offset == count || ptr[offset] == UInt8(ascii: "\t") {
                    // Compute numeric start relative to base
                    let startInt = rangeStart - binary.startIndex
                    let length = offset - startInt
                    let isFirstField = (rangeStart == strStart)
                    let isEmptyField = (length == 0)

                    if isFirstField {
                        let rb = UnsafeBufferPointer(start: ptr + startInt, count: length)
                        ruby = String(decoding: rb, as: UTF8.self)
                    } else if i >= dicdata.endIndex {
                        // 宣言件数より多くの表層フィールドを持つ破損データで添字超過を避ける
                        return
                    } else if isEmptyField {
                        withMutableValue(&dicdata[i]) {
                            $0.ruby = ruby
                            $0.word = ruby
                        }
                        i = dicdata.index(after: i)
                    } else {
                        let wb = UnsafeBufferPointer(start: ptr + startInt, count: length)
                        let word = String(decoding: wb, as: UTF8.self)
                        withMutableValue(&dicdata[i]) {
                            $0.ruby = ruby
                            $0.word = word
                        }
                        i = dicdata.index(after: i)
                    }
                    rangeStart = binary.startIndex + offset + 1
                    offset += 1
                } else {
                    offset += 1
                }
            }
        }
        return dicdata
    }

    static func getUserDictionaryDataForLoudstxt3(_ identifier: String, indices: [Int], cache: Data? = nil, userDictionaryURL: URL) -> [DicdataElement] {
        if let cache {
            return Self.parseLoudstxt3Binary(binary: cache, indices: indices)
        }
        do {
            let url = userDictionaryURL.appendingPathComponent("\(identifier).loudstxt3", isDirectory: false)
            return Self.parseLoudstxt3Binary(binary: try Data(contentsOf: url), indices: indices)
        } catch {
            debug(#function, error)
            return []
        }
    }

    static func getUserShortcutsDataForLoudstxt3(_ identifier: String, indices: [Int], cache: Data? = nil, userDictionaryURL: URL) -> [DicdataElement] {
        if let cache {
            return Self.parseLoudstxt3Binary(binary: cache, indices: indices)
        }
        do {
            let url = userDictionaryURL.appendingPathComponent("\(identifier).loudstxt3", isDirectory: false)
            return Self.parseLoudstxt3Binary(binary: try Data(contentsOf: url), indices: indices)
        } catch {
            debug(#function, error)
            return []
        }
    }

    static func getMemoryDataForLoudstxt3(_ identifier: String, indices: [Int], cache: Data? = nil, memoryURL: URL) -> [DicdataElement] {
        if let cache {
            return Self.parseLoudstxt3Binary(binary: cache, indices: indices)
        }
        do {
            let url = memoryURL.appendingPathComponent("\(identifier).loudstxt3", isDirectory: false)
            return Self.parseLoudstxt3Binary(binary: try Data(contentsOf: url), indices: indices)
        } catch {
            debug(#function, error)
            return []
        }
    }

    static func getDataForLoudstxt3(_ identifier: String, indices: [Int], cache: Data? = nil, dictionaryURL: URL) -> [DicdataElement] {
        if let cache {
            return Self.parseLoudstxt3Binary(binary: cache, indices: indices)
        }
        do {
            let url = dictionaryURL.appendingPathComponent("louds/\(identifier).loudstxt3", isDirectory: false)
            return Self.parseLoudstxt3Binary(binary: try Data(contentsOf: url, options: [.mappedIfSafe]), indices: indices)
        } catch {
            debug(#function, error)
            return []
        }
    }

    /// 学習メモリのシャードから、指定したローカルインデックスの行だけを厳密に読み出す。
    ///
    /// `parseLoudstxt3Binary` と違い全オフセットを使用前に検証し、壊れたシャードでは
    /// 配列境界でトラップせず `malformedShard` を throw する。永続化済み学習エントリの
    /// 同定に必要なフィールドのみを復号する。
    static func parsePersistedMemoryRows(
        binary: borrowing Data,
        localIndices: [Int]
    ) throws -> [(ruby: String, word: String, lcid: Int, rcid: Int)] {
        let total = binary.count
        guard total >= MemoryLayout<UInt16>.size else {
            throw LearningMemoryEnumerationError.malformedShard
        }
        let entryCount = Int(readUInt16LE(binary, 0))
        let headerEnd = MemoryLayout<UInt16>.size + entryCount * MemoryLayout<UInt32>.size
        guard headerEnd <= total else {
            throw LearningMemoryEnumerationError.malformedShard
        }
        var rows: [(ruby: String, word: String, lcid: Int, rcid: Int)] = []
        for index in localIndices {
            guard (0 ..< entryCount).contains(index) else {
                throw LearningMemoryEnumerationError.malformedShard
            }
            let start = Int(readUInt32LE(binary, MemoryLayout<UInt16>.size + index * MemoryLayout<UInt32>.size))
            let end = index == entryCount - 1
                ? total
                : Int(readUInt32LE(binary, MemoryLayout<UInt16>.size + (index + 1) * MemoryLayout<UInt32>.size))
            guard headerEnd <= start, start <= end, end <= total else {
                throw LearningMemoryEnumerationError.malformedShard
            }
            rows.append(contentsOf: try parsePersistedMemoryEntry(binary: binary, range: start ..< end))
        }
        return rows
    }

    private static func parsePersistedMemoryEntry(
        binary: borrowing Data,
        range: Range<Int>
    ) throws -> [(ruby: String, word: String, lcid: Int, rcid: Int)] {
        guard range.count >= MemoryLayout<UInt16>.size else {
            throw LearningMemoryEnumerationError.malformedShard
        }
        let rowCount = Int(readUInt16LE(binary, range.lowerBound))
        // 1行あたり lcid/rcid/mid (UInt16 x3) + score (Float32) の10バイト
        let numericBytes = rowCount * 10
        let textStart = range.lowerBound + MemoryLayout<UInt16>.size + numericBytes
        guard textStart <= range.upperBound else {
            throw LearningMemoryEnumerationError.malformedShard
        }
        guard rowCount > 0 else {
            return []
        }
        var cids: [(lcid: Int, rcid: Int)] = []
        cids.reserveCapacity(rowCount)
        for row in 0 ..< rowCount {
            let base = range.lowerBound + MemoryLayout<UInt16>.size + row * 10
            cids.append((Int(readUInt16LE(binary, base)), Int(readUInt16LE(binary, base + 2))))
        }
        let textRange = binary.index(binary.startIndex, offsetBy: textStart)
            ..< binary.index(binary.startIndex, offsetBy: range.upperBound)
        let fields = String(decoding: binary[textRange], as: UTF8.self)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == rowCount + 1 else {
            throw LearningMemoryEnumerationError.malformedShard
        }
        let ruby = String(fields[0])
        return zip(cids, fields.dropFirst()).map { cid, field in
            (ruby: ruby, word: field.isEmpty ? ruby : String(field), lcid: cid.lcid, rcid: cid.rcid)
        }
    }

    private static func parseLoudstxt3Binary(binary: borrowing Data, indices: [Int]) -> [DicdataElement] {
        // 破損・切り詰められたシャードでも読み出しをトラップさせず空で縮退する
        guard binary.count >= 2 else {
            return []
        }
        let lc: Int = Int(readUInt16LE(binary, 0))
        // Header table of UInt32 offsets starts at byte 2
        let payloadStart = 2 + lc * 4
        guard lc > 0, binary.count >= payloadStart else {
            return []
        }
        var out: [DicdataElement] = []
        out.reserveCapacity(indices.count * 2) // rough guess
        for idx in indices {
            guard idx >= 0, idx < lc else {
                continue
            }
            let start = Int(readUInt32LE(binary, 2 + idx * 4))
            let end: Int = if idx == (lc - 1) {
                binary.endIndex
            } else {
                Int(readUInt32LE(binary, 2 + (idx + 1) * 4))
            }
            guard start >= payloadStart, start <= end, end <= binary.endIndex else {
                continue
            }
            out.append(contentsOf: parseBinary(binary: binary[start ..< end]))
        }
        return out
    }
}
