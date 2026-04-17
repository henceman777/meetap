import AudioToolbox
import CoreAudio
import Foundation

// 从指定输入设备实时转发音频到指定输出设备
// 用法: audio-monitor <input-device-uid> <output-device-uid>
// 使用底层 AudioUnit API，手动处理格式匹配

func findDeviceID(uid: String) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
    for id in ids {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var val: CFString? = nil
        var s = UInt32(MemoryLayout<CFString?>.size)
        if AudioObjectGetPropertyData(id, &propAddr, 0, nil, &s, &val) == noErr,
           let v = val as String?, v == uid { return id }
    }
    return nil
}

func getStreamFormat(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamFormat,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain)
    var fmt = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &fmt) == noErr else { return nil }
    return fmt
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    fputs("Usage: audio-monitor <input-device-uid> <output-device-uid>\n", stderr)
    exit(1)
}

let inputUID = args[0]
let outputUID = args[1]

guard let inputID = findDeviceID(uid: inputUID) else {
    fputs("Error: input device not found: \(inputUID)\n", stderr); exit(1)
}
guard let outputID = findDeviceID(uid: outputUID) else {
    fputs("Error: output device not found: \(outputUID)\n", stderr); exit(1)
}

// 获取设备格式信息
guard let inputFmt = getStreamFormat(inputID, scope: kAudioObjectPropertyScopeInput) else {
    fputs("Error: cannot get input device format\n", stderr); exit(1)
}
guard let outputFmt = getStreamFormat(outputID, scope: kAudioObjectPropertyScopeOutput) else {
    fputs("Error: cannot get output device format\n", stderr); exit(1)
}

fputs("Input:  \(inputUID) — \(inputFmt.mSampleRate)Hz, \(inputFmt.mChannelsPerFrame)ch\n", stderr)
fputs("Output: \(outputUID) — \(outputFmt.mSampleRate)Hz, \(outputFmt.mChannelsPerFrame)ch\n", stderr)

// 创建输入 AUHAL (kAudioUnitSubType_HALOutput)
var inputComp = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0)
guard let comp = AudioComponentFindNext(nil, &inputComp) else {
    fputs("Error: cannot find HALOutput component\n", stderr); exit(1)
}
var inputUnit: AudioUnit?
guard AudioComponentInstanceNew(comp, &inputUnit) == noErr, let inputAU = inputUnit else {
    fputs("Error: cannot create input AudioUnit\n", stderr); exit(1)
}

// 启用输入，禁用输出（这个 AU 只做采集）
var enableIO: UInt32 = 1
var disableIO: UInt32 = 0
AudioUnitSetProperty(inputAU, kAudioOutputUnitProperty_EnableIO,
    kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size))
AudioUnitSetProperty(inputAU, kAudioOutputUnitProperty_EnableIO,
    kAudioUnitScope_Output, 0, &disableIO, UInt32(MemoryLayout<UInt32>.size))

// 设置输入设备
var inDevID = inputID
AudioUnitSetProperty(inputAU, kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global, 0, &inDevID, UInt32(MemoryLayout<AudioDeviceID>.size))

// 创建输出 AUHAL
var outputUnit: AudioUnit?
guard AudioComponentInstanceNew(comp, &outputUnit) == noErr, let outputAU = outputUnit else {
    fputs("Error: cannot create output AudioUnit\n", stderr); exit(1)
}

// 输出 AU 只做播放（默认就是 output enabled, input disabled）
var outDevID = outputID
AudioUnitSetProperty(outputAU, kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global, 0, &outDevID, UInt32(MemoryLayout<AudioDeviceID>.size))

// 使用输入设备的格式作为中间格式（Float32 PCM）
var streamFmt = AudioStreamBasicDescription(
    mSampleRate: inputFmt.mSampleRate,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4,
    mFramesPerPacket: 1,
    mBytesPerFrame: 4,
    mChannelsPerFrame: inputFmt.mChannelsPerFrame,
    mBitsPerChannel: 32,
    mReserved: 0)

// 设置输入 AU 的输出格式（从 input bus 1 读取的数据格式）
AudioUnitSetProperty(inputAU, kAudioUnitProperty_StreamFormat,
    kAudioUnitScope_Output, 1, &streamFmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

// 设置输出 AU 的输入格式（写入 output bus 0 的数据格式）
// 如果采样率不同，CoreAudio 会自动做采样率转换
AudioUnitSetProperty(outputAU, kAudioUnitProperty_StreamFormat,
    kAudioUnitScope_Input, 0, &streamFmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

// 环形缓冲区（线程安全的简单实现）
let bufferSize = 65536 * Int(inputFmt.mChannelsPerFrame)
let ringBuffer = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
ringBuffer.initialize(repeating: 0, count: bufferSize)
var writePos: Int64 = 0
var readPos: Int64 = 0

// 输入回调：从输入设备读取数据
let inputCallback: AURenderCallback = { (
    inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData
) -> OSStatus in
    let ctx = inRefCon.assumingMemoryBound(to: AudioMonitorContext.self)

    // 准备缓冲区来接收输入数据
    let channels = Int(ctx.pointee.channels)
    let bufList = AudioBufferList.allocate(maximumBuffers: channels)
    for i in 0..<channels {
        bufList[i] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: inNumberFrames * 4,
            mData: UnsafeMutableRawPointer.allocate(byteCount: Int(inNumberFrames) * 4, alignment: 4))
    }

    let st = AudioUnitRender(ctx.pointee.inputAU, ioActionFlags, inTimeStamp, 1, inNumberFrames, bufList.unsafeMutablePointer)
    if st == noErr {
        let frames = Int(inNumberFrames)
        let bufSize = ctx.pointee.bufferSize
        let wp = Int(ctx.pointee.writePos % Int64(bufSize / channels))

        // 拷贝所有通道数据到环形缓冲区
        for ch in 0..<channels {
            let src = bufList[ch].mData!.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                let idx = ((wp + f) % (bufSize / channels)) * channels + ch
                ctx.pointee.ringBuffer[idx] = src[f]
            }
        }
        ctx.pointee.writePos += Int64(frames)
    }

    for i in 0..<channels {
        bufList[i].mData?.deallocate()
    }
    free(bufList.unsafeMutablePointer)

    return noErr
}

// 输出回调：向输出设备提供数据
let outputCallback: AURenderCallback = { (
    inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData
) -> OSStatus in
    guard let bufferList = ioData else { return noErr }
    let ctx = inRefCon.assumingMemoryBound(to: AudioMonitorContext.self)
    let channels = Int(ctx.pointee.channels)
    let frames = Int(inNumberFrames)
    let bufSize = ctx.pointee.bufferSize

    let available = ctx.pointee.writePos - ctx.pointee.readPos
    let rp = Int(ctx.pointee.readPos % Int64(bufSize / channels))

    let abl = UnsafeMutableAudioBufferListPointer(bufferList)

    if available >= Int64(frames) {
        for ch in 0..<min(channels, abl.count) {
            let dst = abl[ch].mData!.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                let idx = ((rp + f) % (bufSize / channels)) * channels + ch
                dst[f] = ctx.pointee.ringBuffer[idx]
            }
        }
        ctx.pointee.readPos += Int64(frames)
    } else {
        // 欠载：输出静音
        for ch in 0..<abl.count {
            memset(abl[ch].mData, 0, Int(abl[ch].mDataByteSize))
        }
    }

    return noErr
}

// 上下文结构体
struct AudioMonitorContext {
    var inputAU: AudioUnit
    var ringBuffer: UnsafeMutablePointer<Float>
    var bufferSize: Int
    var writePos: Int64
    var readPos: Int64
    var channels: UInt32
}

var context = AudioMonitorContext(
    inputAU: inputAU,
    ringBuffer: ringBuffer,
    bufferSize: bufferSize,
    writePos: 0,
    readPos: 0,
    channels: inputFmt.mChannelsPerFrame)

let contextPtr = UnsafeMutablePointer<AudioMonitorContext>.allocate(capacity: 1)
contextPtr.initialize(to: context)

// 设置输入回调
var inputCB = AURenderCallbackStruct(inputProc: inputCallback, inputProcRefCon: contextPtr)
AudioUnitSetProperty(inputAU, kAudioOutputUnitProperty_SetInputCallback,
    kAudioUnitScope_Global, 0, &inputCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

// 设置输出回调
var outputCB = AURenderCallbackStruct(inputProc: outputCallback, inputProcRefCon: contextPtr)
AudioUnitSetProperty(outputAU, kAudioUnitProperty_SetRenderCallback,
    kAudioUnitScope_Input, 0, &outputCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

// 初始化并启动
guard AudioUnitInitialize(inputAU) == noErr else {
    fputs("Error: cannot initialize input AudioUnit\n", stderr); exit(1)
}
guard AudioUnitInitialize(outputAU) == noErr else {
    fputs("Error: cannot initialize output AudioUnit\n", stderr); exit(1)
}
guard AudioOutputUnitStart(inputAU) == noErr else {
    fputs("Error: cannot start input AudioUnit\n", stderr); exit(1)
}
guard AudioOutputUnitStart(outputAU) == noErr else {
    fputs("Error: cannot start output AudioUnit\n", stderr); exit(1)
}

fputs("Monitoring: \(inputUID) → \(outputUID)\n", stderr)
fputs("Press Ctrl+C to stop.\n", stderr)

signal(SIGINT) { _ in
    fputs("\nStopping monitor...\n", stderr)
    exit(0)
}
signal(SIGTERM) { _ in
    exit(0)
}

RunLoop.current.run()
