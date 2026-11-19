import CoreAudio
import EventKit
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

// MARK: - 日历：按录音时段找对应的会（calendar-status / calendar-request / calendar-query）
// 规矩：calendar-query 只在已经「完全访问」时读，绝不请求授权——开录、停止、休眠自动停止、
// 后台录音、以后菜单栏 app 拉起的流程都没人在终端前，弹授权框会卡住。只有 setup 调
// calendar-request。权限授给的是终端 App，嵌入的 Info.plist 只提供用途说明。

func calendarStatusName(_ s: EKAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .fullAccess: return "fullAccess"
    case .writeOnly: return "writeOnly"
    @unknown default: return "unknown"
    }
}

// 匹配用的最小信息（和 EventKit 解耦，selftest-calendar 用合成数据驱动）
struct CalItem {
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let canceled: Bool
    let declined: Bool   // 参会人里标成「我」的那一位已拒绝
}

func overlapSec(_ e: CalItem, _ ws: Date, _ we: Date) -> Double {
    max(0, min(e.end, we).timeIntervalSince(max(e.start, ws)))
}

// 重叠门槛：至少 5 分钟；录音不到 10 分钟时，至少录音时长的一半
func minOverlapSec(window: Double) -> Double { window < 600 ? window / 2 : 300 }

// 时间分 = 重叠时长 ÷ 录音和这场会合起来的总时长（0~1）。一场 3 小时的占位日程重叠再多，
// 合起来的总时长也长，分就低；时间和录音贴合的会分高。
func timeScore(_ e: CalItem, _ ws: Date, _ we: Date) -> Double {
    let union = max(e.end, we).timeIntervalSince(min(e.start, ws))
    return union > 0 ? overlapSec(e, ws, we) / union : 0
}

// 候选：先过门槛（全天、已取消、我已拒绝的不算），再按时间分从高到低排，分数一样取开始时间离开录
// 最近的；最多 5 场。只按时间排个序，是哪一场由 meetap 转录完以后按内容认。
func rankCandidates(_ items: [CalItem], start ws: Date, end we: Date) -> [Int] {
    let need = minOverlapSec(window: we.timeIntervalSince(ws))
    let ok = items.indices.filter { i in
        let e = items[i], o = overlapSec(e, ws, we)
        return !e.allDay && !e.canceled && !e.declined && o > 0 && o >= need
    }
    let sorted = ok.sorted { a, b in
        let sa = timeScore(items[a], ws, we), sb = timeScore(items[b], ws, we)
        if abs(sa - sb) > 1e-9 { return sa > sb }
        return abs(items[a].start.timeIntervalSince(ws)) < abs(items[b].start.timeIntervalSince(ws))
    }
    return Array(sorted.prefix(5))
}

let isoOut: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone.current
    f.formatOptions = [.withInternetDateTime]
    return f
}()

// --start / --end：epoch 秒或 ISO 8601
func parseTime(_ s: String) -> Date? {
    if let v = Double(s) { return Date(timeIntervalSince1970: v) }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func emitJSON(_ obj: [String: Any]) -> Never {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }
    exit(0)
}

func participantEmail(_ p: EKParticipant) -> String? {
    let u = p.url.absoluteString
    guard u.lowercased().hasPrefix("mailto:") else { return nil }
    let e = String(u.dropFirst(7))
    return e.isEmpty ? nil : e
}

func participantJSON(_ p: EKParticipant) -> [String: Any] {
    let role: String
    switch p.participantRole {
    case .required: role = "required"
    case .optional: role = "optional"
    case .chair: role = "chair"
    case .nonParticipant: role = "nonParticipant"
    default: role = "unknown"
    }
    let status: String
    switch p.participantStatus {
    case .accepted: status = "accepted"
    case .declined: status = "declined"
    case .tentative: status = "tentative"
    case .pending: status = "pending"
    default: status = "unknown"
    }
    let type: String
    switch p.participantType {
    case .person: type = "person"
    case .room: type = "room"
    case .resource: type = "resource"
    case .group: type = "group"
    default: type = "unknown"
    }
    var d: [String: Any] = ["role": role, "status": status, "type": type]
    if let n = p.name, !n.isEmpty { d["name"] = n }
    if let e = participantEmail(p) { d["email"] = e }
    return d
}

func runCalendarQuery(start ws: Date, end we: Date, timeout: Double) -> Never {
    var window: [String: Any] = ["start": isoOut.string(from: ws), "end": isoOut.string(from: we)]
    let st = EKEventStore.authorizationStatus(for: .event)
    guard st == .fullAccess else {
        emitJSON(["status": "not_authorized", "auth": calendarStatusName(st), "window": window])
    }
    var result: [String: Any]? = nil
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let store = EKEventStore()
        let evs = store.events(matching: store.predicateForEvents(withStart: ws, end: we, calendars: nil))
        let items = evs.map { e in
            CalItem(title: e.title ?? "", start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                    canceled: e.status == .canceled,
                    declined: e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } == true)
        }
        // 候选全部带上完整字段（正文、参会人是原样的，去掉入会信息由 meetap 做）；
        // match 是时间分最高的那场，只是按时间的猜测，留着给只看时间的调用方
        let cands = rankCandidates(items, start: ws, end: we).map { i -> [String: Any] in
            let e = evs[i]
            var d: [String: Any] = [
                "title": items[i].title,
                "start": isoOut.string(from: e.startDate), "end": isoOut.string(from: e.endDate),
                "overlap_sec": Int(overlapSec(items[i], ws, we)),
                "time_score": (timeScore(items[i], ws, we) * 1000).rounded() / 1000,
                "calendar": e.calendar?.title ?? "",
                "attendees": (e.attendees ?? []).map(participantJSON),
                "attendee_count": e.attendees?.count ?? 0,
                "location": e.location ?? "", "notes": e.notes ?? "",
            ]
            if let o = e.organizer { d["organizer"] = participantJSON(o) }
            return d
        }
        var r: [String: Any] = ["status": "ok", "window": window, "candidates": cands]
        r["match"] = cands.first ?? NSNull()
        result = r
        done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        window["timeout_sec"] = timeout
        emitJSON(["status": "timeout", "window": window])
    }
    emitJSON(result ?? ["status": "error", "window": window])
}

// 只给 setup 用：还没决定、或只有写入权限时请求一次完全访问（会弹授权框），输出请求后的状态
func runCalendarRequest() -> Never {
    let st = EKEventStore.authorizationStatus(for: .event)
    if st == .notDetermined || st == .writeOnly {
        let done = DispatchSemaphore(value: 0)
        EKEventStore().requestFullAccessToEvents { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 120)
    }
    print(calendarStatusName(EKEventStore.authorizationStatus(for: .event)))
    exit(0)
}

// 已授权时：能读到几个日历（setup 用来确认同步上了，只给数量）
func runCalendarCount() -> Never {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { print(0); exit(0) }
    print(EKEventStore().calendars(for: .event).count)
    exit(0)
}

// 匹配规则自检（test/calendar-selftest.sh 调用，不碰日历）
func runSelftestCalendar() -> Never {
    var failures = 0
    func check(_ ok: Bool, _ msg: String) {
        print((ok ? "PASS " : "FAIL ") + msg)
        if !ok { failures += 1 }
    }
    let t0 = Date(timeIntervalSince1970: 1_794_960_000)   // 任意基准时刻
    func at(_ min: Double) -> Date { t0.addingTimeInterval(min * 60) }
    func item(_ title: String, _ s: Double, _ e: Double, allDay: Bool = false, canceled: Bool = false,
              declined: Bool = false) -> CalItem {
        CalItem(title: title, start: at(s), end: at(e), allDay: allDay, canceled: canceled, declined: declined)
    }
    func pick(_ items: [CalItem], _ s: Double, _ e: Double) -> (String?, [String]) {
        let r = rankCandidates(items, start: at(s), end: at(e))
        return (r.first.map { items[$0].title }, r.dropFirst().map { items[$0].title })
    }
    do {  // 提前开录、会议拖堂：录音 -2 ~ 70，会议 0 ~ 60
        let items = [item("周会", 0, 60)]
        let r = pick(items, -2, 70)
        check(r.0 == "周会", "提前开录、拖堂都能匹配上（按重叠算）")
    }
    do {  // 时间分最高的排第一，重叠不到 5 分钟的不进候选
        let items = [item("office hour", 30, 60), item("架构周会", 0, 60), item("下一场", 55, 90)]
        let r = pick(items, 1, 52)
        check(r.0 == "架构周会" && r.1 == ["office hour"], "时间分最高的排第一，重叠不到 5 分钟的不进候选：\(r)")
    }
    do {  // 11-19 的真实情况：09:00–12:00 的占位日程和 11:00–12:00 的会，录音 10:53–12:09
        // 以 09:00 为 0 分钟：占位 0~180，会 120~180，录音 113~189
        let items = [item("占位日程", 0, 180), item("分享会", 120, 180)]
        let r = rankCandidates(items, start: at(113), end: at(189))
        let s0 = timeScore(items[0], at(113), at(189)), s1 = timeScore(items[1], at(113), at(189))
        check(r.map { items[$0].title } == ["分享会", "占位日程"],
              String(format: "占位日程重叠更久也排在后面：分享会 %.3f > 占位日程 %.3f", s1, s0))
    }
    do {  // 同一时段两场真会：时间完全一样，分数一样，两场都进候选（交给按内容认）
        let items = [item("会 A", 0, 60), item("会 B", 0, 60)]
        let r = rankCandidates(items, start: at(0), end: at(60))
        check(r.count == 2, "同一时段两场一样的会都进候选，按内容认")
    }
    do {  // 全天、已取消、我已拒绝的不算
        let items = [item("生日", -600, 840, allDay: true), item("取消了", 0, 60, canceled: true),
                     item("我拒了", 0, 60, declined: true), item("真会", 10, 40)]
        let r = pick(items, 0, 60)
        check(r.0 == "真会" && r.1.isEmpty, "全天、已取消、我已拒绝的都不算：\(r)")
    }
    do {  // 门槛：录音 60 分钟时，重叠 4 分钟的不算
        let items = [item("上一场", -30, 4)]
        check(rankCandidates(items, start: at(0), end: at(60)).isEmpty, "重叠不到 5 分钟的不算（防止把上一场会当成这场）")
    }
    do {  // 短录音：8 分钟的录音，门槛是 4 分钟
        let items = [item("站会", 0, 15)]
        check(rankCandidates(items, start: at(13), end: at(21)).isEmpty, "8 分钟录音只重叠 2 分钟（不到一半）：不算")
        check(rankCandidates(items, start: at(9), end: at(17)) == [0], "8 分钟录音重叠 6 分钟（过半）：算")
    }
    do {  // 重叠一样长：时间更贴合录音的分高
        let items = [item("远的", -60, 30), item("近的", -5, 30)]
        let r = pick(items, 0, 30)
        check(r.0 == "近的" && r.1 == ["远的"], "重叠一样长时，时间更贴合录音的排前面：\(r)")
    }
    do {  // 分数完全一样：取开始时间离开录最近的
        // 录音 0~60：A 是 -20~60（重叠 60、合起来 80），B 是 0~80（重叠 60、合起来 80），分数都是 0.75
        let items = [item("提前 20 分钟开", -20, 60), item("准点开", 0, 80)]
        let r = pick(items, 0, 60)
        check(r.0 == "准点开", "分数一样时，取开始时间离开录最近的：\(r)")
    }
    do {  // 候选最多 5 个
        let items = (0..<8).map { item("会\($0)", 0, 60) }
        check(rankCandidates(items, start: at(0), end: at(60)).count == 5, "候选最多 5 个")
    }
    do {
        check(rankCandidates([], start: at(0), end: at(60)).isEmpty, "没有事件：没有候选，不报错")
        check(parseTime("1794960000") == t0 && parseTime("2026-11-18T12:01:06+08:00") != nil && parseTime("昨天") == nil,
              "--start / --end 认 epoch 秒和 ISO 8601，认不出返回 nil")
    }
    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
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
      default-input-name   当前默认输入设备名称
      set-default <id>     设置默认输出设备
      find-uid <uid>       通过 UID 查找设备 ID
      sleep-watch <meetap> <pid-file>  休眠前执行 meetap stop --sleep，唤醒后 _wake-notify
      calendar-status      日历授权状态（fullAccess / writeOnly / denied / restricted / notDetermined）
      calendar-request     只给 setup 用：请求日历完全访问权限（会弹授权框），输出请求后的状态
      calendar-count       已授权时能读到的日历个数
      calendar-query --start T --end T [--timeout 10]
                           按时间段收候选会议，输出 JSON（candidates 按时间分排好，match 是第一场）；T 是 epoch 秒或
                           ISO 8601。没有完全访问权限就直接返回 not_authorized，绝不请求授权
      selftest-calendar    匹配规则自检

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
case "default-input-name":
    guard let id = defaultDevice(output: false), let name = deviceName(id) else {
        fputs("Error: no default input\n", stderr); exit(1) }
    print(name)
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
case "calendar-status":
    print(calendarStatusName(EKEventStore.authorizationStatus(for: .event)))
case "calendar-request":
    runCalendarRequest()
case "calendar-count":
    runCalendarCount()
case "calendar-query":
    var start: Date? = nil, end: Date? = nil, timeout = 10.0
    var i = 1
    while i < args.count {
        if args[i] == "--start", i + 1 < args.count { start = parseTime(args[i + 1]); i += 2 }
        else if args[i] == "--end", i + 1 < args.count { end = parseTime(args[i + 1]); i += 2 }
        else if args[i] == "--timeout", i + 1 < args.count, let t = Double(args[i + 1]), t > 0 { timeout = t; i += 2 }
        else { start = nil; break }
    }
    guard let s = start, let e = end, e >= s else {
        fputs("Usage: calendar-query --start <epoch|ISO8601> --end <epoch|ISO8601> [--timeout SEC]\n", stderr); exit(1)
    }
    runCalendarQuery(start: s, end: e, timeout: timeout)
case "selftest-calendar":
    runSelftestCalendar()
default:
    fputs("Unknown command: \(cmd)\n", stderr); exit(1)
}
