import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Captures system-wide audio output using the Core Audio process-tap API
/// (macOS 14.4+), with no third-party audio driver.
///
/// Pipeline: `CATapDescription` (stereo global tap) → `AudioHardwareCreateProcessTap`
/// → private aggregate device that includes the tap → IOProc delivering Float32
/// buffers. The delivered format is the tapped device's mix format, so callers read
/// `format` and convert as needed (see `PCMConverter`).
///
/// Modeled on insidegui/AudioCap.
final class SystemAudioTap {
    enum TapError: Error, LocalizedError {
        case createTapFailed(OSStatus)
        case noOutputDevice
        case createAggregateFailed(OSStatus)
        case readFormatFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case selfExclusionFailed
        var errorDescription: String? {
            switch self {
            case .createTapFailed(let s):      return "Couldn't create the audio tap (status \(s)). Grant audio-capture permission."
            case .noOutputDevice:              return "No system audio output device found."
            case .createAggregateFailed(let s): return "Couldn't create the capture device (status \(s))."
            case .readFormatFailed(let s):      return "Couldn't read the tap's audio format (status \(s))."
            case .ioProcFailed(let s):          return "Couldn't start audio capture (status \(s))."
            case .selfExclusionFailed:          return "Couldn't exclude cozyplay from its own capture. Try starting the party again."
            }
        }
    }

    /// The tap's actual capture format, valid after `start` succeeds.
    private(set) var format: AVAudioFormat?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "africa.inpathgroup.cozyplay.tap")

    /// Delivered on the audio IO queue for every captured buffer, along with the
    /// capture host time of the buffer's first frame in nanoseconds
    /// (`AudioTimeStamp.mHostTime` converted via `HostClock`).
    private var onBuffer: ((AVAudioPCMBuffer, UInt64) -> Void)?

    /// Start capturing. `onBuffer` is called for each captured chunk.
    /// - Parameter keepSourceAudible: troubleshooting mode — leaves the tapped
    ///   apps' own output audible (`.unmuted`) instead of muting them in favor
    ///   of the engine's delayed playback. Causes doubled audio on the host.
    func start(
        keepSourceAudible: Bool = false,
        onBuffer: @escaping (AVAudioPCMBuffer, UInt64) -> Void
    ) throws {
        self.onBuffer = onBuffer

        // 1. Describe a stereo tap of the whole system, excluding our own process —
        //    otherwise the engine's delayed local playback would be re-captured as a
        //    feedback/echo loop. A failed exclusion MUST abort: with the mute below
        //    it would silently self-mute the host AND stream an escalating echo.
        //    (Translation requires our process to be registered with coreaudiod —
        //    guaranteed because local playback starts before the tap; see
        //    HostController.start().)
        guard let selfObject = Self.processObject(forPID: ProcessInfo.processInfo.processIdentifier) else {
            throw TapError.selfExclusionFailed
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfObject])
        description.uuid = UUID()
        description.name = "cozyplay-tap"
        description.isPrivate = true
        // Mute the tapped processes' direct output: the host hears the engine's
        // *delayed* local playback instead, so it stays aligned with the
        // companions rather than running one buffer ahead of them.
        description.muteBehavior = keepSourceAudible ? .unmuted : .mutedWhenTapped

        // 2. Create the process tap.
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr else { throw TapError.createTapFailed(tapStatus) }
        tapID = newTapID

        // 3. Build a private aggregate device that includes the output device + tap.
        guard let outputUID = Self.defaultOutputDeviceUID() else { throw TapError.noOutputDevice }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "cozyplay-capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard aggStatus == noErr else { throw TapError.createAggregateFailed(aggStatus) }
        aggregateID = newAggregateID

        // 4. Read the tap's stream format.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let fmtStatus = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd)
        guard fmtStatus == noErr, let avFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.readFormatFailed(fmtStatus)
        }
        format = avFormat

        // 5. Install and start an IOProc on the aggregate device.
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            guard let self, let format = self.format else { return }
            let ticks = inInputTime.pointee.mFlags.contains(.hostTimeValid)
                ? inInputTime.pointee.mHostTime
                : mach_absolute_time()
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) {
                self.onBuffer?(buffer, HostClock.ns(fromHostTicks: ticks))
            }
        }
        guard ioStatus == noErr else { throw TapError.ioProcFailed(ioStatus) }

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else { throw TapError.ioProcFailed(startStatus) }
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
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

    // MARK: Helpers

    /// Translate a Unix PID to its Core Audio process object (for tap exclusion).
    private static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &pidValue) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &objectID
            )
        }
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        // The user's actual output device — NOT DefaultSystemOutputDevice (the
        // alert-sounds device), which can differ and would give the aggregate
        // the wrong clock/drift-compensation subdevice.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var uid: CFString? = nil
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let uidStatus = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: CFString.self, capacity: 1) { rebound in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, rebound)
            }
        }
        guard uidStatus == noErr else { return nil }
        return uid as String?
    }
}
