import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// meetap audio-tap — 基于 macOS 14.4+ Core Audio Process Tap 的系统音频旁路捕获
// 不切换系统输出设备、不需要 BlackHole，用户听到原声。
//
// 子命令:
//   tap-supported             检测系统是否支持 Process Tap（≥14.4 输出 "yes" exit 0）
//   tap-rate                  打印默认输出设备标称采样率（整数 Hz，tap 采样率跟随此设备）
//   tap-start [--duration N]  捕获系统音频，Float32 LE mono PCM 写 stdout
//                             ffmpeg 读法: ffmpeg -f f32le -ar <rate> -ac 1 -i pipe:0 ...
//   app-audio-state [--all]   列出正在做音频 IO 的进程（会议自动检测用，不建 tap 不弹权限框）
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

// MARK: - 进程音频状态（CoreAudio Process 对象，macOS 14+）

// 与 Process Tap 是两套东西：这里只「读属性」，不建 tap、不采样，
// 因此不触发 TCC 系统音频授权框（tap 那条路会弹，见文件头权限说明），
// 单次枚举实测约 0.2s，可以放心 15s 轮询一次。

func processObjectList() -> [AudioObjectID]? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
        size > 0 else { return nil }
    var objs = [AudioObjectID](repeating: 0,
        count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objs) == noErr
        else { return nil }
    return objs
}

// 返回 nil 与返回 0 语义不同：nil = 这套属性在本系统上问不出来（老系统），
// 调用方靠它判断整个判据是否可信；0 = 确认没有 IO。
func processFlag(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: sel,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(obj, &addr) else { return nil }
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

func processPID(_ obj: AudioObjectID) -> pid_t? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var v: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

func processBundleID(_ obj: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    // 文档明确 caller 负责 release：用 Unmanaged 接，takeRetainedValue 平掉 +1。
    // 直接用 CFString? 接会吃一个 Swift 内存管理警告。
    var raw: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &raw) {
        AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
    }
    guard st == noErr, let u = raw else { return "-" }
    let s = u.takeRetainedValue() as String
    return s.isEmpty ? "-" : s
}

func processExecPath(_ pid: pid_t) -> String {
    // 会议 App 用 helper 进程做音频（Slack Helper / Teams WebView / Lark Helper），
    // 光看 bundleID 认不出来（com.microsoft.teams2 里没有 "Microsoft Teams"），
    // 所以必须给出可执行文件路径，让调用方用同一份 App 正则去匹配。
    var buf = [CChar](repeating: 0, count: 4096)
    let n = buf.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
    guard n > 0 else { return "-" }   // 别人家的进程可能 EPERM，不算错误
    return String(cString: buf)
}

// MARK: - stdout 写入（IO 回调线程内直接 write；管道 64KB 缓冲足够容纳数秒音频）

// 写失败（如 ffmpeg 退出导致 EPIPE）时置位，由主线程负责清理退出
let writeFailedFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

// 电平表（--level-file / --mic-level-file）：IO 回调累计峰值+平方和，
// 主队列定时器每 0.4s 写 "峰值dBFS RMSdBFS" 两列到文件。
// 峰值供静音检测（阈值标定基于峰值）；RMS 供波形显示——峰值在连续
// 讲话时恒定顶格（每窗都摸到最大音节），RMS 跟随音节/停顿自然起伏。
let meterLock = NSLock()
var meterPeak: Float = 0        // 系统音峰值
var meterSumSq: Double = 0      // 系统音平方和（算 RMS）
var meterCount: Int = 0
var micMeterPeak: Float = 0     // 麦克风峰值
var micMeterSumSq: Double = 0
var micMeterCount: Int = 0
var meterTimer: DispatchSourceTimer? = nil

// MARK: - 麦克风采集与混音（--with-mic，借鉴 meetily ring-buffer 混音架构）
// meetily 经验（core_audio.rs / pipeline.rs, MIT）：绝不让外部进程（ffmpeg
// avfoundation）碰音频设备——tap 采系统音、进程内采麦克风、ring buffer 混音、
// 单路 PCM 输出。彻底消灭设备抢占/枚举竞态一类问题。

// 麦克风环形缓冲：mic IO 回调写入，tap IO 回调按需读出（tap 作主时钟）
final class MicRing {
    private var buf: [Float]
    private var readIdx = 0, writeIdx = 0, count = 0
    private let lock = NSLock()
    init(capacity: Int) { buf = [Float](repeating: 0, count: capacity) }
    func write(_ data: UnsafePointer<Float>, _ n: Int, stride: Int) {
        lock.lock(); defer { lock.unlock() }
        var i = 0
        while i < n {
            buf[writeIdx] = data[i]
            writeIdx = (writeIdx + 1) % buf.count
            if count < buf.count { count += 1 } else { readIdx = (readIdx + 1) % buf.count }
            i += stride
        }
    }
    func read(into out: inout [Float], _ n: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let take = min(n, count)
        for i in 0..<take {
            out[i] = buf[readIdx]
            readIdx = (readIdx + 1) % buf.count
        }
        count -= take
        return take
    }
}

func defaultInputDevice() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var id: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
        id != kAudioObjectUnknown else { return nil }
    return id
}

// 麦克风采集：默认输入设备上挂 IO proc，Float32 首声道写 ring buffer
final class MicCapture {
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private let ioQueue = DispatchQueue(label: "meetap.audio-tap.mic")
    let ring = MicRing(capacity: 96000)  // 2s @48k
    private(set) var sampleRate: Float64 = 0

    func start() throws {
        guard let dev = defaultInputDevice() else {
            throw TapError("cannot get default input device")
        }
        deviceID = dev
        sampleRate = nominalSampleRate(dev) ?? 0

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &asbd)
        // 交错多声道时按 stride 取首声道；CoreAudio 输入默认 Float32
        let channels = max(1, Int(asbd.mChannelsPerFrame))

        var pid: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&pid, dev, ioQueue) {
            [ring] _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard abl.count > 0 else { return }
            let buf = abl[0]
            guard let data = buf.mData, buf.mDataByteSize > 0 else { return }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let fp = data.assumingMemoryBound(to: Float.self)
            let stride = max(1, Int(buf.mNumberChannels > 0 ? buf.mNumberChannels : UInt32(channels)))
            ring.write(fp, n, stride: stride)
            var peak: Float = 0
            var sumsq: Double = 0
            var cnt = 0
            var i = 0
            while i < n {
                let v = fp[i]; let a = abs(v)
                if a > peak { peak = a }
                sumsq += Double(v) * Double(v); cnt += 1
                i += stride
            }
            meterLock.lock()
            if peak > micMeterPeak { micMeterPeak = peak }
            micMeterSumSq += sumsq; micMeterCount += cnt
            meterLock.unlock()
        }
        guard st == noErr, let createdPid = pid else {
            throw TapError("mic AudioDeviceCreateIOProcIDWithBlock failed (status \(st))")
        }
        procID = createdPid
        let st2 = AudioDeviceStart(dev, createdPid)
        guard st2 == noErr else {
            AudioDeviceDestroyIOProcID(dev, createdPid)
            procID = nil
            throw TapError("mic AudioDeviceStart failed (status \(st2))")
        }
        running = true
    }

    func cleanup() {
        if running, let p = procID { AudioDeviceStop(deviceID, p); running = false }
        if let p = procID { AudioDeviceDestroyIOProcID(deviceID, p); procID = nil }
    }
}

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
    var micRing: MicRing? = nil  // --with-mic 时由 main 注入；tap 回调里混音
    var micSampleRate: Float64 = 0  // 麦克风标称采样率；与 tap 采样率不同时需重采样对齐

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
        let ring = micRing
        // 麦克风与 tap 标称采样率可能不一致（且会在不同会话间波动，例如
        // 24000 vs 48000）：ring 只搬字节不感知采样率，若直接等量读取相加，
        // 混入的麦克风人声会按错误时间轴对齐，听感糊/断续。这里预先算好
        // 比例，混音时按比例线性插值把麦克风采样对齐到 tap 的时钟上。
        let micRatio: Double = (ring != nil && micSampleRate > 0 && sampleRate > 0)
            ? micSampleRate / sampleRate : 1.0
        var micScratch: [Float] = []
        st = AudioDeviceCreateIOProcIDWithBlock(&pid, aggregateID, ioQueue) {
            _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard abl.count > 0, !writeFailedFlag.pointee else { return }
            let buf = abl[0]
            guard let data = buf.mData, buf.mDataByteSize > 0 else { return }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let fp = data.assumingMemoryBound(to: Float.self)
            // 电平表：记录本窗口系统音峰值 + 平方和（RMS 用）
            var peak: Float = 0
            var sumsq: Double = 0
            for i in 0..<n {
                let v = fp[i]; let a = abs(v)
                if a > peak { peak = a }
                sumsq += Double(v) * Double(v)
            }
            meterLock.lock()
            if peak > meterPeak { meterPeak = peak }
            meterSumSq += sumsq; meterCount += n
            meterLock.unlock()

            // --with-mic：tap 作主时钟，从 ring 按 micRatio 线性插值取出与 tap
            // 时钟对齐的麦克风样本叠加（进程内混音；相加 + 削顶防爆音）。
            // micRatio == 1 时插值退化为逐样本直取，等价于原直接相加逻辑。
            if let ring = ring {
                let need = Int((Double(n) * micRatio).rounded(.up)) + 1
                if micScratch.count < need {
                    micScratch = [Float](repeating: 0, count: need)
                }
                let got = ring.read(into: &micScratch, need)
                if got > 0 {
                    // usable：ring 欠载（got < need）时按实际能覆盖的插值范围
                    // 裁剪输出样本数，避免对超出数据范围的尾部做错误外插。
                    let usable = min(n, Int(Double(got - 1) / micRatio) + 1)
                    for i in 0..<usable {
                        let srcPos = Double(i) * micRatio
                        let idx0 = min(Int(srcPos), got - 1)
                        let idx1 = min(idx0 + 1, got - 1)
                        let frac = Float(srcPos - Double(idx0))
                        let sample = micScratch[idx0] * (1 - frac) + micScratch[idx1] * frac
                        fp[i] = max(-1.0, min(1.0, fp[i] + sample))
                    }
                }
            }

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
    activeMic?.cleanup()
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
    guard let outDev = defaultOutputDevice() else {
        fputs("Error: cannot get default output device\n", stderr)
        exit(1)
    }
    // 输出设备「标称采样率」不总等于 Process Tap 实际协商到的采样率
    // （二者曾在同一台机器上分别读到 24000 / 48000，导致 tap-start
    // 真实吐出的 PCM 与这里报给 ffmpeg -ar 的值不一致，录音整体变速/变调）。
    // 因此优先临时建一个 tap，直接读 kAudioTapPropertyFormat——与
    // TapCapture.start() 的 readTapFormat() 同源，用完立即销毁。
    if #available(macOS 14.4, *) {
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        desc.isPrivate = true
        var tid = AudioObjectID(kAudioObjectUnknown)
        if AudioHardwareCreateProcessTap(desc, &tid) == noErr, tid != kAudioObjectUnknown {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let ok = AudioObjectGetPropertyData(tid, &addr, 0, nil, &size, &asbd) == noErr
                && asbd.mSampleRate > 0
            let rate = ok ? asbd.mSampleRate : (nominalSampleRate(outDev) ?? 48000)
            AudioHardwareDestroyProcessTap(tid)
            print(Int(rate))
            exit(0)
        }
    }
    guard let rate = nominalSampleRate(outDev) else {
        fputs("Error: cannot get default output device sample rate\n", stderr)
        exit(1)
    }
    print(Int(rate))
    exit(0)
}

// 每个正在做音频 IO 的进程输出一行「<in> <out> <pid> <bundleID> <可执行文件路径>」。
// 路径含空格所以放最后；bundleID/路径取不到时写 "-"，否则字段会错位（调用方按
// 固定 5 段解析）。
//
// 退出码是这个子命令的关键契约：
//   0 = 结果可信（stdout 为空表示「已确认没有进程在做音频 IO」）
//   1 = 无法判断，调用方必须降级到别的判据
func runAppAudioState(all: Bool) -> Never {
    // 守卫 ①：版本下限。Process 对象的 piri/piro 是 macOS 14 才有的。
    let v = ProcessInfo.processInfo.operatingSystemVersion
    guard v.majorVersion >= 14 else {
        fputs("unsupported: macOS \(v.majorVersion) < 14\n", stderr)
        exit(1)
    }
    // 守卫 ②：拿不到进程列表 → 无法判断
    guard let objs = processObjectList(), !objs.isEmpty else {
        fputs("unsupported: cannot read process object list\n", stderr)
        exit(1)
    }
    var answered = 0
    var lines: [String] = []
    for o in objs {
        let inFlag = processFlag(o, kAudioProcessPropertyIsRunningInput)
        let outFlag = processFlag(o, kAudioProcessPropertyIsRunningOutput)
        if inFlag != nil || outFlag != nil { answered += 1 }
        let i = inFlag ?? 0, ou = outFlag ?? 0
        guard all || i == 1 || ou == 1 else { continue }
        guard let pid = processPID(o) else { continue }
        lines.append("\(i) \(ou) \(pid) \(processBundleID(o)) \(processExecPath(pid))")
    }
    // 守卫 ③：一个进程都答不出 piri/piro，说明这套属性在本系统上不可用。
    // 此时若照常 exit 0 输出空，调用方会把「查不到」误当成「确认没有音频活动」，
    // 整个检测会静默失效——必须报 1 让它降级。
    guard answered > 0 else {
        fputs("unsupported: process IO-state properties unavailable\n", stderr)
        exit(1)
    }
    for line in lines { print(line) }
    exit(0)
}

var activeMic: MicCapture? = nil

func runTapStart(duration: Double?, levelFile: String?, micLevelFile: String?, withMic: Bool) -> Never {
    guard #available(macOS 14.4, *) else {
        fputs("Error: Process Tap requires macOS 14.4+\n", stderr)
        exit(1)
    }

    writeFailedFlag.pointee = false
    signal(SIGPIPE, SIG_IGN)  // 管道断开由 write 返回 EPIPE 处理，不让信号杀进程

    let capture = TapCapture()
    activeCapture = capture

    // 麦克风先启动（失败不致命——静默降级为纯系统音，会议不能不录）
    if withMic {
        let mic = MicCapture()
        do {
            try mic.start()
            activeMic = mic
            capture.micRing = mic.ring
            capture.micSampleRate = mic.sampleRate
            fputs("MIC=on rate=\(Int(mic.sampleRate))\n", stderr)
        } catch {
            fputs("MIC=off (\(error))\n", stderr)
        }
    }

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

    // 电平表：每 0.4s 写 "峰值dBFS RMSdBFS" 到文件（原子替换，读方不会读到半行）
    if levelFile != nil || micLevelFile != nil {
        func writeLevel(_ path: String, _ peak: Float, _ sumsq: Double, _ count: Int) {
            let peakDb = peak > 0 ? max(-91.0, 20.0 * log10(Double(peak))) : -91.0
            let rms = count > 0 ? (sumsq / Double(count)).squareRoot() : 0
            let rmsDb = rms > 0 ? max(-91.0, 20.0 * log10(rms)) : -91.0
            let line = String(format: "%.1f %.1f\n", peakDb, rmsDb)
            let tmp = path + ".tmp"
            try? line.write(toFile: tmp, atomically: false, encoding: .utf8)
            _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                withItemAt: URL(fileURLWithPath: tmp))
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.4, repeating: 0.4)
        timer.setEventHandler {
            meterLock.lock()
            let sysPeak = meterPeak; meterPeak = 0
            let sysSumSq = meterSumSq; meterSumSq = 0
            let sysCount = meterCount; meterCount = 0
            let micPeak = micMeterPeak; micMeterPeak = 0
            let micSumSq = micMeterSumSq; micMeterSumSq = 0
            let micCount = micMeterCount; micMeterCount = 0
            meterLock.unlock()
            if let lf = levelFile { writeLevel(lf, sysPeak, sysSumSq, sysCount) }
            if let mlf = micLevelFile { writeLevel(mlf, micPeak, micSumSq, micCount) }
        }
        timer.resume()
        meterTimer = timer
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
      tap-start [--duration N] [--level-file PATH]
                                捕获系统音频，Float32 LE mono PCM 写 stdout
                                --level-file: 每 0.4s 写当前电平(dBFS)到文件，
                                供波形显示读取（SIGINT/SIGTERM 停止并清理）
      app-audio-state [--all]   列出正在做音频 IO 的进程，每行
                                "<in> <out> <pid> <bundleID> <可执行文件路径>"
                                exit 0 = 结果可信（空输出=确认无活动）
                                exit 1 = 无法判断，调用方须降级
                                --all: 不过滤，列出全部进程（排查用）

    """, stderr)
    exit(1)
}

switch cmd {
case "tap-supported":
    runTapSupported()
case "tap-rate":
    runTapRate()
case "app-audio-state":
    var all = false
    for a in args.dropFirst() {
        guard a == "--all" else {
            fputs("Usage: app-audio-state [--all]\n", stderr)
            exit(1)
        }
        all = true
    }
    runAppAudioState(all: all)
case "tap-start":
    var duration: Double? = nil
    var levelFile: String? = nil
    var micLevelFile: String? = nil
    var withMic = false
    var i = 1
    while i < args.count {
        if args[i] == "--duration", i + 1 < args.count, let d = Double(args[i + 1]), d > 0 {
            duration = d
            i += 2
        } else if args[i] == "--level-file", i + 1 < args.count {
            levelFile = args[i + 1]
            i += 2
        } else if args[i] == "--mic-level-file", i + 1 < args.count {
            micLevelFile = args[i + 1]
            i += 2
        } else if args[i] == "--with-mic" {
            withMic = true
            i += 1
        } else {
            fputs("Usage: tap-start [--duration N] [--with-mic] [--level-file PATH] [--mic-level-file PATH]\n", stderr)
            exit(1)
        }
    }
    runTapStart(duration: duration, levelFile: levelFile, micLevelFile: micLevelFile, withMic: withMic)
default:
    fputs("Unknown command: \(cmd)\n", stderr)
    exit(1)
}
