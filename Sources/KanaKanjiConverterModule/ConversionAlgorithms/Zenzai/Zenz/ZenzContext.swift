#if Zenzai || ZenzaiCPU
// Zenzai/ZenzaiCPU が有効でない場合、llama-mock.swift の実装が利用される
import llama
#endif
#if canImport(Darwin)
import Darwin
#endif

import Algorithms
import Foundation
import Synchronization
import SwiftUtils

// [hazkey-community patch] zenzai inference timer (ZenzInferencePerf)
public final class ZenzInferencePerf: @unchecked Sendable {
    public static let shared = ZenzInferencePerf()

    private let lock = NSLock()
    private var elapsedNanoseconds: UInt64 = 0
    public let enabled: Bool

    // [hazkey-community patch] opt-in Zenzai CPU latency deadline (HAZKEY_ZENZAI_DEADLINE_MS).
    // Reuses this class's single monotonic clock source (DispatchTime.now().uptimeNanoseconds)
    // instead of introducing a second, independent timer. Unlike `elapsedNanoseconds` (an
    // accumulator gated by `enabled`, consumed once per evidence report), the deadline tracks
    // elapsed wall-clock time since the most recent `beginDeadlineWindow()` call and is always
    // active when a valid deadline is configured, independent of the `HAZKEY_PERF_EVIDENCE` flag.
    public let deadlineNanoseconds: UInt64?
    private var deadlineWindowStart: UInt64?

    private init() {
        let perfEvidence = ProcessInfo.processInfo.environment["HAZKEY_PERF_EVIDENCE"]
        self.enabled = perfEvidence?.isEmpty == false
        self.deadlineNanoseconds = Self.parseDeadlineMilliseconds(
            ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_DEADLINE_MS"]
        )
    }

    private static func parseDeadlineMilliseconds(_ raw: String?) -> UInt64? {
        // 未設定・0・範囲外・非数値は全て「デッドライン無効」として扱う（トラップしない）。
        guard let raw, let value = Int(raw), value >= 1, value <= 2_000 else {
            return nil
        }
        return UInt64(value) * 1_000_000
    }

    func record(_ nanoseconds: UInt64) {
        guard enabled else { return }
        lock.lock()
        elapsedNanoseconds &+= nanoseconds
        lock.unlock()
    }

    public func consumeElapsedNanoseconds() -> UInt64 {
        guard enabled else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        let elapsed = elapsedNanoseconds
        elapsedNanoseconds = 0
        return elapsed
    }

    /// デッドライン監視ウィンドウを開始する（`HAZKEY_ZENZAI_DEADLINE_MS` 未設定時は no-op）。
    /// Zenzai推論を行う独立したエントリポイント（`all_zenzai`、`ZenzPureGreedyDecoder.decode`、
    /// `ZenzInputTextGenerator.generate`）それぞれの先頭で呼び出す想定。
    public func beginDeadlineWindow() {
        guard deadlineNanoseconds != nil else { return }
        lock.lock()
        deadlineWindowStart = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    /// 現在のデッドラインウィンドウが期限切れかどうかを返す。デッドライン未設定、または
    /// ウィンドウ未開始の場合は常に false（既存の動作を変えない）。
    public func deadlineExpired() -> Bool {
        guard let deadlineNanoseconds else { return false }
        lock.lock()
        let start = deadlineWindowStart
        lock.unlock()
        guard let start else { return false }
        return DispatchTime.now().uptimeNanoseconds &- start >= deadlineNanoseconds
    }
}

public typealias ZenzaiDeviceConfig = ConvertRequestOptions.ZenzaiMode.DeviceConfig

public struct GGMLBackendDevice: Sendable {
    public let name: String
    public let description: String
    public let type: DeviceType

    public enum DeviceType: Sendable {
        case cpu
        case gpu
        case accel
        case unknown
    }

    #if Zenzai
    init(device: ggml_backend_dev_t) {
        if let namePtr = ggml_backend_dev_name(device) {
            self.name = String(cString: namePtr)
        } else {
            self.name = "Unknown"
        }

        if let descPtr = ggml_backend_dev_description(device) {
            self.description = String(cString: descPtr)
        } else {
            self.description = "Unknown"
        }

        switch ggml_backend_dev_type(device) {
        case GGML_BACKEND_DEVICE_TYPE_CPU:
            self.type = .cpu
        case GGML_BACKEND_DEVICE_TYPE_GPU:
            self.type = .gpu
        case GGML_BACKEND_DEVICE_TYPE_ACCEL:
            self.type = .accel
        default:
            self.type = .unknown
        }
    }
    #endif
}

/// Enumerate available GGML backend devices.
/// Call `loadGGMLBackends()` once before using this function.
public func enumerateGGMLBackendDevices() -> [GGMLBackendDevice] {
    #if Zenzai
    let deviceCount = ggml_backend_dev_count()
    var devices: [GGMLBackendDevice] = []
    for i in 0..<deviceCount {
        if let device = ggml_backend_dev_get(i) {
            devices.append(GGMLBackendDevice(device: device))
        }
    }
    return devices
    #else
    return []
    #endif
}

/// Load all available GGML backends.
/// - Parameter path: An optional directory from which to load backends.
public func loadGGMLBackends(from path: String? = nil) {
    #if Zenzai
    if let path {
        ggml_backend_load_all_from_path(path)
    } else {
        ggml_backend_load_all()
    }
    #endif
}

/// Create a device configuration with `createDeviceConfig` based on available backend devices.
public func createDeviceConfig(
    deviceName: String? = nil,
    gpuLayers: Int32 = 99
) -> ZenzaiDeviceConfig {
    #if Zenzai
    let devices = enumerateGGMLBackendDevices()

    if let targetName = deviceName,
       let device = devices.first(where: { $0.name == targetName }) {
        switch device.type {
        case .gpu:
            return ZenzaiDeviceConfig(deviceName: targetName, gpuLayers: gpuLayers)
        case .cpu, .accel, .unknown:
            return ZenzaiDeviceConfig(deviceName: targetName, gpuLayers: 0)
        }
    }

    if let cpuDevice = devices.first(where: { $0.type == .cpu }) {
        return ZenzaiDeviceConfig(deviceName: cpuDevice.name, gpuLayers: 0)
    }

    return ZenzaiDeviceConfig(deviceName: nil, gpuLayers: 0)
    #else
    return ZenzaiDeviceConfig(deviceName: nil, gpuLayers: 0)
    #endif
}

enum ZenzError: LocalizedError {
    case couldNotLoadModel(path: String)
    case couldNotLoadContext
    case couldNotLoadVocab

    var errorDescription: String? {
        switch self {
        case .couldNotLoadContext: return "failed to load context"
        case .couldNotLoadModel(path: let path): return "could not load model weight at \(path)"
        case .couldNotLoadVocab: return "failed to load vocab"
        }
    }
}

/// llama.cpp のバックエンドはプロセス単位で一度だけ初期化する。
///
/// `llama_backend_free()` は現在 MPI 用の後始末にしか使われないため、モデルや
/// コンテキストより先に解放される可能性があるプロセス終了時の明示解放は行わない。
private enum ZenzBackend {
    private static let initialized: Void = {
        // Mitigate SIGILL crash on multi-GPU Linux systems where multiple
        // Vulkan ICDs (e.g. nvidia_icd.json + radeon_icd.json) coexist.
        // Ref: https://github.com/7ka-Hiira/hazkey/issues/29
        // Pin to a single ICD *before* ggml_backend_load_all() runs, because
        // once the Vulkan loader creates a VkInstance it initializes every
        // available ICD and the resulting vendor-mixed state triggers a Swift
        // runtime precondition failure (ud2 -> SIGILL) that cannot be caught
        // by Swift do/catch.
        Self.pinVulkanICDIfNeeded()

        llama_backend_init()
    }()

    static func initializeIfNeeded() {
        _ = self.initialized
    }

    /// Detect Vulkan ICDs in standard search paths and, when more than one is
    /// installed, restrict the Vulkan loader to the first detected ICD by
    /// exporting `VK_DRIVER_FILES` / `VK_ICD_FILENAMES`.
    ///
    /// This is a workaround for https://github.com/7ka-Hiira/hazkey/issues/29
    /// where multi-GPU systems (e.g. NVIDIA dGPU + AMD/Intel iGPU) with both
    /// `nvidia_icd.json` and `radeon_icd.json` installed crash hazkey-server
    /// with SIGILL during Zenzai / Vulkan initialization.
    ///
    /// User-provided values for `VK_DRIVER_FILES` / `VK_ICD_FILENAMES` (set
    /// via shell, systemd unit, or `~/.config/hazkey/env`) are always respected
    /// and never overridden.
    ///
    /// Notes:
    /// - Only intervenes when 2+ ICDs are detected; single-ICD systems are
    ///   not affected by Issue #29 and are left untouched.
    /// - Must be called *before* any ggml backend / Vulkan API call.
    private static func pinVulkanICDIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        if env["VK_DRIVER_FILES"] != nil { return }
        if env["VK_ICD_FILENAMES"] != nil { return }

        var icdSearchPaths = [
            "/usr/share/vulkan/icd.d",
            "/usr/local/share/vulkan/icd.d",
            "/etc/vulkan/icd.d",
        ]
        // Honor XDG_DATA_DIRS when set (typical on Arch / Fedora / Debian).
        if let xdg = env["XDG_DATA_DIRS"] {
            for entry in xdg.split(separator: ":") {
                icdSearchPaths.append("\(entry)/vulkan/icd.d")
            }
        }

        let fm = FileManager.default
        var foundICDs: [String] = []
        for searchPath in icdSearchPaths {
            guard let candidates = try? fm.contentsOfDirectory(atPath: searchPath) else { continue }
            for candidate in candidates where candidate.hasSuffix(".json") {
                foundICDs.append("\(searchPath)/\(candidate)")
            }
        }

        // Only intervene when more than one ICD is present; single-ICD
        // systems are not affected by Issue #29.
        guard foundICDs.count > 1 else { return }

        let pinned = foundICDs[0]
        debug("[Vulkan ICD] Multi-ICD environment detected: \(foundICDs). Pinning to \(pinned) to avoid SIGILL (Issue #29).")
        setenv("VK_DRIVER_FILES", pinned, 1)
        setenv("VK_ICD_FILENAMES", pinned, 1)
    }
}

private final class ZenzTokenArrayBox {
    init(_ tokens: [llama_token]) {
        self.tokens = tokens
    }

    let tokens: [llama_token]
}

struct ZenzResolvedConversionCacheKey: Equatable, Hashable {
    var input: [ComposingText.InputElement]
    var convertTarget: String
    var convertTargetCursorPosition: Int?
    var keyboardLanguage: KeyboardLanguage
    var versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    var prefixConstraint: Kana2Kanji.PrefixConstraint
    var inferenceLimit: Int
}

struct ZenzDraftConversionCacheKey: Equatable, Hashable {
    var input: [ComposingText.InputElement]
    var convertTarget: String
    var convertTargetCursorPosition: Int?
    var keyboardLanguage: KeyboardLanguage
    var versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    var prefixConstraint: Kana2Kanji.PrefixConstraint
}

struct ZenzDraftConversion {
    var resultPrevs: [RegisteredNode]
    var resultLatticeHead: ZenzResolvedLatticeHead
}

struct ZenzResolvedConversion {
    var resultPrevs: [RegisteredNode]
    var resultLatticeHead: ZenzResolvedLatticeHead
    var prefixConstraint: Kana2Kanji.PrefixConstraint
    var satisfyingCandidate: Candidate
}

struct ZenzResolvedLatticeNode: Hashable {
    var data: DicdataElement
    var range: Lattice.LatticeRange
}

final class ZenzResolvedLatticeHead: @unchecked Sendable {
    init(nodes: [ZenzResolvedLatticeNode]) {
        self.nodes = nodes
        self.fingerprint = nodes.hashValue
    }

    let nodes: [ZenzResolvedLatticeNode]
    let fingerprint: Int
}

private final class ZenzResolvedConversionCache: @unchecked Sendable {
    private struct Entry {
        var value: ZenzResolvedConversion
        var accessIndex: UInt64
    }

    init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for key: ZenzResolvedConversionCacheKey) -> ZenzResolvedConversion? {
        self.lock.withLock {
            guard var entry = self.entries[key] else {
                return nil
            }
            self.accessIndex &+= 1
            entry.accessIndex = self.accessIndex
            self.entries[key] = entry
            return entry.value
        }
    }

    func insert(_ value: ZenzResolvedConversion, for key: ZenzResolvedConversionCacheKey) {
        var value = value
        self.lock.withLock {
            // 逐次入力では最大辞書長を超えた後の先頭候補が同一になる。
            // 不変配列を既存entryと共有し、prefixごとの重複保持を避ける。
            if let sharedHead = self.entries.values.lazy.map({
                $0.value.resultLatticeHead
            }).first(where: {
                $0.fingerprint == value.resultLatticeHead.fingerprint
                    && $0.nodes == value.resultLatticeHead.nodes
            }) {
                value.resultLatticeHead = sharedHead
            }
            self.accessIndex &+= 1
            self.entries[key] = Entry(value: value, accessIndex: self.accessIndex)
            if self.entries.count > self.capacity,
               let oldestKey = self.entries.min(by: {
                   $0.value.accessIndex < $1.value.accessIndex
               })?.key {
                self.entries.removeValue(forKey: oldestKey)
            }
        }
    }

    private let capacity: Int
    private var entries: [ZenzResolvedConversionCacheKey: Entry] = [:]
    private var accessIndex: UInt64 = 0
    private let lock = NSLock()
}

/// 同じ辞書状態・入力・制約から得た不変のdraft経路を共有するLRU cache。
/// 可変な探索状態を含むlattice本体は保持しない。
final class ZenzDraftConversionCache: @unchecked Sendable {
    private struct Entry {
        var value: ZenzDraftConversion
        var accessIndex: UInt64
    }

    init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for key: ZenzDraftConversionCacheKey) -> ZenzDraftConversion? {
        self.lock.withLock {
            guard var entry = self.entries[key] else { return nil }
            self.accessIndex &+= 1
            entry.accessIndex = self.accessIndex
            self.entries[key] = entry
            return entry.value
        }
    }

    func insert(_ value: ZenzDraftConversion, for key: ZenzDraftConversionCacheKey) {
        var value = value
        self.lock.withLock {
            if let sharedHead = self.entries.values.lazy.map({
                $0.value.resultLatticeHead
            }).first(where: {
                $0.fingerprint == value.resultLatticeHead.fingerprint
                    && $0.nodes == value.resultLatticeHead.nodes
            }) {
                value.resultLatticeHead = sharedHead
            }
            self.accessIndex &+= 1
            self.entries[key] = Entry(value: value, accessIndex: self.accessIndex)
            if self.entries.count > self.capacity,
               let oldestKey = self.entries.min(by: {
                   $0.value.accessIndex < $1.value.accessIndex
               })?.key {
                self.entries.removeValue(forKey: oldestKey)
            }
        }
    }

    private let capacity: Int
    private var entries: [ZenzDraftConversionCacheKey: Entry] = [:]
    private var accessIndex: UInt64 = 0
    private let lock = NSLock()
}

/// 1つの`KanaKanjiConverter`内で再利用するZenzaiのメモ化キャッシュ。
///
/// モデルやnative contextとは所有者を分け、別Converter間では共有しない。一方、
/// `stopComposition()`は入力中の状態だけを終了するAPIなので、このキャッシュは
/// compositionを跨いで保持する。
final class ZenzaiMemoizationCache: @unchecked Sendable {
    init(
        evaluationCapacity: Int = 256,
        resolvedConversionCapacity: Int = 64,
        draftConversionCapacity: Int = 128,
        promptTokenCapacity: Int = 128
    ) {
        self.evaluationCache = ZenzEvaluationCache(capacity: evaluationCapacity)
        self.resolvedConversionCache = ZenzResolvedConversionCache(
            capacity: resolvedConversionCapacity
        )
        self.draftConversionCache = ZenzDraftConversionCache(
            capacity: draftConversionCapacity
        )
        self.evaluationPromptTokenCache.countLimit = promptTokenCapacity
    }

    func cachedEvaluation(for key: ZenzEvaluationCacheKey) -> CandidateEvaluationResult? {
        self.evaluationCache.value(for: key)
    }

    func cacheEvaluation(_ result: CandidateEvaluationResult, for key: ZenzEvaluationCacheKey) {
        self.evaluationCache.insert(result, for: key)
    }

    func cachedResolvedConversion(
        for key: ZenzResolvedConversionCacheKey
    ) -> ZenzResolvedConversion? {
        self.resolvedConversionCache.value(for: key)
    }

    func cacheResolvedConversion(
        _ value: ZenzResolvedConversion,
        for key: ZenzResolvedConversionCacheKey
    ) {
        self.resolvedConversionCache.insert(value, for: key)
    }

    func cachedDraftConversion(for key: ZenzDraftConversionCacheKey) -> ZenzDraftConversion? {
        self.draftConversionCache.value(for: key)
    }

    func cacheDraftConversion(
        _ value: ZenzDraftConversion,
        for key: ZenzDraftConversionCacheKey
    ) {
        self.draftConversionCache.insert(value, for: key)
    }

    func cachedEvaluationPromptTokens(for prompt: String) -> [llama_token]? {
        self.evaluationPromptTokenCache.object(forKey: prompt as NSString)?.tokens
    }

    func cacheEvaluationPromptTokens(_ tokens: [llama_token], for prompt: String) {
        self.evaluationPromptTokenCache.setObject(
            ZenzTokenArrayBox(tokens),
            forKey: prompt as NSString
        )
    }

    private let evaluationCache: ZenzEvaluationCache
    private let resolvedConversionCache: ZenzResolvedConversionCache
    private let draftConversionCache: ZenzDraftConversionCache
    private let evaluationPromptTokenCache = NSCache<NSString, ZenzTokenArrayBox>()
}

/// 読み取り専用のGGUFモデルを複数の推論コンテキスト間で共有する。
///
/// KV cacheなどの可変状態は`ZenzContext`側に残し、モデルの重みとvocabularyだけを
/// 共有することで、同じモデルを利用するConverterごとの再ロードを避ける。
private final class SharedZenzModel {
    init(path: String, deviceConfig: ZenzaiDeviceConfig) throws {
        ZenzBackend.initializeIfNeeded()
        var modelParams = llama_model_default_params()
        #if Zenzai
        modelParams.n_gpu_layers = deviceConfig.gpuLayers
        let loadedModel: OpaquePointer?
        if let deviceName = deviceConfig.deviceName,
           let device = ggml_backend_dev_by_name(deviceName) {
            var devices = [device, nil]
            loadedModel = devices.withUnsafeMutableBufferPointer { buffer in
                modelParams.devices = buffer.baseAddress
                return llama_model_load_from_file(path, modelParams)
            }
        } else {
            loadedModel = llama_model_load_from_file(path, modelParams)
        }
        #elseif ZenzaiCPU
        modelParams.n_gpu_layers = 0
        modelParams.split_mode = LLAMA_SPLIT_MODE_NONE
        guard let cpuDevice = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU) else {
            debug("Could not find CPU backend")
            throw ZenzError.couldNotLoadModel(path: path)
        }
        // NULL終端のCPU-onlyデバイスリストを渡す。`n_gpu_layers = 0`だけでは
        // llama.cppがMetalデバイスも列挙し、context生成時に初期化してしまう。
        var devices = [cpuDevice, nil]
        let loadedModel = devices.withUnsafeMutableBufferPointer { buffer in
            modelParams.devices = buffer.baseAddress
            return llama_model_load_from_file(path, modelParams)
        }
        #else
        let loadedModel = llama_model_load_from_file(path, modelParams)
        #endif
        guard let model = loadedModel else {
            debug("Could not load model at \(path)")
            throw ZenzError.couldNotLoadModel(path: path)
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_model_free(model)
            debug("Could not load vocab!")
            throw ZenzError.couldNotLoadVocab
        }
        self.model = model
        self.vocab = vocab
    }

    deinit {
        llama_model_free(self.model)
    }

    let model: OpaquePointer
    let vocab: OpaquePointer
}

/// 同時に強参照するモデルを1個に制限する、プロセス共通のモデルキャッシュ。
///
/// `NSCache`にすることでメモリプレッシャー時にはモデルを解放できる。呼び出し側の
/// `ZenzContext`もモデルを強参照するため、使用中のモデルが解放されることはない。
private final class SharedZenzModelCache: @unchecked Sendable {
    static let shared = SharedZenzModelCache()

    private init() {
        self.cache.countLimit = 1
    }

    func model(path: String, deviceConfig: ZenzaiDeviceConfig) throws -> SharedZenzModel {
        try self.lock.withLock {
            let key = path as NSString
            if let cached = self.cache.object(forKey: key) {
                return cached
            }
            let model = try SharedZenzModel(path: path, deviceConfig: deviceConfig)
            self.cache.setObject(model, forKey: key)
            return model
        }
    }

    private let cache = NSCache<NSString, SharedZenzModel>()
    private let lock = NSLock()
}

final class ZenzContext {
    #if Zenzai || ZenzaiCPU
    private struct CPUThreadPoolState: Sendable {
        private var threadPool: OpaquePointer?
        private var threadCount: Int32?
        private var leaseCount = 0
    }

    private final class CPUThreadPoolStore: Sendable {
        private let state = Mutex(CPUThreadPoolState())

        func acquire(threadCount: Int32) -> OpaquePointer? {
            state.withLock { state in
                if let threadPool = state.threadPool {
                    guard state.threadCount == threadCount else {
                        return nil
                    }
                    state.leaseCount += 1
                    return threadPool
                }

                guard let threadPool = llama_cpu_threadpool_create(threadCount) else {
                    return nil
                }

                state.threadPool = threadPool
                state.threadCount = threadCount
                state.leaseCount = 1
                NSLog("ZenzContext CPU ggml threadpool created (threads: \(threadCount))")
                return threadPool
            }
        }

        func release(_ threadPool: OpaquePointer) {
            state.withLock { state in
                guard state.threadPool == threadPool, state.leaseCount > 0 else {
                    return
                }

                state.leaseCount -= 1
                guard state.leaseCount == 0 else {
                    return
                }

                state.threadPool = nil
                state.threadCount = nil
                llama_cpu_threadpool_free(threadPool)
                NSLog("ZenzContext CPU ggml threadpool released")
            }
        }
    }

    private static let cpuThreadPoolStore = CPUThreadPoolStore()
    #endif

    private let sharedModel: SharedZenzModel
    private var context: OpaquePointer
    private var batch: llama_batch
    private var prevInputBySeq: [llama_seq_id: [llama_token]] = [:]
    private var prevPromptBySeq: [llama_seq_id: String] = [:]
    private var currentDeviceConfig: ZenzaiDeviceConfig
    private let cpuThreadPool: OpaquePointer?
    private let cpuThreadPoolThreadCount: Int32?

    private let n_len: Int32 = 512
    private let evalSeqId: llama_seq_id = 0
    private let inputPredictionSeqId: llama_seq_id = 1

    private init(
        sharedModel: SharedZenzModel,
        context: OpaquePointer,
        deviceConfig: ZenzaiDeviceConfig,
        cpuThreadPool: OpaquePointer?,
        cpuThreadPoolThreadCount: Int32?
    ) {
        self.sharedModel = sharedModel
        self.context = context
        self.batch = llama_batch_init(512, 0, 1)
        self.currentDeviceConfig = deviceConfig
        self.cpuThreadPool = cpuThreadPool
        self.cpuThreadPoolThreadCount = cpuThreadPoolThreadCount
    }

    deinit {
        Self.detachCPUThreadPool(self.cpuThreadPool, from: self.context)
        llama_batch_free(self.batch)
        llama_free(context)
        Self.releaseCPUThreadPool(self.cpuThreadPool)
    }

    private static func acquireCPUThreadPool(
        deviceConfig: ZenzaiDeviceConfig,
        threadCount: Int32
    ) -> OpaquePointer? {
        #if Zenzai || ZenzaiCPU
        guard deviceConfig.gpuLayers == 0 else {
            return nil
        }
        return cpuThreadPoolStore.acquire(threadCount: threadCount)
        #else
        return nil
        #endif
    }

    private static func attachCPUThreadPool(
        _ threadPool: OpaquePointer?,
        poolThreadCount: Int32?,
        contextThreadCount: Int32,
        to context: OpaquePointer
    ) {
        #if Zenzai || ZenzaiCPU
        guard let threadPool, let poolThreadCount, poolThreadCount == contextThreadCount else {
            return
        }
        llama_attach_threadpool(context, threadPool, threadPool)
        #endif
    }

    private static func detachCPUThreadPool(_ threadPool: OpaquePointer?, from context: OpaquePointer) {
        #if Zenzai || ZenzaiCPU
        guard threadPool != nil else {
            return
        }
        llama_detach_threadpool(context)
        #endif
    }

    private static func releaseCPUThreadPool(_ threadPool: OpaquePointer?) {
        #if Zenzai || ZenzaiCPU
        guard let threadPool else {
            return
        }
        cpuThreadPoolStore.release(threadPool)
        #endif
    }

    private static func ctx_params(deviceConfig: ZenzaiDeviceConfig) -> llama_context_params {
        let n_threads = self.inferenceThreadCount
        debug("Using \(n_threads) threads")
        var ctx_params = llama_context_default_params()
        ctx_params.n_ctx = 512
        ctx_params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        ctx_params.n_threads       = Int32(n_threads)
        ctx_params.n_threads_batch = Int32(n_threads)
        ctx_params.n_batch = 512
        #if Zenzai || ZenzaiCPU
        ctx_params.n_ubatch = 64
        #endif
        #if Zenzai
        ctx_params.offload_kqv = deviceConfig.gpuLayers > 0
        #endif
        // 推論時間は呼び出し側で計測する。llama.cpp内部の統計更新は不要。
        ctx_params.no_perf = true
        return ctx_params
    }

    /// 対話的な推論に使うCPUスレッド数を実行環境のトポロジーから決定する。
    ///
    /// Apple Siliconでは性能の異なるクラスタを跨ぐと短いdecodeのbarrier待ちが
    /// 増えるため、最高性能クラスタの物理コア数を利用する。それ以外の環境では
    /// OSへ応答性の余地を残しつつ、llama.cppの小規模モデルで過剰並列にならない
    /// よう8スレッドを上限とする。
    // [hazkey-community patch] opt-in CPU thread budget override (HAZKEY_ZENZAI_CPU_THREADS).
    // Invalid values (absent, non-numeric, 0, negative, or > 8) fall back to the existing
    // activeProcessorCount-derived behavior unchanged — never crashes, never traps.
    private static let cpuThreadCountOverride: Int? = {
        guard let raw = ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_CPU_THREADS"],
              let value = Int(raw), value >= 1, value <= 8 else {
            return nil
        }
        return value
    }()

    private static var inferenceThreadCount: Int {
        let activeProcessorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        #if canImport(Darwin)
        let performanceCoreCount = self.sysctlInt32("hw.perflevel0.physicalcpu")
        #else
        let performanceCoreCount: Int? = nil
        #endif
        let selected = self.selectInferenceThreadCount(
            activeProcessorCount: activeProcessorCount,
            performanceCoreCount: performanceCoreCount
        )
        if let override = self.cpuThreadCountOverride {
            debug("HAZKEY_ZENZAI_CPU_THREADS override: using \(override) threads (default would be \(selected))")
            return override
        }
        return selected
    }

    /// DarwinではmacOS/iOSともに最高性能クラスタを優先し、sysctl値を取得できない
    /// 端末やDarwin以外では論理CPU数から安全なフォールバックを選ぶ。
    static func selectInferenceThreadCount(
        activeProcessorCount: Int,
        performanceCoreCount: Int?
    ) -> Int {
        let activeProcessorCount = max(1, activeProcessorCount)
        if let performanceCoreCount,
           performanceCoreCount > 0,
           performanceCoreCount <= activeProcessorCount {
            return performanceCoreCount
        }
        let reservedProcessorCount = if activeProcessorCount >= 8 {
            2
        } else if activeProcessorCount >= 4 {
            1
        } else {
            0
        }
        return max(1, min(8, activeProcessorCount - reservedProcessorCount))
    }

    #if canImport(Darwin)
    private static func sysctlInt32(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else {
            return nil
        }
        return Int(value)
    }
    #endif

    static func createContext(
        path: String,
        deviceConfig: ZenzaiDeviceConfig = ZenzaiDeviceConfig()
    ) throws -> ZenzContext {
        let sharedModel = try SharedZenzModelCache.shared.model(
            path: path,
            deviceConfig: deviceConfig
        )
        var params = ctx_params(deviceConfig: deviceConfig)
        #if ZenzaiCPU
        // CPU 専用: KV / KQV 等の GPU オフロードを完全に無効化
        params.offload_kqv = false
        #endif
        let context = llama_init_from_model(sharedModel.model, params)
        guard let context else {
            debug("Could not load context!")
            throw ZenzError.couldNotLoadContext
        }
        let cpuThreadPool = Self.acquireCPUThreadPool(
            deviceConfig: deviceConfig,
            threadCount: params.n_threads
        )
        let cpuThreadPoolThreadCount = cpuThreadPool == nil ? nil : params.n_threads
        Self.attachCPUThreadPool(
            cpuThreadPool,
            poolThreadCount: cpuThreadPoolThreadCount,
            contextThreadCount: params.n_threads,
            to: context
        )

        return ZenzContext(
            sharedModel: sharedModel,
            context: context,
            deviceConfig: deviceConfig,
            cpuThreadPool: cpuThreadPool,
            cpuThreadPoolThreadCount: cpuThreadPoolThreadCount
        )
    }

    func resetContext() throws {
        Self.detachCPUThreadPool(self.cpuThreadPool, from: self.context)
        llama_free(self.context)
        var params = Self.ctx_params(deviceConfig: self.currentDeviceConfig)
        #if ZenzaiCPU
        params.offload_kqv = false
        #endif
        let context = llama_init_from_model(self.sharedModel.model, params)
        guard let context else {
            debug("Could not load context!")
            throw ZenzError.couldNotLoadContext
        }
        self.context = context
        Self.attachCPUThreadPool(
            self.cpuThreadPool,
            poolThreadCount: self.cpuThreadPoolThreadCount,
            contextThreadCount: params.n_threads,
            to: context
        )
        self.prevInputBySeq = [:]
        self.prevPromptBySeq = [:]
    }

    private func getLogits(tokens: [llama_token], logits_start_index: Int = 0, seqId: llama_seq_id = 0) -> UnsafeMutablePointer<Float>? {
        let perfStart = ZenzInferencePerf.shared.enabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if perfStart != 0 {
                ZenzInferencePerf.shared.record(DispatchTime.now().uptimeNanoseconds - perfStart)
            }
        }

        let currentPrevInput = self.prevInputBySeq[seqId] ?? []
        var effectivePrevInput = currentPrevInput

        // Try to copy KV cache from the other sequence if it gives a longer prefix match.
        let otherSeqId: llama_seq_id? = if seqId == evalSeqId {
            inputPredictionSeqId
        } else if seqId == inputPredictionSeqId {
            evalSeqId
        } else {
            nil
        }
        if let otherSeqId, let otherPrevInput = self.prevInputBySeq[otherSeqId] {
            let currentPrefix = currentPrevInput.commonPrefix(with: tokens).count
            let otherPrefix = otherPrevInput.commonPrefix(with: tokens).count
            if otherPrefix > currentPrefix {
                let copiedPrefixCount = min(otherPrefix, logits_start_index)
                if copiedPrefixCount > 0 {
                    llama_memory_seq_rm(llama_get_memory(context), seqId, 0, -1)
                    llama_memory_seq_cp(llama_get_memory(context), otherSeqId, seqId, 0, llama_pos(copiedPrefixCount))
                    effectivePrevInput = otherPrevInput
                }
            }
        }

        // Manage KV cache: remove entries that differ from previous input
        let prefixCacheCount: Int
        do {
            let pos_max = llama_memory_seq_pos_max(llama_get_memory(self.context), seqId)
            debug("pos max:", pos_max, "prevInput count:", effectivePrevInput.count, "tokens count:", tokens.count)
            let commonTokens = effectivePrevInput.commonPrefix(with: tokens)
            // Remove KV cache from position commonTokens.count onwards to recompute divergent part
            // removed range: [llama_pos(commonTokens.count), inf)
            prefixCacheCount = min(commonTokens.count, logits_start_index)
            llama_memory_seq_rm(llama_get_memory(context), seqId, llama_pos(prefixCacheCount), -1)
            debug("new pos max:", llama_memory_seq_pos_max(llama_get_memory(self.context), seqId), "commonTokens:", commonTokens.count)
        }
        self.batch.n_tokens = 0
        let n_ctx = llama_n_ctx(context)
        let n_kv_req = tokens.count + (Int(n_len) - tokens.count)
        if n_kv_req > n_ctx {
            debug("error: n_kv_req > n_ctx, the required KV cache size is not big enough")
        }
        for i in tokens.indices.dropFirst(prefixCacheCount) {
            llama_batch_add(&self.batch, tokens[i], Int32(i), [seqId], logits: logits_start_index <= i)
        }
        // 評価
        if llama_decode(context, self.batch) != 0 {
            debug("llama_decode() failed")
            return nil
        }
        // update cached input for next call (for KV cache management)
        self.prevInputBySeq[seqId] = tokens
        return llama_get_logits(context)
    }

    func previousEvaluationPrompt() -> String {
        self.prevPromptBySeq[evalSeqId] ?? ""
    }

    func setPreviousEvaluationPrompt(_ prompt: String) {
        self.prevPromptBySeq[evalSeqId] = prompt
    }

    func normalizeForModel(_ text: String) -> String {
        self.preprocessText(text: text)
    }

    func encodeEvaluationPrompt(
        _ prompt: String,
        memoizationCache: ZenzaiMemoizationCache
    ) -> [llama_token] {
        if let cached = memoizationCache.cachedEvaluationPromptTokens(for: prompt) {
            return cached
        }
        let tokens = self.encode(prompt, addBOS: true, addEOS: false)
        memoizationCache.cacheEvaluationPromptTokens(tokens, for: prompt)
        return tokens
    }

    func encode(_ text: String, addBOS: Bool, addEOS: Bool = false) -> [llama_token] {
        self.tokenize(text: self.preprocessText(text: text), add_bos: addBOS, add_eos: addEOS)
    }

    func encodeRaw(_ text: String, addBOS: Bool, addEOS: Bool = false) -> [llama_token] {
        self.tokenize(text: text, add_bos: addBOS, add_eos: addEOS)
    }

    func evaluationLogits(tokens: [llama_token], startOffset: Int) -> UnsafeMutablePointer<Float>? {
        self.getLogits(tokens: tokens, logits_start_index: startOffset, seqId: evalSeqId)
    }

    func inputPredictionLogits(tokens: [llama_token], startOffset: Int) -> UnsafeMutablePointer<Float>? {
        self.getLogits(tokens: tokens, logits_start_index: startOffset, seqId: inputPredictionSeqId)
    }

    var vocabSize: Int {
        Int(llama_vocab_n_tokens(self.sharedModel.vocab))
    }

    var eosToken: llama_token {
        llama_vocab_eos(self.sharedModel.vocab)
    }

    func decodeTokens(_ tokens: [llama_token]) -> String {
        let cchars: [CChar] = tokens.flatMap(self.tokenToPiece)
        let data = Data(cchars.map { UInt8(bitPattern: $0) })
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func llama_batch_add(_ batch: inout llama_batch, _ id: llama_token, _ pos: llama_pos, _ seq_ids: [llama_seq_id], logits: Bool) {
        batch.token   [Int(batch.n_tokens)] = id
        batch.pos     [Int(batch.n_tokens)] = pos
        batch.n_seq_id[Int(batch.n_tokens)] = Int32(seq_ids.count)
        for i in 0..<seq_ids.count {
            batch.seq_id[Int(batch.n_tokens)]![Int(i)] = seq_ids[i]
        }
        batch.logits  [Int(batch.n_tokens)] = logits ? 1 : 0
        batch.n_tokens += 1
    }

    private func preprocessText(text: String) -> String {
        // replace space into ideographic space (\u3000) for zenz tokenizer
        // replace newline into null for zenz tokenizer
        text.replacingOccurrences(of: " ", with: "\u{3000}").replacingOccurrences(of: "\n", with: "")
    }
    private func tokenize(text: String, add_bos: Bool, add_eos: Bool = false) -> [llama_token] {
        let utf8Count = text.utf8.count
        let n_tokens = utf8Count + (add_bos ? 1 : 0)
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: n_tokens)
        let tokenCount = llama_tokenize(self.sharedModel.vocab, text, Int32(utf8Count), tokens, Int32(n_tokens), add_bos, false)
        var swiftTokens: [llama_token] = if tokenCount < 0 {
            [llama_vocab_bos(self.sharedModel.vocab)]
        } else {
            (0..<tokenCount).map {tokens[Int($0)]}
        }
        tokens.deallocate()
        if add_eos {
            swiftTokens.append(llama_vocab_eos(self.sharedModel.vocab))
        }
        return swiftTokens
    }

    /// - note: The result does not contain null-terminator
    func tokenToPiece(token: llama_token) -> [CChar] {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        result.initialize(repeating: Int8(0), count: 8)
        defer {
            result.deallocate()
        }
        let nTokens = llama_token_to_piece(self.sharedModel.vocab, token, result, 8, 0, false)

        if nTokens < 0 {
            let newResult = UnsafeMutablePointer<Int8>.allocate(capacity: Int(-nTokens))
            newResult.initialize(repeating: Int8(0), count: Int(-nTokens))
            defer {
                newResult.deallocate()
            }
            let nNewTokens = llama_token_to_piece(self.sharedModel.vocab, token, newResult, Int32(-nTokens), 0, false)
            let bufferPointer: UnsafeBufferPointer<Int8> = UnsafeBufferPointer(start: newResult, count: Int(nNewTokens))
            return Array(bufferPointer)
        } else {
            let bufferPointer: UnsafeBufferPointer<Int8> = UnsafeBufferPointer(start: result, count: Int(nTokens))
            return Array(bufferPointer)
        }
    }
}
