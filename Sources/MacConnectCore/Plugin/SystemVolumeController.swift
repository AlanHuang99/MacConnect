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

struct SystemVolumeAddressStrategy {
    let primaryElements: [AudioObjectPropertyElement]
    let fallbackElements: [AudioObjectPropertyElement]

    static func preferredElements(
        mainIsReadable: Bool,
        usableChannelElements: [AudioObjectPropertyElement]
    ) -> [AudioObjectPropertyElement] {
        mainIsReadable ? [kAudioObjectPropertyElementMain] : usableChannelElements
    }

    static func resolve(
        mainIsReadable: Bool,
        usableChannelElements: [AudioObjectPropertyElement]
    ) -> SystemVolumeAddressStrategy {
        SystemVolumeAddressStrategy(
            primaryElements: preferredElements(
                mainIsReadable: mainIsReadable,
                usableChannelElements: usableChannelElements
            ),
            fallbackElements: mainIsReadable ? usableChannelElements : []
        )
    }
}

@MainActor
protocol SystemVolumeProviding: AnyObject {
    var volume: Int? { get }
    var isMuted: Bool? { get }
    var onChange: (() -> Void)? { get set }

    func setVolume(_ percent: Int)
    func setMuted(_ muted: Bool)
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
            guard status == noErr else {
                Log.plugin.error(
                    "Core Audio listener registration failed with status \(status, privacy: .public)"
                )
                return nil
            }
        }

        deinit {
            var mutableAddress = address
            let status = AudioObjectRemovePropertyListenerBlock(
                objectID,
                &mutableAddress,
                queue,
                block
            )
            if status != noErr {
                Log.plugin.error(
                    "Core Audio listener removal failed with status \(status, privacy: .public)"
                )
            }
        }
    }

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private var defaultDevice = AudioDeviceID(kAudioObjectUnknown)
    private var volumeAddresses: [AudioObjectPropertyAddress] = []
    private var fallbackVolumeAddresses: [AudioObjectPropertyAddress] = []
    private var muteAddress: AudioObjectPropertyAddress?
    private var systemListener: ListenerRegistration?
    private var deviceListeners: [ListenerRegistration] = []

    var onChange: (() -> Void)?

    var volume: Int? {
        var scalars = volumeAddresses.compactMap { readScalar(objectID: defaultDevice, address: $0) }
        if scalars.isEmpty {
            scalars = fallbackVolumeAddresses.compactMap {
                readScalar(objectID: defaultDevice, address: $0)
            }
        }
        guard let mean = SystemVolumeMath.average(scalars) else { return nil }
        return SystemVolumeMath.percent(fromScalar: mean)
    }

    var isMuted: Bool? {
        guard let muteAddress else { return nil }
        return readMuted(objectID: defaultDevice, address: muteAddress)
    }

    init() {
        observeDefaultDevice()
        reconfigureDevice()
    }

    func setVolume(_ percent: Int) {
        let scalar = SystemVolumeMath.scalar(fromPercent: percent)
        var wroteValue = write(scalar, to: volumeAddresses)
        if !wroteValue {
            wroteValue = write(scalar, to: fallbackVolumeAddresses)
        }

        if wroteValue { onChange?() }
    }

    func setMuted(_ muted: Bool) {
        guard var address = muteAddress else { return }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            defaultDevice,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        )
        if status == noErr {
            onChange?()
        } else {
            Log.plugin.error("Core Audio mute write failed with status \(status, privacy: .public)")
        }
    }

    private func write(_ scalar: Float32, to addresses: [AudioObjectPropertyAddress]) -> Bool {
        var wroteValue = false

        for address in addresses {
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
        return wroteValue
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
        fallbackVolumeAddresses.removeAll()
        muteAddress = nil

        guard let device = readDefaultOutputDevice() else {
            defaultDevice = AudioDeviceID(kAudioObjectUnknown)
            return
        }

        defaultDevice = device
        let resolved = resolveVolumeAddresses(for: device)
        volumeAddresses = resolved.primary
        fallbackVolumeAddresses = resolved.fallback
        let candidateMuteAddress = muteAddressValue()
        if isWritable(candidateMuteAddress, on: device),
           readMuted(objectID: device, address: candidateMuteAddress) != nil
        {
            muteAddress = candidateMuteAddress
        }
        let observedAddresses = volumeAddresses + fallbackVolumeAddresses + [muteAddress].compactMap { $0 }
        deviceListeners = observedAddresses.compactMap { address in
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

    private func resolveVolumeAddresses(
        for device: AudioDeviceID
    ) -> (primary: [AudioObjectPropertyAddress], fallback: [AudioObjectPropertyAddress]) {
        let mainVolume = volumeAddress(element: kAudioObjectPropertyElementMain)
        let channelCount = outputChannelCount(for: device)
        let usableChannelElements = channelCount > 0
            ? (1 ... channelCount).filter {
                let address = volumeAddress(element: $0)
                return isWritable(address, on: device) &&
                    readScalar(objectID: device, address: address) != nil
            }
            : []
        let mainIsReadable = isWritable(mainVolume, on: device) &&
            readScalar(objectID: device, address: mainVolume) != nil
        let strategy = SystemVolumeAddressStrategy.resolve(
            mainIsReadable: mainIsReadable,
            usableChannelElements: usableChannelElements
        )
        return (
            primary: strategy.primaryElements.map(volumeAddress(element:)),
            fallback: strategy.fallbackElements.map(volumeAddress(element:))
        )
    }

    private func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private func muteAddressValue() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func isWritable(_ suppliedAddress: AudioObjectPropertyAddress, on device: AudioDeviceID) -> Bool {
        var address = suppliedAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(device, &address, &settable)
        if status != noErr {
            Log.plugin.error(
                "Core Audio volume capability read failed with status \(status, privacy: .public)"
            )
        }
        return status == noErr && settable.boolValue
    }

    private func outputChannelCount(for device: AudioDeviceID) -> AudioObjectPropertyElement {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard sizeStatus == noErr, size > 0 else {
            if sizeStatus != noErr {
                Log.plugin.error(
                    "Core Audio channel count size read failed with status \(sizeStatus, privacy: .public)"
                )
            }
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let bufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        let readStatus = AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList)
        guard readStatus == noErr else {
            Log.plugin.error(
                "Core Audio channel count read failed with status \(readStatus, privacy: .public)"
            )
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
        guard status == noErr else {
            Log.plugin.error("Core Audio volume read failed with status \(status, privacy: .public)")
            return nil
        }
        return Double(scalar)
    }

    private func readMuted(
        objectID: AudioObjectID,
        address suppliedAddress: AudioObjectPropertyAddress
    ) -> Bool? {
        guard objectID != kAudioObjectUnknown else { return nil }
        var address = suppliedAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            Log.plugin.error("Core Audio mute read failed with status \(status, privacy: .public)")
            return nil
        }
        return value != 0
    }
}
