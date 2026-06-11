import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures everything the Mac plays (a global CoreAudio process tap, i.e.
/// the remote side of a Teams/Zoom/Meet call) regardless of whether output
/// goes to speakers or headphones. Requires the "System Audio Recording"
/// privacy permission; macOS prompts on first use.
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "meetnote.system-tap")
    private(set) var format: AVAudioFormat?

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "meetnote system tap"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            throw MeetnoteError("""
            Could not create the system-audio tap (OSStatus \(status)).
            Likely the System Audio Recording permission is missing: System Settings \
            → Privacy & Security → Screen & System Audio Recording → System Audio \
            Recording Only → enable your terminal app, then retry.
            """)
        }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let avFormat = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw MeetnoteError("Could not read the system tap's audio format (OSStatus \(status)).")
        }
        format = avFormat

        // The aggregate needs a real subdevice for its clock; anchor it on the
        // default output device, with the tap supplying the captured audio.
        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "meetnote aggregate",
            kAudioAggregateDeviceUIDKey: "meetnote-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else {
            stop()
            throw MeetnoteError("Could not create the aggregate capture device (OSStatus \(status)).")
        }
        aggregateID = aggregate

        let debug = ProcessInfo.processInfo.environment["MEETNOTE_DEBUG"] != nil
        var callbackCount = 0
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let fmt = self.format else { return }
            if debug {
                callbackCount += 1
                if callbackCount == 1 || callbackCount % 500 == 0 {
                    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                    let sizes = abl.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ",")
                    eprint("[tap] callback #\(callbackCount): \(abl.count) buffer(s) [\(sizes)] fmt=\(fmt)")
                }
            }
            // The buffer memory is only valid inside this callback; the
            // consumer converts (and thereby copies) synchronously.
            let mutableABL = UnsafeMutablePointer(mutating: inInputData)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: mutableABL, deallocator: nil),
                  pcm.frameLength > 0 else {
                if debug, callbackCount == 1 { eprint("[tap] buffer wrap FAILED") }
                return
            }
            onBuffer(pcm)
        }
        guard status == noErr, ioProcID != nil else {
            stop()
            throw MeetnoteError("Could not install the audio IO proc (OSStatus \(status)).")
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            stop()
            throw MeetnoteError("Could not start the aggregate capture device (OSStatus \(status)).")
        }
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw MeetnoteError("Could not find the default output device (OSStatus \(status)).")
        }
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr else {
            throw MeetnoteError("Could not read the default output device's UID (OSStatus \(status)).")
        }
        return uid as String
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
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
