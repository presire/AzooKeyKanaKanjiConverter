@testable import KanaKanjiConverterModule
import XCTest

/// Regression coverage for `resolveDeviceConfig` (the pure classification logic behind
/// `createDeviceConfig`), covering the GGML `.igpu` device-type category (integrated GPU using
/// host memory, e.g. AMD APU / RADV RAPHAEL_MENDOCINO). llama.cpp's Vulkan backend reports
/// integrated GPUs as `GGML_BACKEND_DEVICE_TYPE_IGPU`, distinct from `GGML_BACKEND_DEVICE_TYPE_GPU`
/// (dedicated memory) -- both are equally capable of receiving offloaded model layers. These tests
/// never touch llama.cpp/GGML/a real GPU: `GGMLBackendDevice`'s plain memberwise initializer
/// constructs synthetic devices directly.
final class GGMLBackendDeviceSelectionTests: XCTestCase {
    func testResolveDeviceConfigTreatsIntegratedGPUAsGPUCapable() {
        let devices = [
            GGMLBackendDevice(name: "Vulkan0", description: "AMD Radeon Graphics (RADV RAPHAEL_MENDOCINO)", type: .igpu),
            GGMLBackendDevice(name: "CPU", description: "AMD Ryzen 9 9900X 12-Core Processor", type: .cpu),
        ]

        let config = resolveDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99, devices: devices)

        XCTAssertEqual(config.deviceName, "Vulkan0")
        XCTAssertEqual(config.gpuLayers, 99, "an integrated GPU selected by name must receive the requested GPU layer count, not be forced to 0")
    }

    func testResolveDeviceConfigTreatsDedicatedGPUAsGPUCapable() {
        let devices = [
            GGMLBackendDevice(name: "Vulkan0", description: "NVIDIA GeForce RTX", type: .gpu),
            GGMLBackendDevice(name: "CPU", description: "Generic CPU", type: .cpu),
        ]

        let config = resolveDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99, devices: devices)

        XCTAssertEqual(config.deviceName, "Vulkan0")
        XCTAssertEqual(config.gpuLayers, 99)
    }

    func testResolveDeviceConfigForcesZeroLayersForCPUDevice() {
        let devices = [
            GGMLBackendDevice(name: "CPU", description: "Generic CPU", type: .cpu),
        ]

        let config = resolveDeviceConfig(deviceName: "CPU", gpuLayers: 99, devices: devices)

        XCTAssertEqual(config.deviceName, "CPU")
        XCTAssertEqual(config.gpuLayers, 0)
    }

    func testResolveDeviceConfigForcesZeroLayersForUnknownOrAccelDeviceType() {
        let devices = [
            GGMLBackendDevice(name: "Weird0", description: "Unclassified device", type: .unknown),
            GGMLBackendDevice(name: "Accel0", description: "BLAS accelerator", type: .accel),
        ]

        XCTAssertEqual(resolveDeviceConfig(deviceName: "Weird0", gpuLayers: 99, devices: devices).gpuLayers, 0)
        XCTAssertEqual(resolveDeviceConfig(deviceName: "Accel0", gpuLayers: 99, devices: devices).gpuLayers, 0)
    }

    func testResolveDeviceConfigFallsBackToCPUWhenRequestedDeviceNameIsAbsent() {
        let devices = [
            GGMLBackendDevice(name: "Vulkan0", description: "Some GPU", type: .igpu),
            GGMLBackendDevice(name: "CPU", description: "Generic CPU", type: .cpu),
        ]

        let config = resolveDeviceConfig(deviceName: "Vulkan9-does-not-exist", gpuLayers: 99, devices: devices)

        XCTAssertEqual(config.deviceName, "CPU")
        XCTAssertEqual(config.gpuLayers, 0)
    }

    func testResolveDeviceConfigReturnsNilDeviceWhenNoDevicesEnumerated() {
        let config = resolveDeviceConfig(deviceName: "Vulkan0", gpuLayers: 99, devices: [])

        XCTAssertNil(config.deviceName)
        XCTAssertEqual(config.gpuLayers, 0)
    }
}
