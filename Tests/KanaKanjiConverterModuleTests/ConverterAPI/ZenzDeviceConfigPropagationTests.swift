@testable import KanaKanjiConverterModule
import XCTest

/// Regression coverage for GPU device-config propagation through the Zenzai model construction
/// chain:
///
///   `KanaKanjiConverter.getModel` -> `Zenz.shared` -> `Zenz.init` -> `ZenzContext.createContext`
///   -> `SharedZenzModelCache.model` -> `SharedZenzModelCache.modelConstructor` (test seam)
///
/// The real llama.cpp model constructor (`SharedZenzModel.init`) is swapped out via
/// `SharedZenzModelCache.modelConstructor` so these tests never touch llama.cpp, a real model
/// file, GPU hardware, the live hazkey-server process, or user config. The fake constructor
/// always throws before a `SharedZenzModel` would be constructed, so the call is fully
/// observable without needing to fabricate llama.cpp pointers.
final class ZenzDeviceConfigPropagationTests: XCTestCase {
    private struct SentinelConstructionError: Error {}

    override func tearDown() {
        SharedZenzModelCache.modelConstructor = SharedZenzModel.init
        super.tearDown()
    }

    /// Proves that an explicit GPU `ZenzaiDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99)`
    /// supplied through `ConvertRequestOptions.ZenzaiMode.on(deviceConfig:)` reaches the model
    /// construction seam unchanged, via the exact same `zenzaiMode.weightURL` /
    /// `zenzaiMode.deviceConfig` accessors used by `KanaKanjiConverter`'s real call sites.
    func testGetModelPropagatesExplicitGPUDeviceConfigToModelConstructionSeam() {
        var capturedCalls: [(path: String, deviceConfig: ZenzaiDeviceConfig)] = []
        SharedZenzModelCache.modelConstructor = { path, deviceConfig in
            capturedCalls.append((path, deviceConfig))
            throw SentinelConstructionError()
        }

        let modelURL = URL(fileURLWithPath: "/tmp/zenz-device-config-propagation-\(UUID().uuidString).gguf")
        let gpuConfig = ZenzaiDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99)
        let zenzaiMode = ConvertRequestOptions.ZenzaiMode.on(
            weight: modelURL,
            personalizationMode: nil,
            deviceConfig: gpuConfig
        )

        let converter = KanaKanjiConverter.withoutDictionary()
        let model = converter.getModel(modelURL: zenzaiMode.weightURL, deviceConfig: zenzaiMode.deviceConfig)

        XCTAssertNil(model, "the fake constructor always throws, so getModel must fail rather than return a model")
        XCTAssertEqual(capturedCalls.count, 1, "the model construction seam must be reached exactly once")
        XCTAssertEqual(capturedCalls.first?.path, modelURL.path)
        XCTAssertEqual(
            capturedCalls.first?.deviceConfig, gpuConfig,
            "the GPU device config supplied through ConvertRequestOptions.ZenzaiMode must reach the model construction seam unchanged"
        )
    }

    /// A CPU-only device config (the implicit default used when no GPU is selected) must reach
    /// the seam as CPU, not silently upgraded to GPU.
    func testGetModelPropagatesCPUDeviceConfigToModelConstructionSeam() {
        var capturedCalls: [(path: String, deviceConfig: ZenzaiDeviceConfig)] = []
        SharedZenzModelCache.modelConstructor = { path, deviceConfig in
            capturedCalls.append((path, deviceConfig))
            throw SentinelConstructionError()
        }

        let modelURL = URL(fileURLWithPath: "/tmp/zenz-device-config-propagation-\(UUID().uuidString).gguf")
        let cpuConfig = ZenzaiDeviceConfig(deviceName: "CPU", gpuLayers: 0)
        let zenzaiMode = ConvertRequestOptions.ZenzaiMode.on(
            weight: modelURL,
            personalizationMode: nil,
            deviceConfig: cpuConfig
        )

        let converter = KanaKanjiConverter.withoutDictionary()
        _ = converter.getModel(modelURL: zenzaiMode.weightURL, deviceConfig: zenzaiMode.deviceConfig)

        XCTAssertEqual(capturedCalls.count, 1)
        XCTAssertEqual(capturedCalls.first?.deviceConfig, cpuConfig)
        XCTAssertEqual(capturedCalls.first?.deviceConfig.gpuLayers, 0)
    }

    // MARK: - Cache identity / separation

    /// `SharedZenzModelCache` must not share a cached model between two different device
    /// configurations for the same weight path (e.g. CPU vs. GPU), or a device switch would
    /// silently reuse a model loaded for the wrong device.
    func testSharedZenzModelCacheKeySeparatesDeviceConfigsForSamePath() {
        let path = "/tmp/shared-zenz-model-cache-key-test.gguf"
        let cpuConfig = ZenzaiDeviceConfig(deviceName: nil, gpuLayers: 0)
        let gpuConfig = ZenzaiDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99)

        let cpuKey = SharedZenzModelCache.cacheKey(path: path, deviceConfig: cpuConfig)
        let gpuKey = SharedZenzModelCache.cacheKey(path: path, deviceConfig: gpuConfig)

        XCTAssertNotEqual(cpuKey, gpuKey, "CPU and GPU device configs for the same weight path must not share a cache identity")
        XCTAssertEqual(cpuKey, SharedZenzModelCache.cacheKey(path: path, deviceConfig: cpuConfig), "identical device configs must map to the same cache identity")
    }

    /// The outer `Zenz`-level cache (keyed by resource URL) must apply the same separation rule.
    func testSharedZenzCacheKeySeparatesDeviceConfigsForSameURL() {
        let url = URL(fileURLWithPath: "/tmp/shared-zenz-cache-key-test.gguf")
        let cpuConfig = ZenzaiDeviceConfig(deviceName: nil, gpuLayers: 0)
        let gpuConfig = ZenzaiDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99)

        let cpuKey = SharedZenzCache.cacheKey(resourceURL: url, deviceConfig: cpuConfig)
        let gpuKey = SharedZenzCache.cacheKey(resourceURL: url, deviceConfig: gpuConfig)

        XCTAssertNotEqual(cpuKey, gpuKey, "CPU and GPU device configs for the same model URL must not share a cache identity")
        XCTAssertEqual(cpuKey, SharedZenzCache.cacheKey(resourceURL: url, deviceConfig: cpuConfig), "identical device configs must map to the same cache identity")
    }

    /// `KanaKanjiConverter.getModel`'s instance-level fast path (`self.zenz`) must not reuse an
    /// already-loaded `Zenz` when the requested device config differs from the cached one, even
    /// for the same model URL. This is the pure predicate extracted from that fast path so it is
    /// regression-testable without constructing a real llama.cpp context.
    func testZenzCanReuseRejectsMismatchedDeviceConfigForSameURL() {
        let url = URL(fileURLWithPath: "/tmp/zenz-instance-cache-test.gguf")
        let cpuConfig = ZenzaiDeviceConfig(deviceName: nil, gpuLayers: 0)
        let gpuConfig = ZenzaiDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99)

        XCTAssertFalse(
            Zenz.canReuse(cachedURL: url, cachedDeviceConfig: cpuConfig, requestedURL: url, requestedDeviceConfig: gpuConfig),
            "a CPU-loaded model must not be reused for a GPU device-config request"
        )
        XCTAssertTrue(
            Zenz.canReuse(cachedURL: url, cachedDeviceConfig: gpuConfig, requestedURL: url, requestedDeviceConfig: gpuConfig),
            "identical URL and device config must be reusable"
        )
    }
}
