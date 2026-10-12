import AVFoundation
import Foundation

@MainActor
final class VoBLEAudioEngine: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var errorMessage: String?

    private let transport: VoBLEGATTMediaTransport
    private var gate = VoBLEAudioStartGate()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var encoder: VoicePCMEncoder?
    private var playbackTask: Task<Void, Never>?
    private var pendingCapture = Data()
    private var muted = false

    init(transport: VoBLEGATTMediaTransport) { self.transport = transport }

    func setMediaReady(_ ready: Bool) {
        gate.mediaReady = ready
        updateRunningState()
    }

    func setCallKitAudioActive(_ active: Bool) {
        gate.callKitAudioActive = active
        updateRunningState()
    }

    func setMuted(_ value: Bool) {
        muted = value
        encoder?.setMuted(value)
    }

    func stop() {
        gate = VoBLEAudioStartGate()
        stopEngine()
    }

    private func updateRunningState() {
        if gate.canStart {
            if !running { startEngine() }
        } else if running { stopEngine() }
    }

    private func startEngine() {
        do {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let encoder = VoicePCMEncoder()
            encoder.setMuted(muted)
            engine.attach(player)
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 8_000,
                channels: 1, interleaved: false) else {
                throw VoiceAudioError.invalidPlaybackFormat
            }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.channelCount > 0 else { throw VoiceAudioError.microphoneUnavailable }
            input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) {
                [weak self, weak encoder] buffer, _ in
                guard let encoded = encoder?.encode(buffer), !encoded.isEmpty else { return }
                Task { @MainActor [weak self] in self?.acceptCaptured(encoded) }
            }
            engine.prepare()
            try engine.start()
            player.play()
            self.engine = engine; self.player = player; self.encoder = encoder
            running = true; errorMessage = nil
            playbackTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.scheduleNextPlaybackFrame()
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        } catch {
            stopEngine()
            errorMessage = "无法启动蓝牙通话音频：\(error.localizedDescription)"
        }
    }

    private func acceptCaptured(_ data: Data) {
        pendingCapture.append(data)
        while pendingCapture.count >= 320 {
            transport.enqueueCapturedPCM(Data(pendingCapture.prefix(320)))
            pendingCapture.removeFirst(320)
        }
    }

    private func scheduleNextPlaybackFrame() {
        guard running, let player, let frame = transport.dequeuePlayback() else { return }
        let samples = frame.pcm.count / 2
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 8_000,
            channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples)),
              let output = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples)
        frame.pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<samples {
                let bits = UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8
                output[index] = Float(Int16(bitPattern: bits)) / 32_768
            }
        }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    private func stopEngine() {
        playbackTask?.cancel(); playbackTask = nil
        pendingCapture.removeAll(keepingCapacity: true)
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        player?.stop(); player = nil; engine = nil; encoder = nil; running = false
    }
}
