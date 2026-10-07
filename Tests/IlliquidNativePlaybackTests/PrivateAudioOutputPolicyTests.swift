import Testing
import IlliquidCore
@testable import IlliquidNativePlayback

@Suite("Private audio output disconnect policy")
struct PrivateAudioOutputPolicyTests {
    private let headphones = AudioOutputDevice(id: "headphones", name: "Private", isDefault: true, isSelected: false)
    private let speaker = AudioOutputDevice(id: "speaker", name: "Speaker", isDefault: true, isSelected: false)

    @Test func removedPrivateOutputPausesButDefaultSwitchDoesNot() {
        let before = NativeAudioDeviceCatalog(devices: [headphones], privateOutputIDs: ["headphones"])
        let removed = NativeAudioDeviceCatalog(devices: [speaker])
        #expect(removed.lostPrivateOutput(comparedTo: before, selectedID: nil))
        let switched = NativeAudioDeviceCatalog(devices: [speaker, headphones], privateOutputIDs: ["headphones"])
        #expect(!switched.lostPrivateOutput(comparedTo: before, selectedID: nil))
    }

    @Test func selectedOutputAndInPlaceJackChangeUsePreviousRoute() {
        let before = NativeAudioDeviceCatalog(devices: [speaker, headphones], privateOutputIDs: ["headphones"])
        let after = NativeAudioDeviceCatalog(devices: [speaker, headphones])
        #expect(after.lostPrivateOutput(comparedTo: before, selectedID: "headphones"))
        #expect(!after.lostPrivateOutput(comparedTo: before, selectedID: "speaker"))
        #expect(!after.lostPrivateOutput(comparedTo: .init(), selectedID: nil))
    }
}
