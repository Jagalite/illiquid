import CoreAudio
import AudioToolbox
import Foundation
import SuperplayrCore

struct NativeAudioDeviceCatalog: Sendable {
    var devices: [AudioOutputDevice] = []
    var channelCapacities: [String: Int] = [:]
    var privateOutputIDs: Set<String> = []
    var objectIDs: [AudioObjectID] = []
    var isValid = true

    func lostPrivateOutput(comparedTo previous: Self, selectedID: String?) -> Bool {
        guard let previousID = selectedID ?? previous.devices.first(where: \.isDefault)?.id,
              previous.privateOutputIDs.contains(previousID) else { return false }
        // A deliberate default switch with the old headphones still connected
        // is not a disconnect. Unknown terminal types are not guessed by name.
        return !devices.contains(where: { $0.id == previousID }) || !privateOutputIDs.contains(previousID)
    }

    func capacity(selectedID: String?) -> Int {
        guard let id = selectedID ?? devices.first(where: \.isDefault)?.id else { return 2 }
        return channelCapacities[id] ?? 2
    }
}

/// Owns Core Audio discovery only. Renderer routing and recovery remain with
/// the existing presentation coordinator and playback core.
final class NativeAudioDeviceMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.platinum.audio-devices", qos: .utility)
    private let lock = NSLock()
    private var active = true
    private var refreshScheduled = false
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let publish: @Sendable (NativeAudioDeviceCatalog) -> Void

    init(publish: @escaping @Sendable (NativeAudioDeviceCatalog) -> Void) {
        self.publish = publish
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   queue, listener) == noErr {
                listeners.append((address, listener))
            }
        }
        refresh()
    }

    func stop() {
        guard lock.withLock({
            if !active { return false }
            active = false
            return true
        }) else { return }
        // Retire discovery asynchronously: a slow device property read must
        // not make the main actor wait for this utility queue during quit.
        queue.async { [self] in removeListeners() }
    }

    private func removeListeners() {
        for (object, var address, listener) in deviceListeners {
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        }
        deviceListeners.removeAll()
        for (var address, listener) in listeners {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   queue, listener)
        }
        listeners.removeAll()
    }

    // A queued refresh/removal retains self while using the registrations, so
    // final destruction cannot race that work or resurrect self in an async task.
    deinit { removeListeners() }

    func refresh() {
        guard lock.withLock({
            guard active, !refreshScheduled else { return false }
            refreshScheduled = true
            return true
        }) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let devices = Self.readCatalog()
            if lock.withLock({ active }) { updateDeviceListeners(devices.objectIDs) }
            let shouldPublish = lock.withLock {
                refreshScheduled = false
                return active
            }
            if shouldPublish { publish(devices) }
        }
    }

    private func updateDeviceListeners(_ ids: [AudioObjectID]) {
        guard Set(deviceListeners.map { $0.0 }) != Set(ids) else { return }
        for (object, var address, listener) in deviceListeners {
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        }
        deviceListeners.removeAll()
        for object in ids {
            for property in [
                Self.address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput),
                Self.address(kAudioDevicePropertyJackIsConnected, scope: kAudioObjectPropertyScopeOutput),
                Self.address(kAudioDevicePropertyDeviceIsAlive),
            ] {
                var address = property
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
                if AudioObjectAddPropertyListenerBlock(object, &address, queue, listener) == noErr {
                    deviceListeners.append((object, address, listener))
                }
            }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func withOutputProperty<T>(_ id: AudioObjectID, selector: AudioObjectPropertySelector,
                                              read: (UnsafeRawPointer, Int) -> T?) -> T? {
        var property = address(selector, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr,
              size > 0, size <= 65_536 else { return nil }
        let allocated = Int(size)
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: allocated, alignment: MemoryLayout<UInt64>.alignment)
        defer { bytes.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, bytes) == noErr,
              Int(size) <= allocated else { return nil }
        return read(UnsafeRawPointer(bytes), Int(size))
    }

    private static func channelCapacity(_ id: AudioObjectID) -> Int {
        let streamChannels: Int? = withOutputProperty(id, selector: kAudioDevicePropertyStreamConfiguration) { bytes, size in
            let header = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
            guard size >= header else { return nil }
            let count = Int(bytes.load(as: UInt32.self))
            guard count <= (size - header) / MemoryLayout<AudioBuffer>.stride else { return nil }
            let buffers = bytes.advanced(by: header).assumingMemoryBound(to: AudioBuffer.self)
            return (0..<count).reduce(0) { $0 + Int(buffers[$1].mNumberChannels) }
        }
        let preferredChannels: Int? = withOutputProperty(id, selector: kAudioDevicePropertyPreferredChannelLayout) { bytes, size in
            preferredSurroundCapacity(bytes, byteCount: size)
        }
        return negotiatedChannelCapacity(streamChannels: streamChannels, preferredChannels: preferredChannels)
    }

    static func preferredSurroundCapacity(_ bytes: UnsafeRawPointer, byteCount: Int) -> Int? {
        let header = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        guard byteCount >= header else { return nil }
        let tag = bytes.load(as: AudioChannelLayoutTag.self)
        if tag != kAudioChannelLayoutTag_UseChannelDescriptions {
            let bitmap = tag == kAudioChannelLayoutTag_UseChannelBitmap
            var value = bitmap ? bytes.load(fromByteOffset: 4, as: UInt32.self) : tag
            let property = bitmap ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
            var size: UInt32 = 0
            guard AudioFormatGetPropertyInfo(property, 4, &value, &size) == noErr,
                  size >= header, size <= 65_536 else { return nil }
            let capacity = Int(size)
            let expanded = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { expanded.deallocate() }
            guard AudioFormatGetProperty(property, 4, &value, &size, expanded) == noErr,
                  Int(size) <= capacity, Int(size) >= header else { return nil }
            // Core Audio supplies descriptions while retaining the input tag.
            return surroundCapacityFromDescriptions(UnsafeRawPointer(expanded), byteCount: Int(size))
        }
        return surroundCapacityFromDescriptions(bytes, byteCount: byteCount)
    }

    private static func surroundCapacityFromDescriptions(_ bytes: UnsafeRawPointer, byteCount: Int) -> Int? {
        let header = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        guard byteCount >= header else { return nil }
        let count = Int(bytes.load(fromByteOffset: 8, as: UInt32.self))
        guard count <= 128, count <= (byteCount - header) / MemoryLayout<AudioChannelDescription>.stride else { return nil }
        let labels = Set((0..<count).map {
            bytes.load(fromByteOffset: header + $0 * MemoryLayout<AudioChannelDescription>.stride, as: AudioChannelLabel.self)
        })
        let base: Set<AudioChannelLabel> = [kAudioChannelLabel_Left, kAudioChannelLabel_Right,
                                           kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen]
        guard labels.isSuperset(of: base) else { return 2 }
        let side = labels.isSuperset(of: [kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround])
        let rear = labels.isSuperset(of: [kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight])
        if side && rear { return 8 }
        return side || rear ? 6 : 2
    }

    static func negotiatedChannelCapacity(streamChannels: Int?, preferredChannels: Int?) -> Int {
        guard let streamChannels, let preferredChannels,
              (1...128).contains(streamChannels), (1...128).contains(preferredChannels) else { return 2 }
        let channels = min(streamChannels, preferredChannels)
        return channels >= 8 ? 8 : channels >= 6 ? 6 : 2
    }

    private static func isPrivateOutput(_ id: AudioObjectID) -> Bool {
        for property in [address(kAudioDevicePropertyDeviceIsAlive),
                         address(kAudioDevicePropertyJackIsConnected, scope: kAudioObjectPropertyScopeOutput)] {
            var property = property
            var value: UInt32 = 1
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr, value == 0 { return false }
        }
        return withOutputProperty(id, selector: kAudioDevicePropertyStreams) { bytes, size in
            guard size % MemoryLayout<AudioStreamID>.stride == 0 else { return false }
            return (0..<(size / MemoryLayout<AudioStreamID>.stride)).contains { index in
                let stream = bytes.load(fromByteOffset: index * MemoryLayout<AudioStreamID>.stride, as: AudioStreamID.self)
                var property = address(kAudioStreamPropertyTerminalType)
                var terminal: UInt32 = 0
                var count = UInt32(MemoryLayout<UInt32>.size)
                guard AudioObjectGetPropertyData(stream, &property, 0, nil, &count, &terminal) == noErr else { return false }
                return terminal == kAudioStreamTerminalTypeHeadphones || terminal == kAudioStreamTerminalTypeReceiverSpeaker
            }
        } ?? false
    }

    static func readCatalog() -> NativeAudioDeviceCatalog {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var defaultID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(system, &property, 0, nil, &size, &defaultID)
        property = address(kAudioHardwarePropertyDevices)
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr,
              size > 0, size <= UInt32(1024 * MemoryLayout<AudioDeviceID>.stride),
              size % UInt32(MemoryLayout<AudioDeviceID>.stride) == 0 else { return .init(isValid: false) }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return .init(isValid: false) }
        var privateOutputs: Set<String> = []
        var capacities: [String: Int] = [:]
        let devices: [AudioOutputDevice] = ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = string(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(id, selector: kAudioObjectPropertyName) else { return nil }
            capacities[uid] = channelCapacity(id)
            if isPrivateOutput(id) { privateOutputs.insert(uid) }
            return AudioOutputDevice(id: uid, name: name, isDefault: id == defaultID, isSelected: false)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return NativeAudioDeviceCatalog(devices: devices, channelCapacities: capacities, privateOutputIDs: privateOutputs, objectIDs: ids)
    }

    static func selectionSnapshot(_ devices: [AudioOutputDevice], selectedID: String?) -> [AudioOutputDevice] {
        let defaultName = devices.first(where: \.isDefault)?.name
        var result = [AudioOutputDevice(id: "auto", name: defaultName.map { "System Default (\($0))" } ?? "System Default",
                                  isDefault: true, isSelected: selectedID == nil)]
            + devices.map { AudioOutputDevice(id: $0.id, name: $0.name, isDefault: $0.isDefault,
                                               isSelected: $0.id == selectedID) }
        if let selectedID, !devices.contains(where: { $0.id == selectedID }) {
            // A rejected fallback must not be reported as successful routing.
            result.append(AudioOutputDevice(id: selectedID, name: "Unavailable output",
                                            isDefault: false, isSelected: true))
        }
        return result
    }
}
