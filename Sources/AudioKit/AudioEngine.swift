import Foundation
import CoreAudio
import AudioToolbox

// REQ-005/021/022 (CR-005): per-device AudioDevice IOProc engine.
//
// The previous engine used an 'ahal' output AudioUnit per device, which
// coreaudiod paces at the system rate (44.1kHz) even when the device runs at
// 48kHz, and an AVAudioEngine tap that can only reach the system default input
// device. Both limits are gone when each device is driven directly:
//
//   capture: one IOProc per device appends the device's input to that device's
//            ring buffer (interleaved float32, the device's native rate).
//   render:  the same IOProc mixes the routed input channels into the device's
//            output. Each input is read from its source ring at
//            sourceRate/renderRate samples per frame (fractional read plus
//            linear interpolation), so devices at different rates still play
//            back at the source's pitch and tempo.
//   sync:    a read head tracks its source write head and never runs ahead of
//            (writeHead - readLagFrames), so a late-starting capture cannot
//            make the reader replay stale ring data (CR-004 generalised).
public final class AudioEngine: ObservableObject {
    public static let inputCount = 4
    public static let outputCount = 4

    // Ring depth (frames, per device input). Must exceed the read lag plus one
    // IO block so the read window never straddles the write region.
    static let ringFrames = 16384        // ~340ms at 48k
    // Steady-state lag of a read head behind its source write head (frames).
    static let readLagFrames = 1536      // ~32ms at 48k
    // REQ-016 (CR-013): peak below this counts as silence (-100dBFS, far under
    // any audible signal) and lets render skip mixing that source.
    static let silenceEpsilon: Float = 1e-5

    // One endpoint per device in use: the device's IOProc, its captured input
    // ring, and the output buses assigned to that device.
    final class Endpoint {
        unowned let engine: AudioEngine
        let device: AudioDeviceID
        var ioProcID: AudioDeviceIOProcID?
        var ring: UnsafeMutablePointer<Float>?   // ringFrames * inChannels
        var inChannels = 2
        var write = 0                            // absolute frames captured
        var rate: Double = 48000
        var hasInput = false
        var hasOutput = false
        var buses: [Int] = []                    // output buses on this device
        // REQ-005/021 (CR-013): only devices feeding an input channel capture.
        var captureNeeded = false
        // REQ-016 (CR-013): absolute frame where continuous silence starts.
        // Frames >= this value are silent (below silenceEpsilon), so a read
        // window entirely inside it can skip the mix loop.
        var silentSinceFrame = 0
        var inPeakL: Float = 0, inPeakR: Float = 0
        var outPeakL: Float = 0, outPeakR: Float = 0
        init(engine: AudioEngine, device: AudioDeviceID) {
            self.engine = engine
            self.device = device
        }
    }

    private var endpoints: [AudioDeviceID: Endpoint] = [:]
    private var inputEndpoint: [Endpoint?] = Array(repeating: nil, count: AudioEngine.inputCount)
    private var outputEndpoint: [Endpoint?] = Array(repeating: nil, count: AudioEngine.outputCount)

    private var inputGain: [Float] = Array(repeating: 1, count: AudioEngine.inputCount)
    private var inputL: [Int] = Array(repeating: 0, count: AudioEngine.inputCount)
    private var inputR: [Int] = Array(repeating: 1, count: AudioEngine.inputCount)
    private var inputActive: [Bool] = Array(repeating: true, count: AudioEngine.inputCount)
    private var outputLevel: [Float] = Array(repeating: 1, count: AudioEngine.outputCount)
    private var outputActive: [Bool] = Array(repeating: true, count: AudioEngine.outputCount)
    private var busRouting: [Set<Int>] = Array(repeating: Set(0..<AudioEngine.inputCount), count: AudioEngine.outputCount)

    // readHeads[input][bus]: absolute source-device frame position.
    private var readHeads: [[Double]] = Array(
        repeating: Array(repeating: -Double(AudioEngine.readLagFrames), count: AudioEngine.outputCount),
        count: AudioEngine.inputCount)

    // Protects every ring, cursor and scalar shared with the IO threads.
    private let lock = NSLock()

    public private(set) var isRunning = false
    public private(set) var outputFramesRendered = 0
    public private(set) var inputFramesPulled = 0
    public private(set) var outputPeak: Float = 0
    public private(set) var inputPeak: Float = 0
    // REQ-014/018: per-channel L/R block peaks for the level meters (display only).
    public var inputLPeaks: [Float] = Array(repeating: 0, count: AudioEngine.inputCount)
    public var inputRPeaks: [Float] = Array(repeating: 0, count: AudioEngine.inputCount)
    public var outputLPeaks: [Float] = Array(repeating: 0, count: AudioEngine.outputCount)
    public var outputRPeaks: [Float] = Array(repeating: 0, count: AudioEngine.outputCount)
    private let meterLock = NSLock()

    // Debug dump (VMIXR_DUMP_OUT / VMIXR_DUMP_SECONDS): accumulate output bus
    // 0's mix as float32 stereo and write a WAV on a background thread, so the
    // audio thread is never blocked by file I/O. Verifies pitch/tempo without
    // depending on the HAL capture clock.
    private let dumpLock = NSLock()
    private var dumpPath: String?
    private var dumpData: [Float] = []
    private var dumpSeconds: Double = 8
    private var dumpStart: Date?
    private var dumpWritten = false
    private var dumpRate: Double = 48000

    public init() {}

    deinit { stop() }

    // Thread-safe snapshot of the meter peaks for main-thread readers
    // (the audio IO threads update the raw values concurrently).
    public func peaksSnapshot() -> (inputL: [Float], inputR: [Float],
                                    outputL: [Float], outputR: [Float],
                                    inputPeak: Float, outputPeak: Float) {
        meterLock.lock()
        defer { meterLock.unlock() }
        return (inputLPeaks, inputRPeaks, outputLPeaks, outputRPeaks, inputPeak, outputPeak)
    }

    // REQ-021/022: build one endpoint per device used by an input or output and
    // start its IOProc.
    public func start(
        sampleRate: Double,
        frameLength: Int,
        inputChannels: [InputChannelConfig],
        outputChannels: [OutputChannelConfig]
    ) -> Bool {
        stop()
        _ = sampleRate; _ = frameLength   // per-device rates are used (CR-005)

        let env = ProcessInfo.processInfo.environment
        dumpLock.lock()
        dumpPath = env["VMIXR_DUMP_OUT"]
        dumpSeconds = Double(env["VMIXR_DUMP_SECONDS"] ?? "8") ?? 8
        dumpData.removeAll()
        dumpStart = nil
        dumpWritten = false
        dumpLock.unlock()
        if let p = dumpPath { NSLog("DIAG dump output0 -> \(p) for \(dumpSeconds)s") }

        lock.lock()
        inputLPeaks = Array(repeating: 0, count: AudioEngine.inputCount)
        inputRPeaks = Array(repeating: 0, count: AudioEngine.inputCount)
        outputLPeaks = Array(repeating: 0, count: AudioEngine.outputCount)
        outputRPeaks = Array(repeating: 0, count: AudioEngine.outputCount)
        inputPeak = 0; outputPeak = 0
        outputFramesRendered = 0; inputFramesPulled = 0
        for i in 0..<AudioEngine.inputCount {
            let c = inputChannels[i]
            inputActive[i] = c.deviceID != 0
            inputGain[i] = c.deviceID == 0 ? 0 : AudioEngine.gainToLinear(c.gainDB) * Float(c.level)
            inputL[i] = c.channelL
            inputR[i] = c.channelR
            inputEndpoint[i] = nil
        }
        for j in 0..<AudioEngine.outputCount {
            let c = outputChannels[j]
            outputActive[j] = c.deviceID != 0
            outputLevel[j] = c.deviceID == 0 ? 0 : Float(c.level)
            busRouting[j] = c.activeInputIndices
            outputEndpoint[j] = nil
        }
        for i in 0..<AudioEngine.inputCount {
            for j in 0..<AudioEngine.outputCount {
                readHeads[i][j] = -Double(AudioEngine.readLagFrames)
            }
        }

        for i in 0..<AudioEngine.inputCount where inputChannels[i].deviceID != 0 {
            let ep = endpoint(for: inputChannels[i].deviceID)
            ep.captureNeeded = true
            inputEndpoint[i] = ep
        }
        for j in 0..<AudioEngine.outputCount where outputChannels[j].deviceID != 0 {
            let ep = endpoint(for: outputChannels[j].deviceID)
            outputEndpoint[j] = ep
            if !ep.buses.contains(j) { ep.buses.append(j) }
        }
        lock.unlock()

        var ok = true
        for ep in endpoints.values {
            guard ep.hasInput || ep.hasOutput else { continue }
            guard startEndpoint(ep) else { ok = false; continue }
        }
        isRunning = ok && !endpoints.isEmpty
        return isRunning
    }

    // REQ-006: the device is gone or disabled; the caller rebuilds by calling
    // start() again. stop() tears every endpoint down.
    public func stop() {
        for ep in endpoints.values { stopEndpoint(ep) }
        lock.lock()
        for ep in endpoints.values { ep.ring?.deallocate(); ep.ring = nil }
        endpoints.removeAll()
        for i in 0..<AudioEngine.inputCount { inputEndpoint[i] = nil }
        for j in 0..<AudioEngine.outputCount { outputEndpoint[j] = nil }
        lock.unlock()
        isRunning = false
    }

    public func setDeviceVolume(_ device: AudioDeviceID, _ value: Float) {
        _ = DeviceVolume.set(device, value)
    }

    // REQ-002 (CR-001 supersedes): capture is now per-device, so there is no
    // single "default input" to configure. Kept for source compatibility.
    public func configureCapture(device: AudioDeviceID?, targetIndices: Set<Int>) {
        _ = device; _ = targetIndices
    }

    // MARK: - endpoint management

    private func endpoint(for device: AudioDeviceID) -> Endpoint {
        if let ep = endpoints[device] { return ep }
        let ep = Endpoint(engine: self, device: device)
        ep.rate = Self.nominalRate(device)
        ep.hasInput = Self.hasStreams(device, input: true)
        ep.hasOutput = Self.hasStreams(device, input: false)
        ep.inChannels = max(1, Self.channelCount(device, input: true))
        if ep.hasInput {
            let ring = UnsafeMutablePointer<Float>.allocate(capacity: AudioEngine.ringFrames * ep.inChannels)
            ring.initialize(repeating: 0, count: AudioEngine.ringFrames * ep.inChannels)
            ep.ring = ring
        }
        endpoints[device] = ep
        return ep
    }

    private func startEndpoint(_ ep: Endpoint) -> Bool {
        let refCon = Unmanaged.passUnretained(ep).toOpaque()
        var ioID: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcID(ep.device, Self.ioProcCallback, refCon, &ioID) == noErr,
              let ioID else { return false }
        if AudioDeviceStart(ep.device, ioID) != noErr {
            AudioDeviceDestroyIOProcID(ep.device, ioID)
            return false
        }
        ep.ioProcID = ioID
        return true
    }

    private func stopEndpoint(_ ep: Endpoint) {
        guard let ioID = ep.ioProcID else { return }
        AudioDeviceStop(ep.device, ioID)
        AudioDeviceDestroyIOProcID(ep.device, ioID)
        ep.ioProcID = nil
    }

    // MARK: - Core Audio helpers

    static func hasStreams(_ device: AudioDeviceID, input: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func channelCount(_ device: AudioDeviceID, input: Bool) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buf) == noErr else { return 0 }
        let list = buf.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableRawPointer(list).advanced(by: 8).assumingMemoryBound(to: AudioBuffer.self)
        var total = 0
        for b in 0..<Int(list.pointee.mNumberBuffers) { total += Int(buffers[b].mNumberChannels) }
        return total
    }

    static func nominalRate(_ device: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return 48000 }
        return rate
    }

    // The HAL allocates mNumberBuffers AudioBuffers contiguously after the
    // AudioBufferList header (mNumberBuffers at offset 0, 4 padding bytes).
    static func bufferArray(_ abl: UnsafeMutablePointer<AudioBufferList>) -> UnsafeMutablePointer<AudioBuffer> {
        UnsafeMutableRawPointer(abl).advanced(by: 8).assumingMemoryBound(to: AudioBuffer.self)
    }

    static func constBufferArray(_ abl: UnsafePointer<AudioBufferList>) -> UnsafePointer<AudioBuffer> {
        UnsafeRawPointer(abl).advanced(by: 8).assumingMemoryBound(to: AudioBuffer.self)
    }

    // MARK: - IO callback

    private static let ioProcCallback: AudioDeviceIOProc = { _, _, inInput, _, outOutput, _, refCon in
        guard let refCon else { return noErr }
        let ep = Unmanaged<Endpoint>.fromOpaque(refCon).takeUnretainedValue()
        return ep.engine.handleIO(ep: ep, inInput: inInput, outOutput: outOutput)
    }

    private func handleIO(ep: Endpoint,
                          inInput: UnsafePointer<AudioBufferList>?,
                          outOutput: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        // REQ-005/021 (CR-013): a full-duplex device used only as an output has
        // no reader for its input ring, so capturing it is wasted work.
        if ep.captureNeeded, let inInput { capture(ep, inInput) }
        if ep.hasOutput, let outOutput { render(ep, outOutput) }
        return noErr
    }

    // REQ-021: append the device's input frames to its ring buffer.
    private func capture(_ ep: Endpoint, _ abl: UnsafePointer<AudioBufferList>) {
        guard abl.pointee.mNumberBuffers >= 1, let ring = ep.ring else { return }
        let b0 = Self.constBufferArray(abl)[0]
        let ch = max(1, Int(b0.mNumberChannels))
        guard let data = b0.mData else { return }
        let n = Int(b0.mDataByteSize) / (4 * ch)
        guard n > 0 else { return }
        let src = data.assumingMemoryBound(to: Float.self)
        let stored = min(ch, ep.inChannels)
        var pl: Float = 0
        var pr: Float = 0
        for f in 0..<n {
            let pos = ((ep.write + f) % AudioEngine.ringFrames + AudioEngine.ringFrames) % AudioEngine.ringFrames
            let dst = ring + pos * ep.inChannels
            for c in 0..<ep.inChannels {
                let raw: Float = c < stored ? src[f * ch + c] : 0
                dst[c] = raw.isFinite ? raw : 0
            }
            let a = abs(dst[0])
            if a > pl { pl = a }
            if ep.inChannels >= 2 {
                let b = abs(dst[1])
                if b > pr { pr = b }
            }
        }
        ep.write += n
        // REQ-016 (CR-013): any audible sample in this block pushes the silence
        // start past it, so render keeps mixing until the source goes quiet.
        if max(pl, pr) >= Self.silenceEpsilon {
            ep.silentSinceFrame = ep.write
        }
        ep.inPeakL = pl
        ep.inPeakR = pr
        inputFramesPulled += n
        meterLock.lock()
        inputPeak = max(inputPeak, max(pl, pr))
        for i in 0..<AudioEngine.inputCount where inputEndpoint[i] === ep {
            inputLPeaks[i] = pl
            inputRPeaks[i] = pr
        }
        meterLock.unlock()
    }

    // REQ-016/022/CR-005: mix the routed input channels into the device output.
    // Each input is read from its source ring at sourceRate/renderRate samples
    // per frame (CR-003) with a fractional read head clamped to the source write
    // head (CR-004).
    private func render(_ ep: Endpoint, _ abl: UnsafeMutablePointer<AudioBufferList>) {
        guard abl.pointee.mNumberBuffers >= 1 else { return }
        let bufs = Self.bufferArray(abl)
        let ch = max(1, Int(bufs[0].mNumberChannels))
        let n = Int(bufs[0].mDataByteSize) / (4 * ch)
        guard n > 0 else { return }
        let outRate = ep.rate > 0 ? ep.rate : 48000

        // REQ-016/022 (CR-013): decide once per block which (input, bus) pairs
        // are worth mixing. A pair is skipped when its bus/input is inactive,
        // its level is zero, or its read window lies entirely inside the
        // source's tracked silence - all of which contribute exactly zero.
        var pairMask: UInt16 = 0
        var busMask: UInt16 = 0
        for j in ep.buses where j < AudioEngine.outputCount && outputActive[j] && outputLevel[j] != 0 {
            for i in busRouting[j] where i < AudioEngine.inputCount && inputActive[i] {
                guard let src = inputEndpoint[i], src.ring != nil, src.inChannels > 0 else { continue }
                guard readHeads[i][j] < Double(src.silentSinceFrame) else { continue }
                pairMask |= UInt16(1) << UInt16(i * AudioEngine.outputCount + j)
                busMask |= UInt16(1) << UInt16(j)
            }
        }

        // REQ-016 (CR-013): nothing to mix (silent idle, inactive bus, or an
        // input-only device with no buses) - write silence instead of running
        // the mix loop.
        if busMask == 0 {
            zeroFill(bufs, numBuf: Int(abl.pointee.mNumberBuffers))
            if ep.buses.contains(0) {
                for _ in 0..<n { appendDump(l: 0, r: 0, rate: outRate) }
            }
            outputFramesRendered += n
            ep.outPeakL = 0
            ep.outPeakR = 0
            meterLock.lock()
            for j in ep.buses where j < AudioEngine.outputCount {
                outputLPeaks[j] = 0
                outputRPeaks[j] = 0
            }
            meterLock.unlock()
            return
        }

        var peakL: Float = 0
        var peakR: Float = 0
        for f in 0..<n {
            var l: Float = 0
            var r: Float = 0
            for j in ep.buses where j < AudioEngine.outputCount && outputActive[j]
                && ((busMask >> UInt16(j)) & 1) == 1 {
                let level = outputLevel[j]
                var bl: Float = 0
                var br: Float = 0
                for i in busRouting[j] where i < AudioEngine.inputCount && inputActive[i]
                    && ((pairMask >> UInt16(i * AudioEngine.outputCount + j)) & 1) == 1 {
                    guard let src = inputEndpoint[i], let sring = src.ring, src.inChannels > 0 else { continue }
                    let pos = readHeads[i][j] + Double(f) * (src.rate / outRate)
                    let fi = Int(pos.rounded(.down))
                    let frac = Float(pos - Double(fi))
                    let cL = min(max(inputL[i], 0), src.inChannels - 1)
                    let cR = min(max(inputR[i], 0), src.inChannels - 1)
                    let i0 = ((fi % AudioEngine.ringFrames) + AudioEngine.ringFrames) % AudioEngine.ringFrames
                    let i1 = (i0 + 1) % AudioEngine.ringFrames
                    let s0 = sring + i0 * src.inChannels
                    let s1 = sring + i1 * src.inChannels
                    let g = inputGain[i]
                    bl += (s0[cL] * (1 - frac) + s1[cL] * frac) * g
                    br += (s0[cR] * (1 - frac) + s1[cR] * frac) * g
                }
                l += bl * level
                r += br * level
                if j == 0 { appendDump(l: bl * level, r: br * level, rate: outRate) }
            }
            let al = abs(l), ar = abs(r)
            if al > peakL { peakL = al }
            if ar > peakR { peakR = ar }
            writeFrame(bufs, numBuf: Int(abl.pointee.mNumberBuffers), ch: ch, f: f, l: l, r: r)
        }

        // Advance the read heads by the block in the source timescale, clamped
        // so a head never runs ahead of (sourceWrite - readLagFrames).
        for j in ep.buses where j < AudioEngine.outputCount {
            for i in busRouting[j] where i < AudioEngine.inputCount && inputActive[i] {
                guard let src = inputEndpoint[i] else { continue }
                let base = readHeads[i][j]
                let advanced = base + Double(n) * (src.rate / outRate)
                let target = Double(src.write) - Double(AudioEngine.readLagFrames)
                readHeads[i][j] = max(base, min(advanced, target))
            }
        }

        outputFramesRendered += n
        ep.outPeakL = peakL
        ep.outPeakR = peakR
        meterLock.lock()
        outputPeak = max(outputPeak, max(peakL, peakR))
        for j in ep.buses where j < AudioEngine.outputCount {
            outputLPeaks[j] = peakL
            outputRPeaks[j] = peakR
        }
        meterLock.unlock()
    }

    // Write one stereo frame to the device output, honouring interleaved (one
    // buffer) or per-channel (one buffer per channel) layouts.
    private func writeFrame(_ bufs: UnsafeMutablePointer<AudioBuffer>, numBuf: Int, ch: Int, f: Int, l: Float, r: Float) {
        if numBuf <= 1 {
            guard let dst = bufs[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            for c in 0..<ch { dst[f * ch + c] = (c == 0) ? l : ((c == 1) ? r : 0) }
        } else {
            for b in 0..<numBuf {
                guard let dst = bufs[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
                dst[f] = (b == 0) ? l : ((b == 1) ? r : 0)
            }
        }
    }

    // REQ-016 (CR-013): write silence to the whole output block, honouring the
    // same interleaved / per-channel layouts as writeFrame.
    private func zeroFill(_ bufs: UnsafeMutablePointer<AudioBuffer>, numBuf: Int) {
        if numBuf <= 1 {
            guard let dst = bufs[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            dst.initialize(repeating: 0, count: Int(bufs[0].mDataByteSize) / 4)
        } else {
            for b in 0..<numBuf {
                guard let dst = bufs[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
                dst.initialize(repeating: 0, count: Int(bufs[b].mDataByteSize) / 4)
            }
        }
    }

    // Debug: accumulate output bus 0's mix while the dump window is open.
    private func appendDump(l: Float, r: Float, rate: Double) {
        dumpLock.lock()
        guard let path = dumpPath, !dumpWritten else { dumpLock.unlock(); return }
        if dumpStart == nil { dumpStart = Date(); dumpRate = rate }
        let dt = Date().timeIntervalSince(dumpStart ?? Date())
        guard dt <= dumpSeconds else { dumpLock.unlock(); return }
        if dumpData.isEmpty { dumpData.reserveCapacity(Int(dumpSeconds * 48000) * 2) }
        dumpData.append(l)
        dumpData.append(r)
        if dt >= dumpSeconds - 0.05 {
            dumpWritten = true
            let snap = dumpData
            dumpData.removeAll()
            let sr = dumpRate > 0 ? dumpRate : 48000
            dumpLock.unlock()
            DispatchQueue.global(qos: .userInitiated).async {
                Self.writeDumpWAV(path: path, frames: snap, rate: sr)
                NSLog("DIAG wrote dump \(path) frames=\(snap.count / 2) rate=\(sr)")
            }
            return
        }
        dumpLock.unlock()
    }

    static func writeDumpWAV(path: String, frames: [Float], rate: Double) {
        let n = frames.count / 2
        let ch = 2
        func fourCC(_ s: String) -> UInt32 {
            var v: UInt32 = 0
            for (i, c) in Array(s.utf8).enumerated() { v |= UInt32(c) << (8 * i) }
            return v
        }
        var data = Data()
        func a32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(Data($0)) } }
        func a16(_ v: Int16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(Data($0)) } }
        let sr = UInt32(max(1, rate.rounded()))
        a32(fourCC("RIFF")); a32(36 + UInt32(n) * UInt32(ch) * 4); a32(fourCC("WAVE")); a32(fourCC("fmt "))
        a32(16); a16(3); a16(Int16(ch)); a32(sr); a32(sr * UInt32(ch) * 4); a16(Int16(ch * 4)); a16(Int16(32))
        a32(fourCC("data")); a32(UInt32(n) * UInt32(ch) * 4)
        for i in 0..<n {
            for c in 0..<ch {
                var le = frames[i * ch + c].bitPattern.littleEndian
                withUnsafeBytes(of: &le) { data.append(Data($0)) }
            }
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - live parameter updates (REQ-011..013/016/017)

    public func updateInput(_ i: Int, active: Bool, level: Double, gainDB: Double,
                            channelL: Int, channelR: Int) {
        lock.lock()
        inputActive[i] = active
        inputGain[i] = active ? AudioEngine.gainToLinear(gainDB) * Float(level) : 0
        inputL[i] = channelL
        inputR[i] = channelR
        lock.unlock()
    }

    public func updateOutput(_ j: Int, active: Bool, level: Double, activeInputIndices: Set<Int>) {
        lock.lock()
        outputActive[j] = active
        outputLevel[j] = active ? Float(level) : 0
        busRouting[j] = activeInputIndices
        lock.unlock()
    }

    public static func gainToLinear(_ db: Double) -> Float {
        db <= -60 ? 0 : Float(pow(10, db / 20))
    }
}

// configuration passed to the engine (decoupled from the UI model)
public struct InputChannelConfig {
    public var deviceID: AudioDeviceID
    public var inputChannelCount: Int
    public var channelL: Int
    public var channelR: Int
    public var level: Double
    public var gainDB: Double
    public init(deviceID: AudioDeviceID, inputChannelCount: Int, channelL: Int, channelR: Int,
                level: Double, gainDB: Double) {
        self.deviceID = deviceID
        self.inputChannelCount = inputChannelCount
        self.channelL = channelL
        self.channelR = channelR
        self.level = level
        self.gainDB = gainDB
    }
}

public struct OutputChannelConfig {
    public var deviceID: AudioDeviceID
    public var level: Double
    public var activeInputIndices: Set<Int>
    public init(deviceID: AudioDeviceID, level: Double, activeInputIndices: Set<Int>) {
        self.deviceID = deviceID
        self.level = level
        self.activeInputIndices = activeInputIndices
    }
}
