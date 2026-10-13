import CryptoKit
import Foundation

enum VoBLEMediaDirection: UInt8, Sendable {
    case uplink = 1
    case downlink = 2
}

struct VoBLESealedAudio: Equatable, Sendable {
    let payload: Data
    let authenticationTag: Data
}

enum VoBLEMediaCipher {
    static func seal(
        _ plaintext: Data, key: Data, direction: VoBLEMediaDirection,
        streamID: UInt8, sequence: UInt32, timestamp: UInt32
    ) throws -> VoBLESealedAudio {
        let box = try AES.GCM.seal(
            plaintext, using: try symmetricKey(key),
            nonce: try AES.GCM.Nonce(data: nonce(
                direction: direction, streamID: streamID,
                sequence: sequence, timestamp: timestamp)),
            authenticating: aad(direction: direction, streamID: streamID,
                                sequence: sequence, timestamp: timestamp)
        )
        return VoBLESealedAudio(payload: box.ciphertext, authenticationTag: box.tag)
    }

    static func open(
        _ value: VoBLESealedAudio, key: Data, direction: VoBLEMediaDirection,
        streamID: UInt8, sequence: UInt32, timestamp: UInt32
    ) throws -> Data {
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce(
                direction: direction, streamID: streamID,
                sequence: sequence, timestamp: timestamp)),
            ciphertext: value.payload, tag: value.authenticationTag)
        return try AES.GCM.open(
            box, using: try symmetricKey(key),
            authenticating: aad(direction: direction, streamID: streamID,
                                sequence: sequence, timestamp: timestamp))
    }

    private static func symmetricKey(_ data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw VoBLEPairingError.invalidKey }
        return SymmetricKey(data: data)
    }

    private static func nonce(
        direction: VoBLEMediaDirection, streamID: UInt8,
        sequence: UInt32, timestamp: UInt32
    ) -> Data {
        var value = Data([direction.rawValue, streamID, 0, 0])
        append(timestamp, to: &value)
        append(sequence, to: &value)
        return value
    }

    private static func aad(
        direction: VoBLEMediaDirection, streamID: UInt8,
        sequence: UInt32, timestamp: UInt32
    ) -> Data {
        var value = Data([direction.rawValue, VoBLEAudioCodec.g711MuLaw.rawValue, streamID])
        append(sequence, to: &value)
        append(timestamp, to: &value)
        return value
    }

    private static func append(_ number: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: number >> 24))
        data.append(UInt8(truncatingIfNeeded: number >> 16))
        data.append(UInt8(truncatingIfNeeded: number >> 8))
        data.append(UInt8(truncatingIfNeeded: number))
    }
}

enum VoBLEMULaw {
    static func encode(_ pcm: Data) -> Data {
        guard pcm.count.isMultiple(of: 2) else { return Data() }
        var output = Data(capacity: pcm.count / 2)
        pcm.withUnsafeBytes { bytes in
            let input = bytes.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: input.count, by: 2) {
                let bits = UInt16(input[offset]) | UInt16(input[offset + 1]) << 8
                output.append(linearToMuLaw(Int(Int16(bitPattern: bits))))
            }
        }
        return output
    }

    static func decode(_ encoded: Data) -> Data {
        var output = Data(capacity: encoded.count * 2)
        for byte in encoded {
            let sample = muLawToLinear(byte)
            output.append(UInt8(truncatingIfNeeded: sample))
            output.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return output
    }

    private static func linearToMuLaw(_ input: Int) -> UInt8 {
        let bias = 0x84
        var sample = input
        let sign = (sample >> 8) & 0x80
        if sign != 0 { sample = -sample }
        sample = min(32_635, sample) + bias
        var exponent = 7
        var mask = 0x4000
        while exponent > 0, sample & mask == 0 { exponent -= 1; mask >>= 1 }
        let mantissa = (sample >> (exponent + 3)) & 0x0f
        return UInt8(truncatingIfNeeded: ~(sign | exponent << 4 | mantissa))
    }

    private static func muLawToLinear(_ input: UInt8) -> Int16 {
        let value = Int(~input)
        let sign = value & 0x80
        let exponent = (value >> 4) & 0x07
        let mantissa = value & 0x0f
        let magnitude = (((mantissa << 3) + 0x84) << exponent) - 0x84
        return Int16(sign == 0 ? magnitude : -magnitude)
    }
}

struct VoBLEPlaybackFrame: Equatable, Sendable {
    let sequence: UInt32
    let pcm: Data
    let concealed: Bool
}

struct VoBLEJitterBuffer: Sendable {
    private(set) var targetFrames: Int
    private var frames: [UInt32: Data] = [:]
    private var expected: UInt32?
    private var started = false
    private var lastPCM: Data?
    private var seen: Set<UInt32> = []
    private var stableFrameCount = 0
    private(set) var skippedFrames = 0

    init(targetFrames: Int = 4) {
        self.targetFrames = min(8, max(3, targetFrames))
    }

    mutating func insert(sequence: UInt32, pcm: Data) -> Bool {
        guard pcm.count == 320, !seen.contains(sequence) else { return false }
        if let expected, sequence < expected { return false }
        if frames.count >= 8, let oldest = frames.keys.min() {
            guard sequence > oldest else { return false }
            frames.removeValue(forKey: oldest)
            skippedFrames += 1
            // Keep latency bounded after a scheduling stall. Rejecting all new
            // packets leaves old speech in the buffer and causes repeated PLC.
            expected = frames.keys.min()
            noteDiscontinuity()
        }
        seen.insert(sequence); frames[sequence] = pcm
        if seen.count > 256, let oldest = seen.min() { seen.remove(oldest) }
        if expected == nil { expected = frames.keys.min() }
        if frames.count >= targetFrames { started = true }
        return true
    }

    mutating func noteDiscontinuity() {
        targetFrames = min(8, targetFrames + 1)
        stableFrameCount = 0
    }

    mutating func dequeue() -> VoBLEPlaybackFrame? {
        guard started, var sequence = expected else { return nil }
        guard let next = frames.keys.min() else {
            // No packet proves a gap yet. Do not advance the sample clock and
            // reject the very next packet when notifications resume.
            started = false
            return nil
        }
        if next > sequence, next - sequence > 8 {
            skippedFrames += Int(next - sequence)
            sequence = next
            noteDiscontinuity()
        }
        expected = sequence &+ 1
        if let pcm = frames.removeValue(forKey: sequence) {
            lastPCM = pcm
            stableFrameCount += 1
            if stableFrameCount >= 50, targetFrames > 3 {
                targetFrames -= 1
                stableFrameCount = 0
            }
            return VoBLEPlaybackFrame(sequence: sequence, pcm: pcm, concealed: false)
        }
        guard let previous = lastPCM, frames.keys.contains(where: { $0 > sequence }) else { return nil }
        var faded = Data(capacity: previous.count)
        previous.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: bytes.count, by: 2) {
                let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                let sample = Int16(bitPattern: bits)
                let attenuated = Int16(Float(sample) * 0.85)
                faded.append(UInt8(truncatingIfNeeded: attenuated))
                faded.append(UInt8(truncatingIfNeeded: attenuated >> 8))
            }
        }
        lastPCM = faded
        noteDiscontinuity()
        return VoBLEPlaybackFrame(sequence: sequence, pcm: faded, concealed: true)
    }

    mutating func reset() { self = VoBLEJitterBuffer(targetFrames: targetFrames) }
}

struct VoBLEMediaSessionIdentity: Equatable, Sendable {
    let callID: String
    let generation: UInt64
}

@MainActor
protocol VoBLEMediaWriting: AnyObject {
    var canSendWriteWithoutResponse: Bool { get }
    var maximumWriteLength: Int { get }
    func writeWithoutResponse(_ data: Data)
}

/// Crypto, G.711 and jitter-buffer work runs on a dedicated serial queue. BLE
/// callbacks arrive on the main actor, but a 20 ms media cadence must never make
/// SwiftUI and CallKit process every audio frame synchronously.
private final class VoBLEMediaCodecWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.example.airsim.voble.media-codec", qos: .userInteractive)
    private var identity: VoBLEMediaSessionIdentity?
    private var mediaKey = Data()
    private var sequence: UInt32 = 0
    private var timestamp: UInt32 = 0
    private var downlink = VoBLEAudioReassembler()
    private var jitter = VoBLEJitterBuffer()
    private var receivedSequences: Set<UInt32> = []
    private var dropped = 0
    private var received = 0
    private var replayDrops = 0
    private var jitterDrops = 0
    private var invalidDrops = 0
    private var concealed = 0

    func start(identity: VoBLEMediaSessionIdentity, mediaKey: Data) {
        queue.sync {
            self.identity = identity; self.mediaKey = mediaKey
            sequence = 0; timestamp = 0; downlink = VoBLEAudioReassembler()
            jitter.reset(); receivedSequences.removeAll(); dropped = 0
            received = 0; replayDrops = 0; jitterDrops = 0; invalidDrops = 0; concealed = 0
        }
    }

    func stop(identity candidate: VoBLEMediaSessionIdentity) {
        queue.sync {
            guard candidate == identity else { return }
            identity = nil; mediaKey.removeAll(); jitter.reset(); receivedSequences.removeAll()
        }
    }

    func encode(
        pcm: Data, discontinuity: Bool, maximumPacketLength: Int,
        completion: @escaping @Sendable ([Data]?) -> Void
    ) {
        queue.async { [self] in
            guard identity != nil, pcm.count == 320 else { completion(nil); return }
            do {
                let compressed = VoBLEMULaw.encode(pcm)
                let sealed = try VoBLEMediaCipher.seal(
                    compressed, key: mediaKey, direction: .uplink, streamID: 1,
                    sequence: sequence, timestamp: timestamp)
                let packet = VoBLEAudioPacket(
                    flags: discontinuity ? [.discontinuity] : [],
                    codec: .g711MuLaw, streamID: 1, sequence: sequence,
                    sampleTimestamp: timestamp, payload: sealed.payload,
                    authenticationTag: sealed.authenticationTag)
                sequence &+= 1; timestamp &+= 160
                completion(try packet.encodedFragments(maximumPacketLength: maximumPacketLength))
            } catch {
                dropped += 1
                completion(nil)
            }
        }
    }

    func receive(_ fragment: Data, now: Date) {
        queue.async { [self] in
            guard identity != nil else { return }
            do {
                guard let packet = try downlink.append(fragment, now: now) else { return }
                guard !receivedSequences.contains(packet.sequence) else {
                    dropped += 1; replayDrops += 1; return
                }
                let compressed = try VoBLEMediaCipher.open(
                    .init(payload: packet.payload, authenticationTag: packet.authenticationTag),
                    key: mediaKey, direction: .downlink, streamID: packet.streamID,
                    sequence: packet.sequence, timestamp: packet.sampleTimestamp)
                receivedSequences.insert(packet.sequence)
                received += 1
                if receivedSequences.count > 256, let oldest = receivedSequences.min() {
                    receivedSequences.remove(oldest)
                }
                if packet.flags.contains(.discontinuity) { jitter.noteDiscontinuity() }
                if !jitter.insert(sequence: packet.sequence, pcm: VoBLEMULaw.decode(compressed)) {
                    dropped += 1; jitterDrops += 1
                }
            } catch { dropped += 1; invalidDrops += 1 }
        }
    }

    func dequeue() -> VoBLEPlaybackFrame? {
        queue.sync {
            let frame = jitter.dequeue()
            if frame?.concealed == true { concealed += 1 }
            return frame
        }
    }
    func droppedCount() -> Int { queue.sync { dropped } }
    func diagnosticSummary() -> String {
        queue.sync {
            "received=\(received) replay=\(replayDrops) late=\(jitterDrops) invalid=\(invalidDrops) skipped=\(jitter.skippedFrames) concealed=\(concealed)"
        }
    }
    func jitterTarget() -> Int { queue.sync { jitter.targetFrames } }
}

@MainActor
final class VoBLEGATTMediaTransport {
    private struct QueuedFrame { var fragments: [Data] }
    private let writer: any VoBLEMediaWriting
    private var identity: VoBLEMediaSessionIdentity?
    private var mediaKey = Data()
    private var queued: [QueuedFrame] = []
    private var localDroppedFrameCount = 0
    private let codec = VoBLEMediaCodecWorker()

    init(writer: any VoBLEMediaWriting) { self.writer = writer }
    var queuedFrameCount: Int { queued.count }
    var isRunning: Bool { identity != nil }
    var droppedFrameCount: Int { localDroppedFrameCount + codec.droppedCount() }
    var diagnosticSummary: String { codec.diagnosticSummary() }
    var jitterTargetFrames: Int { codec.jitterTarget() }

    func start(identity: VoBLEMediaSessionIdentity, mediaKey: Data) throws {
        guard !identity.callID.isEmpty, identity.generation > 0, mediaKey.count == 32 else {
            throw VoBLEPairingError.invalidKey
        }
        self.identity = identity; self.mediaKey = mediaKey
        queued.removeAll(); localDroppedFrameCount = 0
        codec.start(identity: identity, mediaKey: mediaKey)
    }

    func stop(identity candidate: VoBLEMediaSessionIdentity) {
        guard candidate == identity else { return }
        identity = nil; mediaKey.removeAll(); queued.removeAll()
        codec.stop(identity: candidate)
    }

    func enqueueCapturedPCM(_ pcm: Data) {
        guard identity != nil, pcm.count == 320 else { return }
        let discontinuity = queued.count >= 8
        if discontinuity { queued.removeFirst(); localDroppedFrameCount += 1 }
        let maximumLength = writer.maximumWriteLength
        codec.encode(pcm: pcm, discontinuity: discontinuity, maximumPacketLength: maximumLength) {
            [weak self] fragments in
            Task { @MainActor in
                guard let self, self.identity != nil else { return }
                guard let fragments else { self.localDroppedFrameCount += 1; return }
                if self.queued.count >= 8 {
                    self.queued.removeFirst(); self.localDroppedFrameCount += 1
                }
                self.queued.append(QueuedFrame(fragments: fragments))
                self.drain()
            }
        }
    }

    func peripheralIsReadyToSend() { drain() }

    func receiveDownlinkFragment(_ fragment: Data, now: Date = Date()) {
        guard identity != nil else { return }
        codec.receive(fragment, now: now)
    }

    func dequeuePlayback() -> VoBLEPlaybackFrame? { codec.dequeue() }

    private func drain() {
        while writer.canSendWriteWithoutResponse, !queued.isEmpty {
            var frame = queued.removeFirst()
            while writer.canSendWriteWithoutResponse, !frame.fragments.isEmpty {
                let fragment = frame.fragments.removeFirst()
                writer.writeWithoutResponse(fragment)
            }
            if !frame.fragments.isEmpty {
                queued.insert(frame, at: 0)
                return
            }
        }
    }
}

struct VoBLEAudioStartGate: Equatable, Sendable {
    var mediaReady = false
    var callKitAudioActive = false
    var appAudioSessionActive = false
    var canStart: Bool { mediaReady && (callKitAudioActive || appAudioSessionActive) }
}
