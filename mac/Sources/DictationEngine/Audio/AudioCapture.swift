@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// A single capture. Built fresh for every dictation.
public protocol MicCapture: AnyObject, Sendable {
    /// Starts capture and returns once frames actually arrive (the liveness gate). Fails closed.
    func start(frames: @escaping @Sendable (Data) -> Void) async throws
    /// Stops after a short tail linger, so a Bluetooth route's last frames aren't cut.
    func stop() async
}

public protocol MicCaptureFactory: Sendable {
    func make() -> any MicCapture
}

/// Shared, lock-protected meter the recorder writes and the overlay polls.
public final class LevelMeter: @unchecked Sendable {
    public static let silenceFloor: Float = -115
    private let lock = NSLock()
    private var value: Float = LevelMeter.silenceFloor

    public init() {}

    public var decibels: Float {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    /// 0…1 for drawing, with a perceptual floor around −60 dB.
    public var normalized: Float {
        let db = decibels
        return max(0, min(1, (db + 60) / 60))
    }
}

public struct AVCaptureRecorderFactory: MicCaptureFactory {
    let meter: LevelMeter
    /// Re-read at every press. nil or absent → system default (without unpinning).
    let pinnedDeviceUID: @Sendable () -> String?

    public init(meter: LevelMeter, pinnedDeviceUID: @escaping @Sendable () -> String?) {
        self.meter = meter
        self.pinnedDeviceUID = pinnedDeviceUID
    }

    public func make() -> any MicCapture {
        AVCaptureRecorder(meter: meter, pinnedUID: pinnedDeviceUID())
    }
}

/// A fresh `AVCaptureSession` per capture. A long-lived `AVAudioEngine` tap binds to one device
/// and goes stale on a route switch (-10868 or all-zero buffers); this doesn't.
final class AVCaptureRecorder: NSObject, MicCapture, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let meter: LevelMeter
    private let pinnedUID: String?
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "dictation.mic")
    private let lock = NSLock()
    private var sink: (@Sendable (Data) -> Void)?
    private var framesArrived = false
    private var transport: Transport = .unknown

    init(meter: LevelMeter, pinnedUID: String?) {
        self.meter = meter
        self.pinnedUID = pinnedUID
    }

    func start(frames: @escaping @Sendable (Data) -> Void) async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw DictationError.microphone("access not granted")
        }
        let device = pinnedUID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw DictationError.microphone("no input device") }
        transport = Transport(device.transportType)

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                throw DictationError.microphone("can't use \(device.localizedName)")
            }
            session.addInput(input)
            // Ask the output for the wire format directly, so nothing downstream resamples.
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Wire.sampleRate,
                AVNumberOfChannelsKey: Wire.channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(output)
            session.commitConfiguration()
        } catch let error as DictationError {
            throw error
        } catch {
            throw DictationError.microphone(error.localizedDescription)
        }

        lock.withLock { sink = frames }
        let session = self.session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()   // blocking; opens the device
                done.resume()
            }
        }

        // Liveness: poll from ~1 ms up to 25 ms. Digital silence counts — this is a route-is-live
        // gate, never a speech threshold.
        let deadline = Date().addingTimeInterval(transport.livenessTimeout)
        var interval: UInt64 = 1_000_000
        while !lock.withLock({ framesArrived }) {
            if Date() >= deadline {
                await stopNow()
                throw DictationError.microphone("no audio from \(device.localizedName)")
            }
            try? await Task.sleep(nanoseconds: interval)
            interval = min(interval * 2, 25_000_000)
        }
    }

    func stop() async {
        try? await Task.sleep(nanoseconds: transport == .bluetooth ? 250_000_000 : 80_000_000)
        await stopNow()
    }

    private func stopNow() async {
        lock.withLock { sink = nil }
        meter.decibels = LevelMeter.silenceFloor
        let session = self.session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                if session.isRunning { session.stopRunning() }
                done.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == noErr else { return }
        if let power = connection.audioChannels.first?.averagePowerLevel {
            meter.decibels = max(LevelMeter.silenceFloor, power)
        }
        let sink = lock.withLock { () -> (@Sendable (Data) -> Void)? in
            framesArrived = true
            return self.sink
        }
        sink?(data)
    }
}

enum Transport: Equatable {
    case wired, bluetooth, unknown

    init(_ raw: Int32) {
        switch UInt32(bitPattern: raw) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetooth
        case kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            self = .wired
        default:
            self = .unknown
        }
    }

    var livenessTimeout: TimeInterval {
        switch self {
        case .wired: Timing.livenessWired
        case .bluetooth: Timing.livenessBluetooth
        case .unknown: Timing.livenessUnknown
        }
    }
}

public struct InputDevice: Identifiable, Hashable, Sendable {
    public let id: String   // CoreAudio UID == AVCaptureDevice.uniqueID
    public let name: String

    public static func all() -> [InputDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { InputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }
}
