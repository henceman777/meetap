import CoreAudio
import Foundation

// MARK: - CoreAudio Helpers

func allDeviceIDs() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func stringProp(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var val: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &val) == noErr,
          let v = val else { return nil }
    return v as String
}

func deviceName(_ id: AudioDeviceID) -> String? { stringProp(id, kAudioObjectPropertyName) }
func deviceUID(_ id: AudioDeviceID) -> String? { stringProp(id, kAudioDevicePropertyDeviceUID) }

func outputChannels(_ id: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { ptr.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr) == noErr else { return 0 }
    return Int(ptr.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
}

func defaultDevice(output: Bool) -> AudioDeviceID? {
    let sel = output ? kAudioHardwarePropertyDefaultOutputDevice
                     : kAudioHardwarePropertyDefaultInputDevice
    var addr = AudioObjectPropertyAddress(
        mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var id: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
    return id
}

func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var devID = id
    return AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size), &devID) == noErr
}

func findByUID(_ uid: String) -> AudioDeviceID? {
    allDeviceIDs().first { deviceUID($0) == uid }
}

func findBlackHoleUID() -> String? {
    for id in allDeviceIDs() {
        if let name = deviceName(id), name.contains("BlackHole"),
           let uid = deviceUID(id) { return uid }
    }
    return nil
}

func getSampleRate(_ id: AudioDeviceID) -> Float64? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return nil }
    return rate
}

func setSampleRate(_ id: AudioDeviceID, _ rate: Float64) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var r = rate
    return AudioObjectSetPropertyData(id, &addr, 0, nil,
        UInt32(MemoryLayout<Float64>.size), &r) == noErr
}

// 多输出设备的固定标识
let kMOUID = "com.meeting-record.multi-output"
let kMOName = "Meeting Multi-Output"

func createMultiOutput(masterUID: String, secondUID: String, noDrift: Bool = false) -> AudioDeviceID? {
    // "stck": 1 = multi-output (stacked) mode
    // "drift": 1 = enable drift correction on secondary device
    let desc: [String: Any]
    if noDrift {
        // 无 master 模式：两个设备平等，都不加 drift correction
        // 适用于两个设备采样率相同的情况（如 Speaker 48kHz + BlackHole 48kHz）
        desc = [
            "name": kMOName, "uid": kMOUID,
            "private": 0, "stck": 1,
            "subdevices": [
                ["uid": masterUID],
                ["uid": secondUID]
            ]
        ]
    } else {
        desc = [
            "name": kMOName, "uid": kMOUID,
            "private": 0, "stck": 1, "drift": 1,
            "subdevices": [
                ["uid": masterUID, "drift": 0],
                ["uid": secondUID, "drift": 1]
            ],
            "master": masterUID
        ]
    }
    var aggID: AudioDeviceID = 0
    let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
    if st == noErr { return aggID }
    fputs("Error: create aggregate device failed (\(st))\n", stderr)
    return nil
}

func destroyDevice(_ id: AudioDeviceID) -> Bool {
    AudioHardwareDestroyAggregateDevice(id) == noErr
}

// 清理之前遗留的多输出设备
func cleanup() {
    for id in allDeviceIDs() {
        if deviceUID(id) == kMOUID || deviceName(id) == kMOName {
            let _ = destroyDevice(id)
        }
    }
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    fputs("""
    audio-multi-output - 会议录制音频设备管理工具

    Commands:
      list                 列出所有输出设备 (name|uid|id)
      default-output-uid   当前默认输出设备 UID
      default-output-name  当前默认输出设备名称
      default-output-id    当前默认输出设备 ID
      default-input-name   当前默认输入设备名称
      blackhole-uid        BlackHole 设备 UID
      create <m-uid> <s-uid>  创建多输出设备 (master + secondary)
      destroy <device-id>  销毁聚合设备
      set-default <id>     设置默认输出设备
      find-uid <uid>       通过 UID 查找设备 ID
      cleanup              清理遗留的 Meeting Multi-Output 设备

    """, stderr)
    exit(1)
}

switch cmd {
case "list":
    for id in allDeviceIDs() where outputChannels(id) > 0 {
        print("\(deviceName(id) ?? "?")|\(deviceUID(id) ?? "?")|\(id)")
    }
case "default-output-uid":
    guard let id = defaultDevice(output: true), let uid = deviceUID(id) else {
        fputs("Error: no default output\n", stderr); exit(1) }
    print(uid)
case "default-output-name":
    guard let id = defaultDevice(output: true), let name = deviceName(id) else {
        fputs("Error: no default output\n", stderr); exit(1) }
    print(name)
case "default-output-id":
    guard let id = defaultDevice(output: true) else {
        fputs("Error: no default output\n", stderr); exit(1) }
    print(id)
case "default-input-name":
    guard let id = defaultDevice(output: false), let name = deviceName(id) else {
        fputs("Error: no default input\n", stderr); exit(1) }
    print(name)
case "blackhole-uid":
    guard let uid = findBlackHoleUID() else {
        fputs("Error: BlackHole not found\n", stderr); exit(1) }
    print(uid)
case "create":
    guard args.count >= 3 else {
        fputs("Usage: create <master-uid> <secondary-uid> [--no-drift]\n", stderr); exit(1) }
    let noDrift = args.contains("--no-drift")
    guard let id = createMultiOutput(masterUID: args[1], secondUID: args[2], noDrift: noDrift) else { exit(1) }
    print(id)
case "destroy":
    guard args.count >= 2, let n = UInt32(args[1]) else {
        fputs("Usage: destroy <device-id>\n", stderr); exit(1) }
    if !destroyDevice(n) { fputs("Warning: destroy failed\n", stderr) }
case "set-default":
    guard args.count >= 2, let n = UInt32(args[1]) else {
        fputs("Usage: set-default <device-id>\n", stderr); exit(1) }
    if !setDefaultOutput(n) { fputs("Error: set default failed\n", stderr); exit(1) }
case "find-uid":
    guard args.count >= 2 else {
        fputs("Usage: find-uid <uid>\n", stderr); exit(1) }
    guard let id = findByUID(args[1]) else {
        fputs("Error: device not found\n", stderr); exit(1) }
    print(id)
case "cleanup":
    cleanup()
case "set-sample-rate":
    guard args.count >= 3, let n = UInt32(args[1]), let r = Float64(args[2]) else {
        fputs("Usage: set-sample-rate <device-id> <rate>\n", stderr); exit(1) }
    if !setSampleRate(n, r) { fputs("Error: set sample rate failed\n", stderr); exit(1) }
case "get-sample-rate":
    guard args.count >= 2, let n = UInt32(args[1]) else {
        fputs("Usage: get-sample-rate <device-id>\n", stderr); exit(1) }
    guard let r = getSampleRate(n) else {
        fputs("Error: get sample rate failed\n", stderr); exit(1) }
    print(Int(r))
default:
    fputs("Unknown command: \(cmd)\n", stderr); exit(1)
}
