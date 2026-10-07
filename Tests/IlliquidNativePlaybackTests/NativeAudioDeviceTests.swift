import CNativeAudio
import Foundation
import IlliquidCore
import Testing
@testable import IlliquidNativePlayback

@Suite("Native audio output selection")
struct NativeAudioDeviceTests {
    @Test func defaultExplicitAndDisconnectedSelectionRemainUnambiguous() {
        let devices = [
            AudioOutputDevice(id: "speakers", name: "Speakers", isDefault: true, isSelected: false),
            AudioOutputDevice(id: "usb", name: "USB DAC", isDefault: false, isSelected: false),
        ]
        #expect(NativeAudioDeviceMonitor.selectionSnapshot(devices, selectedID: nil)
            .filter(\.isSelected).map(\.id) == ["auto"])
        #expect(NativeAudioDeviceMonitor.selectionSnapshot(devices, selectedID: "usb")
            .filter(\.isSelected).map(\.id) == ["usb"])
        #expect(NativeAudioDeviceMonitor.selectionSnapshot(Array(devices.prefix(1)), selectedID: "usb")
            .filter(\.isSelected).map(\.name) == ["Unavailable output"])
        #expect(NativeAudioDeviceMonitor.selectionSnapshot([], selectedID: "gone")
            .filter(\.isSelected).map(\.id) == ["gone"])
    }

    @Test func objectiveCSelectionExceptionBecomesAnErrorValue() {
        // NSObject lacks the renderer setter: Objective-C raises inside the
        // bridge, without unwinding through a Swift setter or crashing tests.
        let invalidRenderer = NSObject()
        let error = SPSetAudioOutputDevice(Unmanaged.passUnretained(invalidRenderer).toOpaque(), nil)
        #expect(error != nil)
    }

    @Test func defaultSelectionDoesNotReconfigureAnAlreadyDefaultRenderer() throws {
        let presentation = try NativePresentationCoordinator()
        defer { presentation.terminate() }
        let fence = presentation.currentFence
        try presentation.setAudioOutputDevice(nil)
        #expect(presentation.audioOutputDeviceID == nil)
        #expect(presentation.currentFence == fence)
    }
}
