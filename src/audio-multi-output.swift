import CoreAudio
import Foundation
import IOKit.pwr_mgt

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

// MARK: - sleep-watch：系统休眠前结束录音，唤醒后发通知

// IOKit 的消息常量是函数式宏（iokit_common_msg），Swift 导入不了，按定义手算：
// sys_iokit(0xE0000000) | sub_iokit_common(0) | message
let kMsgCanSystemSleep: UInt32 = 0xE000_0270
let kMsgSystemWillSleep: UInt32 = 0xE000_0280
let kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300

// IOKit 回调是 C 函数指针，不能捕获上下文，状态放全局
var swRootPort: io_connect_t = 0
var swMeetap = ""
var swSleepHandled = false

/// 同步执行 meetap 子命令，最多等 timeout 秒（休眠回调里不能无限阻塞，系统上限约 30s）
func swRunMeetap(_ arguments: [String], timeout: TimeInterval) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: swMeetap)
    p.arguments = arguments
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    do { try p.run() } catch {
        fputs("sleep-watch: failed to run \(swMeetap): \(error)\n", stderr); return }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(100_000) }
    if p.isRunning {
        fputs("sleep-watch: \(arguments.joined(separator: " ")) timed out after \(Int(timeout))s\n", stderr)
    }
}

func swHandleWillSleep() {
    guard !swSleepHandled else { return }
    swRunMeetap(["stop", "--sleep"], timeout: 25)
    swSleepHandled = true
}

func swHandlePoweredOn() {
    guard swSleepHandled else { return }
    swRunMeetap(["_wake-notify"], timeout: 10)
    exit(0)
}

func runSleepWatch(meetap: String, pidFile: String, simulate: Bool) {
    swMeetap = meetap
    if simulate {   // 测试用：不注册 IOKit，直接走一遍休眠→唤醒
        swHandleWillSleep()
        swHandlePoweredOn()
        exit(0)
    }
    var notifyPort: IONotificationPortRef?
    var notifier: io_object_t = 0
    swRootPort = IORegisterForSystemPower(nil, &notifyPort, { _, _, messageType, messageArgument in
        switch messageType {
        case kMsgCanSystemSleep:
            IOAllowPowerChange(swRootPort, Int(bitPattern: messageArgument))
        case kMsgSystemWillSleep:
            swHandleWillSleep()
            IOAllowPowerChange(swRootPort, Int(bitPattern: messageArgument))
        case kMsgSystemHasPoweredOn:
            swHandlePoweredOn()
        default:
            break
        }
    }, &notifier)
    guard swRootPort != 0, let port = notifyPort else {
        fputs("sleep-watch: IORegisterForSystemPower failed\n", stderr); exit(1) }
    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                       .defaultMode)
    // 录音被手动 stop / 自停后 PID 文件消失 → 退出。处理过休眠后不再检查：
    // stop --sleep 本身会删 PID 文件，watcher 要活到唤醒发通知
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        if !swSleepHandled && !FileManager.default.fileExists(atPath: pidFile) { exit(0) }
    }
    CFRunLoopRun()
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
      sleep-watch <meetap> <pid-file>  休眠前执行 meetap stop --sleep，唤醒后 _wake-notify

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
case "sleep-watch":
    guard args.count >= 3 else {
        fputs("Usage: sleep-watch <meetap-path> <ffmpeg-pid-file> [--simulate-sleep]\n", stderr); exit(1) }
    runSleepWatch(meetap: args[1], pidFile: args[2], simulate: args.contains("--simulate-sleep"))
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
