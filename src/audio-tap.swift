import AudioToolbox
import CoreAudio
import Foundation

// meetap audio-tap — 基于 macOS 14.4+ Core Audio Process Tap 的系统音频旁路捕获
// 不切换系统输出设备、不需要 BlackHole，用户听到原声。
//
// 子命令:
//   tap-supported             检测系统是否支持 Process Tap（≥14.4 输出 "yes" exit 0）
//   tap-rate                  打印默认输出设备标称采样率（整数 Hz，仅参考）
//   tap-format                打印 Process Tap 实际采样率（整数 Hz，采集/编码以此为准）
//   tap-start [--output-rate HZ] [--duration N] [--with-mic] [--level-file PATH] [--mic-level-file PATH]
//                             捕获系统音频（--with-mic 混入麦克风），Float32 LE mono PCM 写 stdout
//                             输出恒为 --output-rate（默认 48000）：tap、麦克风各自重采样到该率再混音，
//                             与设备实际采样率无关（蓝牙耳机通话模式麦克风只有 16k/24k）。
//                             ffmpeg 读法: ffmpeg -f f32le -ar <同一个 output-rate> -ac 1 -i pipe:0 ...
//   selftest-resample         重采样自检（合成信号，不碰音频设备）
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
// tap 回调最近一次触发的时刻（uptime ns，meterLock 保护），供 tap 卡死看门狗用
var tapLastNs: UInt64 = 0
// 各源首次送达数据的时刻（uptime ns，meterLock 保护），主队列据此写诊断日志。
// 蓝牙耳机开麦后切通话模式要时间，偶发数秒不出数据，日志里要看得见。
var tapFirstNs: UInt64 = 0
var micFirstNs: UInt64 = 0
var micLastNs: UInt64 = 0

// MARK: - 麦克风采集与混音（--with-mic，借鉴 meetily ring-buffer 混音架构）
// meetily 经验（core_audio.rs / pipeline.rs, MIT）：绝不让外部进程（ffmpeg
// avfoundation）碰音频设备——tap 采系统音、进程内采麦克风、ring buffer 混音、
// 单路 PCM 输出。彻底消灭设备抢占/枚举竞态一类问题。

// 通用音频环形缓冲：IO 回调写入，输出写线程按需读出。系统音、麦克风各一个。
// 满了覆盖最旧样本，覆盖量计入该路的丢弃统计。
final class AudioRing {
    private var buf: [Float]
    private var readIdx = 0, writeIdx = 0, count = 0
    private var overflowCount = 0
    private let lock = NSLock()
    init(capacity: Int) { buf = [Float](repeating: 0, count: capacity) }
    var available: Int { lock.lock(); defer { lock.unlock() }; return count }
    func write(_ data: UnsafePointer<Float>, _ n: Int, stride: Int) {
        lock.lock(); defer { lock.unlock() }
        var i = 0
        while i < n {
            buf[writeIdx] = data[i]
            writeIdx = (writeIdx + 1) % buf.count
            if count < buf.count { count += 1 } else { readIdx = (readIdx + 1) % buf.count; overflowCount += 1 }
            i += stride
        }
    }
    // 读入调用方预分配的裸指针缓冲（不接收 inout [Float]：实时 tap 回调里
    // 用 Swift 数组会因 COW 检查/潜在分配而破坏实时安全，改用预分配 scratch）。
    func read(into out: UnsafeMutablePointer<Float>, _ n: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let take = min(n, count)
        for i in 0..<take {
            out[i] = buf[readIdx]
            readIdx = (readIdx + 1) % buf.count
        }
        count -= take
        return take
    }
    // 丢弃最旧的 n 个样本，返回实际丢弃数
    func discard(_ n: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let d = min(n, count)
        readIdx = (readIdx + d) % buf.count
        count -= d
        return d
    }
    // 取出并清零自上次以来的溢出（被覆盖）样本数
    func takeOverflow() -> Int {
        lock.lock(); defer { lock.unlock() }
        let o = overflowCount; overflowCount = 0
        return o
    }
}

// MARK: - 采样率转换
// 每个源在进 ring 之前都转到统一的输出采样率，ring 里永远是同一个采样率的样本，
// 才能按样本 1:1 混音。蓝牙耳机一开麦就切到通话模式（HFP），麦克风只有 16k/24k，
// 而 tap 由系统重采样、恒为 48k；不转换的话，24k 麦克风会让整段录音 2 倍速 + 升调
// （AirPods Pro 实录事故）。
// 用线性插值而不是 AudioConverter：墙钟同步要逐拍连续微调比例（adjust），
// AudioConverter 改比例要重设且自带内部延迟；线性插值零分配、可在 IO 回调里跑、
// 行为确定可单测。HFP 带宽本就 ≤12kHz，线性插值的高频衰减落在带外；tap 48k 在
// 水位死区内走直通，系统音不经插值。
final class LinearResampler {
    let outRate: Double
    private let lock = NSLock()
    private var inRateValue: Double
    private var adjustValue = 1.0
    // 到达统计（测实际输入速率用）：累计输入帧数、最近一次回调时刻、回调最大间隔
    private var rawFrames = 0
    private var lastCbNs: UInt64 = 0
    private var maxGapNs: UInt64 = 0
    // 插值状态（只在所属 IO 回调里访问）：上一批最后一个输入样本 prev 记作位置 0，
    // 本批第 i 个输入样本记作位置 i+1；pos 是下一个输出点的位置（单位：输入样本间隔）。
    private var prev: Float = 0
    private var pos: Double = 1
    private let scratchCap = 4096
    private let scratch: UnsafeMutablePointer<Float>

    init(inRate: Double, outRate: Double) {
        inRateValue = inRate
        self.outRate = outRate
        scratch = .allocate(capacity: scratchCap)
    }
    deinit { scratch.deallocate() }

    // 输入采样率（声明值）：设备自报，设备改采样率时由属性监听更新，实测偏差大时由测速改写
    var inRate: Double {
        get { lock.lock(); defer { lock.unlock() }; return inRateValue }
        set { lock.lock(); inRateValue = newValue; lock.unlock() }
    }
    // 水位控制的微调系数（1 = 不调），实际比例 = inRate × adjust / outRate
    var adjust: Double {
        get { lock.lock(); defer { lock.unlock() }; return adjustValue }
        set { lock.lock(); adjustValue = newValue; lock.unlock() }
    }

    var lastCallbackNs: UInt64 { lock.lock(); defer { lock.unlock() }; return lastCbNs }

    struct Arrival { let frames: Int; let lastNs: UInt64; let maxGapNs: UInt64 }
    // 读出到达统计，并清零回调最大间隔（下一个测速窗口重新计）
    func takeArrival() -> Arrival {
        lock.lock(); defer { lock.unlock() }
        let a = Arrival(frames: rawFrames, lastNs: lastCbNs, maxGapNs: maxGapNs)
        maxGapNs = 0
        return a
    }

    // 转换一批输入（交错多声道按 stride 取首声道），结果写进 ring。nowNs = 回调时刻
    func process(_ data: UnsafePointer<Float>, frames m: Int, stride: Int, into ring: AudioRing,
                 nowNs: UInt64) {
        guard m > 0 else { return }
        lock.lock()
        let rIn = inRateValue * adjustValue
        rawFrames += m
        if lastCbNs > 0 && nowNs > lastCbNs { maxGapNs = max(maxGapNs, nowNs - lastCbNs) }
        lastCbNs = nowNs
        lock.unlock()

        let last = data[(m - 1) * stride]
        if rIn <= 0 || rIn == outRate {
            ring.write(data, m * stride, stride: stride)
            prev = last; pos = 1
            return
        }
        let step = rIn / outRate
        let end = Double(m)
        var p = pos
        var k = 0
        while p <= end {
            let i = Int(p)
            let t = Float(p - Double(i))
            let a = i == 0 ? prev : data[(i - 1) * stride]
            // t > 0 时 p <= end 保证 i < m，右邻点 data[i] 一定在本批内
            scratch[k] = t == 0 ? a : a + (data[i * stride] - a) * t
            k += 1
            if k == scratchCap { ring.write(scratch, k, stride: 1); k = 0 }
            p += step
        }
        if k > 0 { ring.write(scratch, k, stride: 1) }
        prev = last
        pos = p - end
    }
}

let nominalRateAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyNominalSampleRate,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

// 监听设备采样率变化，变了就更新 resampler（录音途中蓝牙耳机切换音频模式等）。
// 返回监听 block，清理时传给 removeRateListener。
func addRateListener(_ dev: AudioObjectID, _ rs: LinearResampler, tag: String,
                     queue: DispatchQueue) -> AudioObjectPropertyListenerBlock? {
    let block: AudioObjectPropertyListenerBlock = { _, _ in
        guard let r = nominalSampleRate(dev), r > 0 else { return }
        let old = rs.inRate
        guard r != old else { return }
        rs.inRate = r
        fputs("\(tag)_RATE_CHANGED \(Int(old)) -> \(Int(r)) (resample to \(Int(rs.outRate)))\n", stderr)
    }
    var addr = nominalRateAddress
    return AudioObjectAddPropertyListenerBlock(dev, &addr, queue, block) == noErr ? block : nil
}

func removeRateListener(_ dev: AudioObjectID, _ block: AudioObjectPropertyListenerBlock?,
                        queue: DispatchQueue) {
    guard let b = block else { return }
    var addr = nominalRateAddress
    AudioObjectRemovePropertyListenerBlock(dev, &addr, queue, b)
}

// MARK: - 墙钟同步
// 输出以墙钟为准：OutputWriter 每拍按「墙钟应写帧数 − 已写帧数」写出，录音时长恒等于
// 真实时长。每一路源（tap / 麦克风）各自对齐到墙钟：
//   - 就绪：ring 攒够目标水位（120ms，吸收回调抖动）才开始取数，之前这一路出零（idle）
//   - 欠载：取数不够（切设备、回调卡顿）就先出零、攒回目标水位再继续（缺的记 pad）。
//     不靠微调比例慢慢补水位——那要一分多钟、期间这一路音高一直偏
//   - 断流：欠载后回调停了超过 250ms 视为这一路停了（系统没放声 / 麦克风断流 / 拔设备），
//     这段改记 idle
//   - 水位控制：平滑水位偏离目标超过 20ms 时按偏差微调重采样比例（最多 ±0.5%），只用来
//     吸收设备时钟与墙钟之间 ppm 级的漂移；水位超过 400ms 直接丢到目标水位（drop）
//   - 测速（CLOCK_DRIFT 保险丝）：每 2s 用 IO 回调时间戳实测输入速率，与声明采样率偏差
//     >2% 且连续两次一致 → 告警并改用实测速率。正常设备不该响；响了说明设备自报错了
// 设备报错、切换没被监听到、时钟漂移，都只表现为本路的补零 / 丢弃 / 告警，不改变时长。
final class Source {
    static let targetSec = 0.12, deadbandSec = 0.02, maxSec = 0.4
    static let gain = 0.05, maxAdjust = 0.005
    static let starveNs: UInt64 = 250_000_000
    static let maxCbGapNs: UInt64 = 100_000_000
    static let minWindowSec = 1.5
    static let driftThreshold = 0.02, driftAgree = 0.01
    static let standardRates: [Double] = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000]

    let name: String
    let ring: AudioRing
    let outRate: Double
    var log: (String) -> Void = { fputs($0 + "\n", stderr) }
    var originNs: UInt64 = 0      // 录音时间轴零点（OutputWriter 设置），日志里的时刻相对它
    private let target: Int
    private let lock = NSLock()   // 保护 rs 引用与统计量（写线程写、主线程读摘要）
    private var rs: LinearResampler?
    private var generation = 0
    // 以下只在写线程访问
    private var seenGeneration = -1
    private enum State { case idle, refilling, running }
    private var state = State.idle
    private var pendingGap = 0     // refilling 期间出的零：恢复了记 pad，断流了记 idle
    private var level = 0.0
    private var prevArrival: LinearResampler.Arrival?
    private var pendingDeviation: Double?
    private var measuredGeneration = -1
    private var reportedPad = 0, reportedDrop = 0
    // 统计（lock 保护）
    private var idleFrames = 0, padFrames = 0, dropFrames = 0, trimFrames = 0, driftFixes = 0
    private var curAdjust = 1.0

    init(name: String, ring: AudioRing, outRate: Double) {
        self.name = name; self.ring = ring; self.outRate = outRate
        target = Int(Self.targetSec * outRate)
    }

    // 采集端（含设备切换、tap 重建）挂上新的 resampler，测速从头开始
    func attach(_ r: LinearResampler) {
        lock.lock(); rs = r; generation += 1; lock.unlock()
    }

    // 写线程：取 n 帧到 out，不足补零
    func pull(_ n: Int, into out: UnsafeMutablePointer<Float>, now: UInt64) {
        lock.lock(); let r = rs, gen = generation; lock.unlock()
        if gen != seenGeneration { seenGeneration = gen; prevArrival = nil; pendingDeviation = nil }
        var idle = 0, pad = 0, drop = ring.takeOverflow(), trim = 0
        defer {
            lock.lock()
            idleFrames += idle; padFrames += pad; dropFrames += drop; trimFrames += trim
            curAdjust = r?.adjust ?? 1
            lock.unlock()
        }
        let avail = ring.available
        switch state {
        case .idle, .refilling:
            guard avail >= target else {
                out.update(repeating: 0, count: n)
                r?.adjust = 1
                if state == .idle { idle = n; return }
                pendingGap += n
                // 欠载后回调停了超过 250ms：这一路停了，不是短暂欠载
                let last = r?.lastCallbackNs ?? 0
                if last == 0 || (now > last && now - last > Self.starveNs) {
                    idle = pendingGap; pendingGap = 0; state = .idle
                }
                return
            }
            if state == .idle {
                // 首次/断流后就绪：积压（设备先于写线程启动、首包带缓存）裁到目标水位，延迟不累积
                if avail > target { trim = ring.discard(avail - target) }
            } else {
                pad = pendingGap
            }
            pendingGap = 0
            state = .running
            level = Double(ring.available)
        case .running:
            if avail > Int(Self.maxSec * outRate) {
                drop += ring.discard(avail - target)
                level = Double(target)
            }
        }
        let got = ring.read(into: out, n)
        if got < n {
            (out + got).update(repeating: 0, count: n - got)
            pad += n - got
            state = .refilling
            r?.adjust = 1
            return
        }
        // 水位控制：平滑水位（约 200ms 时间常数）偏离目标超出死区时微调比例。
        // 水位偏高 = 源比墙钟快 → 调大有效输入率 → 每个输入样本产出更少输出
        level += 0.05 * (Double(ring.available) - level)
        let err = (level - Double(target)) / outRate
        var adj = 1.0
        if abs(err) > Self.deadbandSec {
            let e = err > 0 ? err - Self.deadbandSec : err + Self.deadbandSec
            adj = 1 + max(-Self.maxAdjust, min(Self.maxAdjust, Self.gain * e))
        }
        r?.adjust = adj
    }

    // 写线程，每 2s：实测输入速率，与声明采样率比对
    func measure(now: UInt64) {
        lock.lock(); let r = rs, gen = generation; lock.unlock()
        guard let r else { return }
        if gen != measuredGeneration { measuredGeneration = gen; prevArrival = nil; pendingDeviation = nil }
        let a = r.takeArrival()
        defer { prevArrival = a }
        // 窗口有效：上个快照时已在出数据、整段连续交付（回调间隔都 <100ms）、此刻仍在交付
        guard let p = prevArrival, p.lastNs > 0, a.lastNs > p.lastNs, a.frames > p.frames,
              a.maxGapNs < Self.maxCbGapNs,
              a.lastNs >= now || now - a.lastNs < Self.maxCbGapNs else { pendingDeviation = nil; return }
        let dt = Double(a.lastNs - p.lastNs) / 1e9
        guard dt >= Self.minWindowSec else { pendingDeviation = nil; return }
        let measured = Double(a.frames - p.frames) / dt
        let declared = r.inRate
        let dev = measured / declared - 1
        guard abs(dev) > Self.driftThreshold else { pendingDeviation = nil; return }
        // 单个窗口可能碰上切换瞬间的突发，连续两个窗口一致才认定
        guard let pd = pendingDeviation, abs(pd - dev) < Self.driftAgree else { pendingDeviation = dev; return }
        pendingDeviation = nil
        let fixed = Self.standardRates.first { abs($0 / measured - 1) < 0.005 } ?? measured
        r.inRate = fixed
        lock.lock(); driftFixes += 1; lock.unlock()
        log(String(format: "WARNING: CLOCK_DRIFT %@ declared %.0f Hz but measured %.0f Hz (x%.3f), resampling from %.0f Hz (at %.1fs)",
                   name, declared, measured, measured / declared, fixed, Double(now - originNs) / 1e9))
    }

    struct Stats { let idle: Int, pad: Int, drop: Int, trim: Int, driftFixes: Int, adjust: Double, inRate: Double }
    func stats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return Stats(idle: idleFrames, pad: padFrames, drop: dropFrames, trim: trimFrames, driftFixes: driftFixes,
                     adjust: curAdjust, inRate: rs?.inRate ?? 0)
    }

    private func ms(_ frames: Int) -> Int { Int(Double(frames) * 1000 / outRate) }

    // 写线程，每 10s：补零/丢弃有新增才记一行
    func reportIfChanged() {
        let s = stats()
        guard s.pad != reportedPad || s.drop != reportedDrop else { return }
        log(String(format: "SYNC %@ pad=+%dms drop=+%dms level=%dms adj=%+.2f%% rate=%.0f",
                   name, ms(s.pad - reportedPad), ms(s.drop - reportedDrop),
                   ms(Int(level)), (s.adjust - 1) * 100, s.inRate))
        reportedPad = s.pad; reportedDrop = s.drop
    }

    func summaryLine() -> String {
        let s = stats()
        return String(format: "SYNC_SUMMARY %@ idle=%.1fs pad=%dms drop=%dms trim=%dms drift_fixes=%d rate=%.0f adj=%+.2f%%",
                      name, Double(s.idle) / outRate, ms(s.pad), ms(s.drop), ms(s.trim), s.driftFixes, s.inRate,
                      (s.adjust - 1) * 100)
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

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var val: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &val) == noErr, let v = val else { return "?" }
    return v.takeRetainedValue() as String
}

// 麦克风采集：默认输入设备上挂 IO proc，取首声道、重采样到输出采样率后写进
// 麦克风那一路的 ring。本回调不碰 stdout。默认输入设备变了由 runTapStart 换一个新实例。
final class MicCapture {
    private(set) var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private let ioQueue = DispatchQueue(label: "meetap.audio-tap.mic")
    private let source: Source
    private var rateListener: AudioObjectPropertyListenerBlock?
    private(set) var sampleRate: Float64 = 0

    init(source: Source) { self.source = source }

    func start() throws {
        guard let dev = defaultInputDevice() else {
            throw TapError("cannot get default input device")
        }
        deviceID = dev

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &asbd)
        // IO proc 按设备标称采样率交付；读不到再看流格式。都读不到宁可不开麦。
        // （自报值不准也不怕：Source 测速会纠正）
        sampleRate = nominalSampleRate(dev) ?? 0
        if sampleRate <= 0 { sampleRate = asbd.mSampleRate }
        guard sampleRate > 0 else { throw TapError("cannot read mic sample rate") }
        // 交错多声道时按 stride 取首声道；CoreAudio 输入默认 Float32
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        // 闭包外捕获为局部量：避免回调隐式捕获 self，保证实时线程零分配
        let ring = source.ring
        let rs = LinearResampler(inRate: sampleRate, outRate: source.outRate)

        var pid: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&pid, dev, ioQueue) {
            _, inInputData, _, _, _ in
            if writeFailedFlag.pointee { return }
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard abl.count > 0 else { return }
            let buf = abl[0]
            guard let data = buf.mData, buf.mDataByteSize > 0 else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let total = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let fp = data.assumingMemoryBound(to: Float.self)
            let stride = max(1, Int(buf.mNumberChannels > 0 ? buf.mNumberChannels : UInt32(channels)))

            var peak: Float = 0
            var sumsq: Double = 0
            var cnt = 0
            var i = 0
            while i < total {
                let v = fp[i]; let a = abs(v)
                if a > peak { peak = a }
                sumsq += Double(v) * Double(v); cnt += 1
                i += stride
            }
            meterLock.lock()
            if peak > micMeterPeak { micMeterPeak = peak }
            micMeterSumSq += sumsq; micMeterCount += cnt
            micLastNs = now
            if micFirstNs == 0 { micFirstNs = now }
            meterLock.unlock()
            rs.process(fp, frames: total / stride, stride: stride, into: ring, nowNs: now)
        }
        guard st == noErr, let createdPid = pid else {
            throw TapError("mic AudioDeviceCreateIOProcIDWithBlock failed (status \(st))")
        }
        procID = createdPid
        source.attach(rs)
        rateListener = addRateListener(dev, rs, tag: "MIC", queue: ioQueue)
        let st2 = AudioDeviceStart(dev, createdPid)
        guard st2 == noErr else {
            cleanup()
            throw TapError("mic AudioDeviceStart failed (status \(st2))")
        }
        running = true
    }

    func cleanup() {
        if running, let p = procID { AudioDeviceStop(deviceID, p); running = false }
        removeRateListener(deviceID, rateListener, queue: ioQueue); rateListener = nil
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

// MARK: - 输出写线程（墙钟节拍）
// stdout 的唯一写出口。每 10ms 按墙钟算出「从启动到现在应写的帧数」，补写差额：
// 每一路各取这么多帧（Source 负责不足补零 / 多余丢弃 / 微调比例）混音写出。
// 节拍只跟墙钟走，不跟任何设备的硬件时钟：哪一路速率和声明不符，都不会让录音变速。
// （老架构按「活跃源里可用量最少的那个」取数，24k 麦克风把整段录音拖成 2 倍速。）
final class OutputWriter {
    private let rate: Double
    private let sources: [Source]
    private let originNs: UInt64
    private let queue = DispatchQueue(label: "meetap.audio-tap.writer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let cap: Int
    private let out, tmp: UnsafeMutablePointer<Float>
    private(set) var written = 0
    private var nextMeasureNs: UInt64
    private var nextReportNs: UInt64
    static let measureNs: UInt64 = 2_000_000_000
    static let reportNs: UInt64 = 10_000_000_000

    // originNs：录音时间轴零点（audio-tap 启动时刻），之后每一纳秒墙钟都对应输出帧
    init(rate: Double, sources: [Source], originNs: UInt64) {
        self.rate = rate
        self.sources = sources
        self.originNs = originNs
        for s in sources { s.originNs = originNs }
        cap = max(4800, Int(rate / 10))  // 单次渲染上限 100ms，追帧时分块
        out = .allocate(capacity: cap)
        tmp = .allocate(capacity: cap)
        nextMeasureNs = originNs + Self.measureNs
        nextReportNs = originNs + Self.reportNs
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [unowned self] in self.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        if writeFailedFlag.pointee { return }
        let ok = pump(now: DispatchTime.now().uptimeNanoseconds) { p, n in
            writeAll(fd: 1, data: p, count: n * MemoryLayout<Float>.size)
        }
        if !ok {
            // 下游（ffmpeg）已退出：置位并交给主线程清理
            writeFailedFlag.pointee = true
            DispatchQueue.main.async { cleanupAndExit(0) }
        }
    }

    // 写到墙钟 now 应有的帧数；sink 返回 false 表示下游已关闭。selftest 用合成时间驱动它。
    func pump(now: UInt64, sink: (UnsafePointer<Float>, Int) -> Bool) -> Bool {
        let due = Int(Double(now - originNs) * rate / 1e9)
        while written < due {
            let n = min(cap, due - written)
            out.update(repeating: 0, count: n)
            for s in sources {
                s.pull(n, into: tmp, now: now)
                for i in 0..<n { out[i] += tmp[i] }
            }
            for i in 0..<n { out[i] = max(-1.0, min(1.0, out[i])) }
            if !sink(out, n) { return false }
            written += n
        }
        if now >= nextMeasureNs {
            nextMeasureNs = now + Self.measureNs
            for s in sources { s.measure(now: now) }
        }
        if now >= nextReportNs {
            nextReportNs = now + Self.reportNs
            for s in sources { s.reportIfChanged() }
        }
        return true
    }

    func logSummary() {
        for s in sources { s.log(s.summaryLine()) }
    }
}

// 除本进程外，是否有进程正在往外放声音。用来区分「系统本来就没声音」
// 和「有声音但 tap 回调没触发（卡死）」。设备级的 IsRunningSomewhere 不行：
// 输入输出同一设备的 USB 耳机，本进程开麦克风就会让它显示 running。
@available(macOS 14.4, *)
func otherProcessPlaying() -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let sysObj = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sysObj, &addr, 0, nil, &size) == noErr else { return false }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &ids) == noErr else { return false }
    let me = getpid()
    for id in ids {
        var pid: pid_t = 0
        var running: UInt32 = 0
        var sz = UInt32(MemoryLayout<pid_t>.size)
        addr.mSelector = kAudioProcessPropertyPID
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &pid) == noErr, pid != me else { continue }
        sz = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioProcessPropertyIsRunningOutput
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &running) == noErr, running != 0 {
            return true
        }
    }
    return false
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
    // 系统音那一路：本回调写入其 ring，OutputWriter 读出。重建 tap 时沿用同一路。
    private let source: Source
    private var rateListener: AudioObjectPropertyListenerBlock?

    init(source: Source) { self.source = source }

    // IO 回调实际交付的采样率（aggregate device 的标称率），重采样以此为准
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

        // IO proc 挂在 aggregate 上，按 aggregate 的标称率交付（tap 经漂移补偿重采样进来）。
        // 实测 AirPods 通话模式下输出设备降到 24k，tap 与 aggregate 仍是 48k。
        if let aggRate = nominalSampleRate(aggID), aggRate > 0 {
            if aggRate != sampleRate {
                fputs("NOTE: tap format \(Int(sampleRate)) != aggregate \(Int(aggRate)), using aggregate\n", stderr)
            }
            sampleRate = aggRate
        }

        // 闭包外捕获为局部量，避免回调隐式捕获 self、也保证实时线程零分配。
        let ring = source.ring
        let rs = LinearResampler(inRate: sampleRate, outRate: source.outRate)

        // 4. IO proc：系统音重采样到输出采样率后写进 ring，不碰 stdout（由 OutputWriter 写出）。
        //    mono tap → 单 buffer Float32。
        var pid: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&pid, aggregateID, ioQueue) {
            _, inInputData, _, _, _ in
            if writeFailedFlag.pointee { return }
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard abl.count > 0 else { return }
            let buf = abl[0]
            guard let data = buf.mData, buf.mDataByteSize > 0 else { return }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let fp = data.assumingMemoryBound(to: Float.self)
            let stride = max(1, Int(buf.mNumberChannels))
            let now = DispatchTime.now().uptimeNanoseconds
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
            tapLastNs = now
            if tapFirstNs == 0 { tapFirstNs = now }
            meterLock.unlock()
            // ring 满时自动丢最旧样本（写线程被阻塞的极端情况），不阻塞回调
            rs.process(fp, frames: n / stride, stride: stride, into: ring, nowNs: now)
        }
        guard st == noErr, let createdPid = pid else {
            cleanup()
            throw TapError("AudioDeviceCreateIOProcIDWithBlock failed (status \(st))")
        }
        procID = createdPid
        source.attach(rs)
        rateListener = addRateListener(aggregateID, rs, tag: "TAP", queue: ioQueue)

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
        removeRateListener(aggregateID, rateListener, queue: ioQueue); rateListener = nil
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
    activeWriter?.logSummary()
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

// tap-format：打印 Process Tap 的【实际】采样率（Hz），仅供诊断。
// tap-rate 读默认输出设备的“标称采样率”，tap-format 读 tap 自身的流格式
// (kAudioTapPropertyFormat)，两者在蓝牙通话模式下不相等（输出设备 24k、tap 48k）。
// tap-start 的输出采样率由 --output-rate 决定、内部重采样，不依赖这两个值。
func runTapFormat() -> Never {
    guard #available(macOS 14.4, *) else {
        fputs("Error: Process Tap requires macOS 14.4+\n", stderr)
        exit(1)
    }
    guard defaultOutputDevice() != nil else {
        fputs("Error: cannot get default output device\n", stderr)
        exit(1)
    }
    let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
    desc.name = "meetap-tap-probe"
    desc.isPrivate = true
    var tid = AudioObjectID(kAudioObjectUnknown)
    let st = AudioHardwareCreateProcessTap(desc, &tid)
    guard st == noErr, tid != kAudioObjectUnknown else {
        fputs("Error: AudioHardwareCreateProcessTap failed (status \(st))\n", stderr)
        exit(1)
    }
    defer { AudioHardwareDestroyProcessTap(tid) }

    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(tid, &addr, 0, nil, &size, &asbd) == noErr,
          asbd.mSampleRate > 0 else {
        fputs("Error: cannot read tap format\n", stderr)
        exit(1)
    }
    print(Int(asbd.mSampleRate))
    exit(0)
}

var activeMic: MicCapture? = nil
var activeWriter: OutputWriter? = nil
var tapWatchdog: DispatchSourceTimer? = nil

func runTapStart(duration: Double?, levelFile: String?, micLevelFile: String?, withMic: Bool,
                 outputRate: Double) -> Never {
    guard #available(macOS 14.4, *) else {
        fputs("Error: Process Tap requires macOS 14.4+\n", stderr)
        exit(1)
    }

    writeFailedFlag.pointee = false
    signal(SIGPIPE, SIG_IGN)  // 管道断开由 write 返回 EPIPE 处理，不让信号杀进程
    // 录音时间轴零点：输出从这一刻起按墙钟出帧（设备初始化期间的空档也算在录音时长里）
    let launchNs = DispatchTime.now().uptimeNanoseconds

    // 装配：tap、麦克风各一路（Source），各自重采样到 outputRate 写进自己的 ring；
    // OutputWriter 按墙钟取数混音写 stdout。写线程等 tap 起来才启动：tap 起不来就
    // 不出一个字节直接退出，让 meetap 的健康探测照常判失败、重试。启动后先补齐
    // 从 launchNs 到此刻的空档（设备初始化期间），时长仍从启动时刻算。
    let ringCap = Int(outputRate) * 2  // 2s
    let sysSource = Source(name: "tap", ring: AudioRing(capacity: ringCap), outRate: outputRate)
    let micSource = withMic ? Source(name: "mic", ring: AudioRing(capacity: ringCap), outRate: outputRate) : nil
    let writer = OutputWriter(rate: outputRate, sources: [sysSource] + (micSource.map { [$0] } ?? []),
                              originNs: launchNs)
    activeWriter = writer

    // 麦克风失败不致命：降级为纯系统音，会议不能不录
    func startMic(_ ms: Source) {
        let mic = MicCapture(source: ms)
        do {
            try mic.start()
            activeMic = mic
            fputs("MIC=on rate=\(Int(mic.sampleRate)) device=\(deviceName(mic.deviceID))\n", stderr)
            if mic.sampleRate != outputRate {
                fputs("RESAMPLE mic \(Int(mic.sampleRate)) -> \(Int(outputRate))\n", stderr)
            }
        } catch {
            mic.cleanup()
            activeMic = nil
            fputs("MIC=off (\(error))\n", stderr)
        }
    }
    if let ms = micSource { startMic(ms) }

    let capture = TapCapture(source: sysSource)
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
    if capture.sampleRate != outputRate {
        fputs("RESAMPLE tap \(Int(capture.sampleRate)) -> \(Int(outputRate))\n", stderr)
    }
    writer.start()

    // 元信息走 stderr（stdout 只有 PCM 数据）。SAMPLE_RATE 即 --output-rate，
    // 调用方给 ffmpeg -ar 用的必须是同一个值。
    fputs("SAMPLE_RATE=\(Int(outputRate))\n", stderr)
    fputs("CHANNELS=1\n", stderr)
    fputs("FORMAT=f32le\n", stderr)

    // 重建 tap（看门狗用），沿用同一路 sysSource
    var tapStartNs = DispatchTime.now().uptimeNanoseconds
    func rebuildTap(_ why: String) {
        fputs("TAP_REBUILD (\(why))\n", stderr)
        (activeCapture as? TapCapture)?.cleanup()
        let c = TapCapture(source: sysSource)
        activeCapture = c
        do {
            try c.start()
            if c.sampleRate != outputRate {
                fputs("RESAMPLE tap \(Int(c.sampleRate)) -> \(Int(outputRate))\n", stderr)
            }
        } catch {
            fputs("Error: tap rebuild failed (\(error))\n", stderr)
        }
        tapStartNs = DispatchTime.now().uptimeNanoseconds
    }

    // 录音途中切输入设备（断开/连上蓝牙耳机、手动改输入）：麦克风跟随默认输入设备。
    // tap 不跟随默认输出重建：实测原 tap 在默认输出改变后照样录到所有进程的声音，
    // 而重建出的新 tap 录不到仍在往原设备放音的进程（如固定输出到耳机的会议 App）。
    // 录音时长不受任何切换影响（墙钟节拍）。
    let sysObj = AudioObjectID(kAudioObjectSystemObject)
    var inAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    if let ms = micSource {
        AudioObjectAddPropertyListenerBlock(sysObj, &inAddr, .main) { _, _ in
            guard let dev = defaultInputDevice(), dev != activeMic?.deviceID else { return }
            fputs("MIC_DEVICE_CHANGED -> \(deviceName(dev))\n", stderr)
            activeMic?.cleanup()
            activeMic = nil
            startMic(ms)
        }
    }

    // tap 卡死看门狗：Process Tap 的 IO 回调偶发不启动（AudioDeviceStart 成功却不
    // 喂数据）。有别的进程在放声音、tap 却迟迟没回调，就在进程内重建 tap，录音不断。
    // 重建间隔 3s 起步、每次翻倍、上限 60s，tap 一出数据就恢复 3s。
    var backoffNs: UInt64 = 3_000_000_000
    var restarts = 0
    var tapFirstLogged = false, micFirstLogged = false, micNoDataWarned = false, micStalled = false
    let wd = DispatchSource.makeTimerSource(queue: .main)
    wd.schedule(deadline: .now() + 1, repeating: 1)
    wd.setEventHandler {
        let now = DispatchTime.now().uptimeNanoseconds
        meterLock.lock()
        let last = tapLastNs, tapFirst = tapFirstNs, micFirst = micFirstNs, micLast = micLastNs
        meterLock.unlock()
        // 首次出数据诊断（相对 audio-tap 启动）
        if !tapFirstLogged && tapFirst > 0 {
            tapFirstLogged = true
            fputs("TAP_FIRST_DATA after \((tapFirst - launchNs) / 1_000_000) ms\n", stderr)
        }
        if activeMic != nil && !micFirstLogged && micFirst > 0 {
            micFirstLogged = true
            fputs("MIC_FIRST_DATA after \((micFirst - launchNs) / 1_000_000) ms\n", stderr)
        }
        if activeMic != nil && micFirst == 0 && !micNoDataWarned && now - launchNs > 5_000_000_000 {
            micNoDataWarned = true
            fputs("WARNING: MIC_NO_DATA mic opened but delivered nothing for 5s\n", stderr)
        }
        // 麦克风出过数据后断流（实测蓝牙耳机通话模式下偶发）：断流/恢复各记一行
        if activeMic != nil && micFirst > 0 {
            let gapMs = (now - micLast) / 1_000_000
            if !micStalled && gapMs > 2000 {
                micStalled = true
                fputs("WARNING: MIC_STALLED no mic data for \(gapMs) ms (at \((now - launchNs) / 1_000_000) ms)\n", stderr)
            } else if micStalled && gapMs < 1000 {
                micStalled = false
                fputs("MIC_RESUMED at \((now - launchNs) / 1_000_000) ms\n", stderr)
            }
        }
        if last > tapStartNs { backoffNs = 3_000_000_000; return }
        guard now - tapStartNs > backoffNs, otherProcessPlaying() else { return }
        restarts += 1
        rebuildTap("restart \(restarts): audio playing but tap delivered nothing")
        backoffNs = min(backoffNs * 2, 60_000_000_000)
    }
    wd.resume()
    tapWatchdog = wd

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

// MARK: - 自检（test/resample-selftest.sh 调用，不碰音频设备）

func runSelftestResample() -> Never {
    let out = 48000.0
    let freq = 440.0, secs = 2.0
    var failures = 0
    func check(_ ok: Bool, _ msg: String) {
        print((ok ? "PASS " : "FAIL ") + msg)
        if !ok { failures += 1 }
    }
    func sine(_ rate: Double, _ n: Int, from start: Int = 0) -> [Float] {
        (0..<n).map { Float(sin(2 * .pi * freq * Double(start + $0) / rate)) }
    }
    // 按不规则批大小（1~1013 帧）喂入，模拟 IO 回调 buffer 大小变化，检验跨批连续
    func feed(_ rs: LinearResampler, _ input: [Float], stride: Int, _ ring: AudioRing) {
        let frames = input.count / stride
        var off = 0, chunk = 37
        input.withUnsafeBufferPointer { p in
            while off < frames {
                let m = min(chunk, frames - off)
                rs.process(p.baseAddress! + off * stride, frames: m, stride: stride, into: ring,
                           nowNs: UInt64(off + 1))
                off += m
                chunk = chunk * 7 % 1013 + 1
            }
        }
    }
    func drain(_ ring: AudioRing) -> [Float] {
        var buf = [Float](repeating: 0, count: ring.available)
        let n = buf.count
        _ = buf.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, n) }
        return buf
    }
    func maxErr(_ got: [Float]) -> Float {
        let ideal = sine(out, got.count)
        return zip(got, ideal).map { abs($0 - $1) }.max() ?? 0
    }
    let expect = Int(out * secs)

    print("== 重采样 ==")
    // 1) 蓝牙 HFP（8k/16k/24k）、常见 USB/内建（44.1k/48k/96k）等 → 48k：
    //    样本数 = 时长 × 48000（不变速），波形贴合理想 48k 正弦（不变调）
    for inRate in [8000.0, 16000, 22050, 24000, 32000, 44100, 48000, 96000] {
        let ring = AudioRing(capacity: expect + 1024)
        feed(LinearResampler(inRate: inRate, outRate: out), sine(inRate, Int(inRate * secs)), stride: 1, ring)
        let got = drain(ring)
        let err = maxErr(got)
        check(abs(got.count - expect) <= 8 && err < 0.02,
              "\(Int(inRate)) -> 48000: \(got.count) samples (expect \(expect)), max err \(err)")
    }

    // 2) 交错双声道（stride 2）只取首声道
    do {
        let n = Int(24000 * secs)
        let mono = sine(24000, n)
        var stereo = [Float](repeating: 0.9, count: n * 2)
        for i in 0..<n { stereo[i * 2] = mono[i] }
        let ring = AudioRing(capacity: expect + 1024)
        feed(LinearResampler(inRate: 24000, outRate: out), stereo, stride: 2, ring)
        let got = drain(ring)
        let err = maxErr(got)
        check(abs(got.count - expect) <= 8 && err < 0.02,
              "stereo 24000 -> 48000 (first channel): \(got.count) samples, max err \(err)")
    }

    // 3) 录音途中输入采样率改变（24k 一秒 → 16k 一秒）：总时长仍是 2 秒
    do {
        let ring = AudioRing(capacity: expect + 1024)
        let rs = LinearResampler(inRate: 24000, outRate: out)
        feed(rs, sine(24000, 24000), stride: 1, ring)
        rs.inRate = 16000
        feed(rs, sine(16000, 16000, from: 16000), stride: 1, ring)
        let got = drain(ring)
        let peak = got.map { abs($0) }.max() ?? 0
        check(abs(got.count - expect) <= 8 && peak <= 1.0001,
              "rate change 24000 -> 16000 mid-stream: \(got.count) samples (expect \(expect)), peak \(peak)")
    }

    // 4) 墙钟同步仿真：合成时间驱动 OutputWriter.pump，模拟设备按「真实速率」出数据、
    //    按「自报速率」声明，检验输出时长 = 墙钟、音高不变、CLOCK_DRIFT 该响才响
    print("== 墙钟同步仿真（60s）==")
    struct Dev {
        let name: String
        let trueRate: Double          // 设备实际每秒出多少帧
        let declared: Double          // 设备自报（resampler 初始 inRate）
        var startAt = 0.8             // 首次出数据（蓝牙切通话模式要时间）
        var stall: ClosedRange<Double>? = nil
        var burstSec = 0.0            // 首个回调一次性带来的积压（秒）
        var period = 0.02             // 回调周期
    }
    struct SimResult { let out: [Float]; let drift: [(Double, String)]; let stats: [Source.Stats] }
    func simulate(_ devs: [Dev], seconds: Double = 60) -> SimResult {
        let origin: UInt64 = 1_000_000_000
        var simT = 0.0
        var drift: [(Double, String)] = []
        let sources = devs.map { Source(name: $0.name, ring: AudioRing(capacity: Int(out) * 2), outRate: out) }
        let rss = zip(devs, sources).map { d, s -> LinearResampler in
            let r = LinearResampler(inRate: d.declared, outRate: out)
            s.attach(r)
            s.log = { msg in if msg.contains("CLOCK_DRIFT") { drift.append((simT, msg)) } }
            return r
        }
        let writer = OutputWriter(rate: out, sources: sources, originNs: origin)
        var result = [Float](); result.reserveCapacity(Int(out * seconds) + 1)
        var k = [Int](repeating: 0, count: devs.count)       // 下一个回调序号
        var seed: UInt64 = 12345
        func jitter() -> Double {                            // 0~4ms 投递延迟（确定性伪随机）
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31) * 0.004
        }
        var buf = [Float](repeating: 0, count: Int(out))
        var tick = 0
        let steps = Int(seconds * 1000)
        for ms in 0...steps {
            simT = Double(ms) / 1000
            for (j, d) in devs.enumerated() {
                while true {
                    let end = d.startAt + Double(k[j] + 1) * d.period   // 本回调覆盖到的真实时刻
                    let deliver = end + jitter()
                    guard deliver <= simT else { break }
                    k[j] += 1
                    if let st = d.stall, st.contains(end) { continue }
                    let from = k[j] == 1 ? end - d.period - d.burstSec : end - d.period
                    let i0 = Int(((from - d.startAt) * d.trueRate).rounded())
                    let i1 = Int(((end - d.startAt) * d.trueRate).rounded())
                    let n = i1 - i0
                    if n <= 0 { continue }
                    for i in 0..<n { buf[i] = Float(sin(2 * .pi * freq * Double(i0 + i) / d.trueRate)) }
                    buf.withUnsafeBufferPointer {
                        rss[j].process($0.baseAddress!, frames: n, stride: 1, into: sources[j].ring,
                                       nowNs: origin + UInt64(deliver * 1e9))
                    }
                }
            }
            if ms % 10 == 0 {
                tick += 1
                _ = writer.pump(now: origin + UInt64(simT * 1e9)) { p, n in
                    result.append(contentsOf: UnsafeBufferPointer(start: p, count: n)); return true
                }
            }
        }
        return SimResult(out: result, drift: drift, stats: sources.map { $0.stats() })
    }
    // 上升过零次数 / 时长 = 频率（补零段最多多数一个过零，误差可忽略）
    func pitch(_ x: [Float], _ a: Double, _ b: Double) -> Double {
        let i0 = Int(a * out), i1 = min(x.count, Int(b * out))
        var c = 0
        for i in (i0 + 1)..<i1 where x[i - 1] < 0 && x[i] >= 0 { c += 1 }
        return Double(c) / (b - a)
    }
    func ms(_ f: Int) -> Int { Int(Double(f) * 1000 / out) }
    let full = Int(out * 60)
    func report(_ label: String, _ r: SimResult, expectDrift: Bool, maxDriftAt: Double = 20,
                pitchFrom: Double = 40, maxPadMs: Int = 30, maxDropMs: Int = 0) {
        let p = pitch(r.out, pitchFrom, 60)
        let pad = r.stats.map { ms($0.pad) }.max() ?? 0
        let drop = r.stats.map { ms($0.drop) }.max() ?? 0
        let driftAt = r.drift.first?.0
        var ok = r.out.count == full && abs(p / freq - 1) < 0.005 && pad <= maxPadMs && drop <= maxDropMs
        ok = ok && (expectDrift ? (driftAt.map { $0 <= maxDriftAt } ?? false) : r.drift.isEmpty)
        let driftDesc = driftAt.map { String(format: "CLOCK_DRIFT@%.0fs", $0) } ?? "无 CLOCK_DRIFT"
        check(ok, String(format: "%@: %d 帧(应 %d) 音高 %.1fHz pad=%dms drop=%dms %@",
                         label, r.out.count, full, p, pad, drop, driftDesc))
    }

    report("AirPods 麦 24k 如实上报", simulate([Dev(name: "mic", trueRate: 24000, declared: 24000)]),
           expectDrift: false)
    report("坏版本：麦 24k 却按 48k 处理（关掉重采样）",
           simulate([Dev(name: "mic", trueRate: 24000, declared: 48000)]),
           expectDrift: true, maxPadMs: 20000)
    report("设备时钟快 0.3%（24072 报 24000）", simulate([Dev(name: "mic", trueRate: 24072, declared: 24000)]),
           expectDrift: false)
    report("设备时钟慢 0.3%（23928 报 24000）", simulate([Dev(name: "mic", trueRate: 23928, declared: 24000)]),
           expectDrift: false)
    report("自报偏差 3%（23280 报 24000）", simulate([Dev(name: "mic", trueRate: 23280, declared: 24000)]),
           expectDrift: true, maxPadMs: 2000, maxDropMs: 2000)
    report("麦克风 20~25s 断流", simulate([Dev(name: "mic", trueRate: 24000, declared: 24000, stall: 20...25)]),
           expectDrift: false)
    do {
        // 录音途中切麦克风设备：0.2s 空档后新设备接上。恢复后应立刻攒回水位、比例回到 1，
        // 不能靠长时间微调比例慢慢补（那会让这一路音高偏一分多钟）
        let r = simulate([Dev(name: "mic", trueRate: 24000, declared: 24000, stall: 45...45.2)])
        report("麦克风 45s 切设备空档 0.2s（短于断流阈值）", r, expectDrift: false, pitchFrom: 47, maxPadMs: 600)
        check(abs(r.stats[0].adjust - 1) < 0.0005, "切设备后比例回到 1（adj=\(r.stats[0].adjust)）")
    }
    report("tap 48k + 麦 16k 同时", simulate([Dev(name: "tap", trueRate: 48000, declared: 48000, period: 512 / 48000),
                                            Dev(name: "mic", trueRate: 16000, declared: 16000)]),
           expectDrift: false)
    report("开麦 3s 后才出数据且首包积压 0.5s",
           simulate([Dev(name: "mic", trueRate: 24000, declared: 24000, startAt: 3, burstSec: 0.5)]),
           expectDrift: false, maxDropMs: 1000)
    do {
        let r = simulate([Dev(name: "tap", trueRate: 48000, declared: 48000, period: 512 / 48000)])
        let adj = r.stats[0].adjust
        check(adj == 1 && r.stats[0].pad == 0 && r.stats[0].drop == 0,
              "tap 48k 稳态走直通（adj=\(adj)，不插值）")
    }

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    fputs("""
    audio-tap - macOS 14.4+ Process Tap 系统音频捕获工具

    Commands:
      tap-supported             检测 Process Tap 是否可用（yes / 原因）
      tap-rate                  打印默认输出设备标称采样率（Hz）
      tap-format                打印 Process Tap 实际采样率（Hz，采集/编码应以此为准）
      tap-start [--output-rate HZ] [--duration N] [--with-mic] [--level-file PATH] [--mic-level-file PATH]
                                捕获系统音频，Float32 LE mono PCM 写 stdout
                                --output-rate: 输出采样率（默认 48000），各源重采样到此率
                                --with-mic: 混入默认输入设备（麦克风）
                                --level-file: 每 0.4s 写当前电平(dBFS)到文件，
                                供波形显示读取（SIGINT/SIGTERM 停止并清理）
      selftest-resample         重采样自检

    """, stderr)
    exit(1)
}

switch cmd {
case "tap-supported":
    runTapSupported()
case "tap-rate":
    runTapRate()
case "tap-format":
    runTapFormat()
case "tap-start":
    var duration: Double? = nil
    var levelFile: String? = nil
    var micLevelFile: String? = nil
    var withMic = false
    var outputRate = 48000.0
    var i = 1
    while i < args.count {
        if args[i] == "--output-rate", i + 1 < args.count, let r = Int(args[i + 1]), r > 0 {
            outputRate = Double(r)
            i += 2
        } else if args[i] == "--duration", i + 1 < args.count, let d = Double(args[i + 1]), d > 0 {
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
            fputs("Usage: tap-start [--output-rate HZ] [--duration N] [--with-mic] [--level-file PATH] [--mic-level-file PATH]\n", stderr)
            exit(1)
        }
    }
    runTapStart(duration: duration, levelFile: levelFile, micLevelFile: micLevelFile, withMic: withMic,
                outputRate: outputRate)
case "selftest-resample":
    runSelftestResample()
default:
    fputs("Unknown command: \(cmd)\n", stderr)
    exit(1)
}
