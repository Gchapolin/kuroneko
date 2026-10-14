import CoreAudio
import Foundation

public enum CoreAudioError: Error, Equatable {
    case osStatus(OSStatus, String)
}

enum CoreAudioSupport {
    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw CoreAudioError.osStatus(status, operation) }
    }

    static func readProcessObjectList() throws -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = globalAddress(kAudioHardwarePropertyProcessObjectList)
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize),
            "processObjectList size"
        )
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var list = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        try check(
            AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &list),
            "processObjectList"
        )
        return list
    }

    static func readBundleID(of object: AudioObjectID) -> String? {
        var address = globalAddress(kAudioProcessPropertyBundleID)
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func readPID(of object: AudioObjectID) -> pid_t? {
        var address = globalAddress(kAudioProcessPropertyPID)
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        var value: pid_t = -1
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { return nil }
        return value
    }

    static func readUInt32(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> UInt32? {
        var address = globalAddress(selector)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { return nil }
        return value
    }

    static func translatePIDToProcessObject(_ pid: pid_t) -> AudioObjectID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = globalAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var object = AudioObjectID(kAudioObjectUnknown)
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                system,
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifierPointer,
                &dataSize,
                &object
            )
        }
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    static func readDefaultSystemOutputDeviceUID() throws -> String {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = globalAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        try check(
            AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &deviceID),
            "defaultSystemOutputDevice"
        )

        var uidAddress = globalAddress(kAudioDevicePropertyDeviceUID)
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, pointer)
        }
        guard status == noErr, let uid else {
            throw CoreAudioError.osStatus(status, "deviceUID")
        }
        return uid as String
    }

    static func readTapStreamDescription(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = globalAddress(kAudioTapPropertyFormat)
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var description = AudioStreamBasicDescription()
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &description),
            "tapFormat"
        )
        return description
    }
}
