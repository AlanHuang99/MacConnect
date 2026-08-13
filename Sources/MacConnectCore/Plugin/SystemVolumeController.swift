@preconcurrency import CoreAudio
@preconcurrency import Foundation

enum SystemVolumeMath {
    static func percent(fromScalar scalar: Double) -> Int {
        Int((min(1, max(0, scalar)) * 100).rounded())
    }

    static func scalar(fromPercent percent: Int) -> Float32 {
        Float32(min(100, max(0, percent))) / 100
    }

    static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

@MainActor
protocol SystemVolumeProviding: AnyObject {
    var volume: Int? { get }
    var onChange: (() -> Void)? { get set }

    func setVolume(_ percent: Int)
}

@MainActor
final class CoreAudioVolumeController: SystemVolumeProviding {
    private final class ListenerRegistration: @unchecked Sendable {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock

        init?(
            objectID: AudioObjectID,
            address: AudioObjectPropertyAddress,
            queue: DispatchQueue,
            block: @escaping AudioObjectPropertyListenerBlock
        ) {
            self.objectID = objectID
            self.address = address
            self.queue = queue
            self.block = block

            var mutableAddress = address
            let status = AudioObjectAddPropertyListenerBlock(
                objectID,
                &mutableAddress,
                queue,
                block
            )
            guard status == noErr else { return nil }
        }

        deinit {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(
                objectID,
                &mutableAddress,
                queue,
                block
            )
        }
    }

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private var defaultDevice = AudioDeviceID(kAudioObjectUnknown)
    private var volumeAddresses: [AudioObjectPropertyAddress] = []
    private var systemListener: ListenerRegistration?
    private var deviceListeners: [ListenerRegistration] = []

    var onChange: (() -> Void)?

    var volume: Int? {
        let scalars = volumeAddresses.compactMap { readScalar(objectID: defaultDevice, address: $0) }
        guard let mean = SystemVolumeMath.average(scalars) else { return nil }
        return SystemVolumeMath.percent(fromScalar: mean)
    }

    init() {
        observeDefaultDevice()
        reconfigureDevice()
    }

    func setVolume(_ percent: Int) {
        let scalar = SystemVolumeMath.scalar(fromPercent: percent)
        var wroteValue = false

        for address in volumeAddresses {
            var mutableAddress = address
            var value = scalar
            let status = AudioObjectSetPropertyData(
                defaultDevice,
                &mutableAddress,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &value
            )
            if status == noErr {
                wroteValue = true
            } else {
                Log.plugin.error("Core Audio volume write failed with status \(status, privacy: .public)")
            }
        }

        if wroteValue { onChange?() }
    }

    private func observeDefaultDevice() {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        systemListener = ListenerRegistration(
            objectID: systemObject,
            address: address,
            queue: .main
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.reconfigureDevice()
                self?.onChange?()
            }
        }
    }

    private func reconfigureDevice() {
        deviceListeners.removeAll()
        volumeAddresses.removeAll()

        guard let device = readDefaultOutputDevice() else {
            defaultDevice = AudioDeviceID(kAudioObjectUnknown)
            return
        }

        defaultDevice = device
        volumeAddresses = resolveVolumeAddresses(for: device)
        deviceListeners = volumeAddresses.compactMap { address in
            ListenerRegistration(objectID: device, address: address, queue: .main) { [weak self] _, _ in
                Task { @MainActor in self?.onChange?() }
            }
        }
    }

    private func readDefaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            if status != noErr {
                Log.plugin.error("Core Audio default output read failed with status \(status, privacy: .public)")
            }
            return nil
        }
        return device
    }

    private func resolveVolumeAddresses(for device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        let master = volumeAddress(element: kAudioObjectPropertyElementMain)
        if isWritable(master, on: device) { return [master] }

        let channelCount = outputChannelCount(for: device)
        guard channelCount > 0 else { return [] }
        return (1 ... channelCount)
            .map(volumeAddress(element:))
            .filter { isWritable($0, on: device) }
    }

    private func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private func isWritable(_ suppliedAddress: AudioObjectPropertyAddress, on device: AudioDeviceID) -> Bool {
        var address = suppliedAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(device, &address, &settable)
        return status == noErr && settable.boolValue
    }

    private func outputChannelCount(for device: AudioDeviceID) -> AudioObjectPropertyElement {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let bufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else {
            return 0
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    private func readScalar(
        objectID: AudioObjectID,
        address suppliedAddress: AudioObjectPropertyAddress
    ) -> Double? {
        guard objectID != kAudioObjectUnknown else { return nil }
        var address = suppliedAddress
        var scalar = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &scalar)
        guard status == noErr else { return nil }
        return Double(scalar)
    }
}
