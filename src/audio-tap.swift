import AudioToolbox
import CoreAudio
import Foundation

// meetap audio-tap — 基于 macOS 14.4+ Core Audio Process Tap 的系统音频旁路捕获
// 不切换系统输出设备、不需要 BlackHole，用户听到原声。
//
// 子命令:
//   tap-supported             检测系统是否支持 Process Tap（≥14.4 输出 "yes" exit 0）
//   tap-rate                  打印默认输出设备标称采样率（整数 Hz，tap 采样率跟随此设备）
//   tap-start [--duration N]  捕获系统音频，Float32 LE mono PCM 写 stdout
//                             ffmpeg 读法: ffmpeg -f f32le -ar <rate> -ac 1 -i pipe:0 ...
//
// tap-start 启动后 stderr 输出 "SAMPLE_RATE=<rate>" 等元信息（数据只走 stdout）。
// SIGINT/SIGTERM 时显式销毁 aggregate device 与 tap（防止残留设备出现在音频 MIDI 设置）。
//
// 权限说明: 首次创建 tap 时 macOS 自动弹 TCC 系统音频录制授权框（以终端 App 名义）。
// 用户拒绝时 tap 不报错而是输出静音（全 0）——这是 macOS 的行为，无可靠 API 预检。

// MARK: - CoreAudio 基础工具

func defaultOutputDevice() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var id: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
        id != kAudioObjectUnknown else { return nil }
    return id
}

func deviceUID(_ id: AudioDeviceID) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var val: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &val) == noErr,
          let v = val else { return nil }
    return v as String
}

func nominalSampleRate(_ id: AudioDeviceID) -> Float64? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return nil }
    return rate
}

// MARK: - stdout 写入（IO 回调线程内直接 write；管道 64KB 缓冲足够容纳数秒音频）

// 写失败（如 ffmpeg 退出导致 EPIPE）时置位，由主线程负责清理退出
let writeFailedFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

func writeAll(fd: Int32, data: UnsafeRawPointer, count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let n = write(fd, data.advanced(by: offset), count - offset)
        if n < 0 {
            if errno == EINTR { continue }
            return false  // EPIPE 等：下游已关闭
        }
        offset += n
    }
    return true
}

// MARK: - Process Tap 捕获（macOS 14.4+）

struct TapError: Error { let message: String; init(_ m: String) { message = m } }

@available(macOS 14.4, *)
final class TapCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private let ioQueue = DispatchQueue(label: "meetap.audio-tap.io")

    private(set) var sampleRate: Float64 = 0
    private(set) var channels: UInt32 = 1

    // 读取 tap 的实际流格式（采样率跟随被 tap 的设备，不能写死 48000）
    private func readTapFormat() -> AudioStreamBasicDescription? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr else { return nil }
        return asbd
    }

    func start() throws {
        // 1. 默认输出设备（tap 监听目标）
        guard let outDev = defaultOutputDevice(), let outUID = deviceUID(outDev) else {
            throw TapError("cannot get default output device")
        }

        // 2. 创建 mono global tap（排除进程列表为空 = 捕获全部系统音）
        //    mono 全局 tap 对系统音捕获更可靠（meetily 验证）
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        desc.name = "meetap-tap"
        desc.isPrivate = true
        var tid = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tid)
        guard st == noErr, tid != kAudioObjectUnknown else {
            throw TapError("AudioHardwareCreateProcessTap failed (status \(st))")
        }
        tapID = tid

        if let asbd = readTapFormat() {
            sampleRate = asbd.mSampleRate
            channels = asbd.mChannelsPerFrame
        } else {
            // 兜底：跟随默认输出设备
            sampleRate = nominalSampleRate(outDev) ?? 48000
            channels = 1
        }

        // 3. 创建 aggregate device —— 关键防回声结构（meetily 血泪教训）：
        //    只放 tap_list，绝不放 sub_device_list（同时放会把系统音捕获两次 → 回声）。
        //    main_sub_device 仍需设为输出设备 UID（告诉系统 tap 跟随哪个设备）。
        let aggUID = UUID().uuidString
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "meetap-audio-tap",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // 注意：这里刻意没有 kAudioAggregateDeviceSubDeviceListKey
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard st == noErr, aggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw TapError("AudioHardwareCreateAggregateDevice failed (status \(st))")
        }
        aggregateID = aggID

        // 4. IO proc：从回调拿 PCM，直接写 stdout。
        //    mono tap → 单 buffer Float32；管道写通常远快于实时音频速率，不会阻塞回调。
        var pid: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&pid, aggregateID, ioQueue) {
            _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard abl.count > 0, !writeFailedFlag.pointee else { return }
            let buf = abl[0]
            guard let data = buf.mData, buf.mDataByteSize > 0 else { return }
            if !writeAll(fd: 1, data: data, count: Int(buf.mDataByteSize)) {
                // 下游（ffmpeg）已退出：置位并交给主线程清理，不在实时线程里做重活
                writeFailedFlag.pointee = true
                DispatchQueue.main.async { cleanupAndExit(0) }
            }
        }
        guard st == noErr, let createdPid = pid else {
            cleanup()
            throw TapError("AudioDeviceCreateIOProcIDWithBlock failed (status \(st))")
        }
        procID = createdPid

        // 5. 启动采集
        st = AudioDeviceStart(aggregateID, procID)
        guard st == noErr else {
            cleanup()
            throw TapError("AudioDeviceStart failed (status \(st))")
        }
        running = true
    }

    // 显式销毁所有 CoreAudio 对象（防残留；进程被 kill -9 时系统也会兜底回收）
    func cleanup() {
        if running, let p = procID {
            AudioDeviceStop(aggregateID, p)
            running = false
        }
        if let p = procID {
            AudioDeviceDestroyIOProcID(aggregateID, p)
            procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

// 全局 capture 引用，供信号处理/异常路径统一清理
var activeCapture: AnyObject? = nil

func cleanupAndExit(_ code: Int32) -> Never {
    if #available(macOS 14.4, *) {
        (activeCapture as? TapCapture)?.cleanup()
    }
    exit(code)
}

// MARK: - 子命令实现

func runTapSupported() -> Never {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    let versionOK = v.majorVersion > 14 || (v.majorVersion == 14 && v.minorVersion >= 4)
    guard versionOK else {
        print("unsupported: macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) < 14.4")
        exit(1)
    }
    if #available(macOS 14.4, *) {
        // API 可用性探测：确认能拿到默认输出设备（tap 创建留到 tap-start，避免提前弹权限框）
        guard defaultOutputDevice() != nil else {
            print("unsupported: no default output device")
            exit(1)
        }
        print("yes")
        exit(0)
    } else {
        print("unsupported: binary built without macOS 14.4 Process Tap API")
        exit(1)
    }
}

func runTapRate() -> Never {
    guard let dev = defaultOutputDevice(), let rate = nominalSampleRate(dev) else {
        fputs("Error: cannot get default output device sample rate\n", stderr)
        exit(1)
    }
    print(Int(rate))
    exit(0)
}

func runTapStart(duration: Double?) -> Never {
    guard #available(macOS 14.4, *) else {
        fputs("Error: Process Tap requires macOS 14.4+\n", stderr)
        exit(1)
    }

    writeFailedFlag.pointee = false
    signal(SIGPIPE, SIG_IGN)  // 管道断开由 write 返回 EPIPE 处理，不让信号杀进程

    let capture = TapCapture()
    activeCapture = capture
    do {
        try capture.start()
    } catch let err as TapError {
        fputs("Error: \(err.message)\n", stderr)
        cleanupAndExit(1)
    } catch {
        fputs("Error: \(error)\n", stderr)
        cleanupAndExit(1)
    }

    // 元信息走 stderr（stdout 只有 PCM 数据），供调用方构造 ffmpeg 参数
    fputs("SAMPLE_RATE=\(Int(capture.sampleRate))\n", stderr)
    fputs("CHANNELS=\(capture.channels)\n", stderr)
    fputs("FORMAT=f32le\n", stderr)

    // SIGINT/SIGTERM → 显式清理后退出（用 DispatchSource，避免在信号处理器里做非安全调用）
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSrc.setEventHandler { cleanupAndExit(0) }
    sigintSrc.resume()
    let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSrc.setEventHandler { cleanupAndExit(0) }
    sigtermSrc.resume()

    if let d = duration {
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { cleanupAndExit(0) }
    }

    dispatchMain()
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    fputs("""
    audio-tap - macOS 14.4+ Process Tap 系统音频捕获工具

    Commands:
      tap-supported             检测 Process Tap 是否可用（yes / 原因）
      tap-rate                  打印默认输出设备采样率（Hz）
      tap-start [--duration N]  捕获系统音频，Float32 LE mono PCM 写 stdout
                                （SIGINT/SIGTERM 停止并清理）

    """, stderr)
    exit(1)
}

switch cmd {
case "tap-supported":
    runTapSupported()
case "tap-rate":
    runTapRate()
case "tap-start":
    var duration: Double? = nil
    var i = 1
    while i < args.count {
        if args[i] == "--duration", i + 1 < args.count, let d = Double(args[i + 1]), d > 0 {
            duration = d
            i += 2
        } else {
            fputs("Usage: tap-start [--duration N]\n", stderr)
            exit(1)
        }
    }
    runTapStart(duration: duration)
default:
    fputs("Unknown command: \(cmd)\n", stderr)
    exit(1)
}
