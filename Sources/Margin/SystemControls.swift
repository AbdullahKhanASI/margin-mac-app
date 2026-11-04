import AppKit
import AudioToolbox
import CMultitouch
import CoreAudio
import MarginCore

enum SystemControls {
    /// Posts the same system-defined event the keyboard's media keys send, so macOS applies the
    /// change and shows its own volume / brightness HUD. With `fine`, Shift-Option is attached,
    /// which macOS turns into a quarter step.
    static func press(_ key: MediaKey, fine: Bool = false) {
        post(key, down: true, fine: fine)
        post(key, down: false, fine: fine)
    }

    private static func post(_ key: MediaKey, down: Bool, fine: Bool) {
        let state = down ? 0xA : 0xB
        var flags = UInt(state << 8)
        if fine { flags |= NSEvent.ModifierFlags([.shift, .option]).rawValue }
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (key.rawValue << 16) | (state << 8),
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }

    // MARK: Haptics

    /// Drives the trackpad's haptic motor directly. NSHapticFeedbackManager is silent for
    /// background apps like this one, so it's only the fallback. Safe to call from any thread.
    static func tick(_ strength: HapticStrength, device: UInt64) {
        let actuation: Int32 = switch strength {
        case .light: 3
        case .medium: 4
        case .strong: 6
        }
        guard mr_actuate(device, actuation) != 0 else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = switch strength {
        case .light: .alignment
        case .medium: .levelChange
        case .strong: .generic
        }
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }

    /// A heavier double pulse, used for mute so it can be felt without looking.
    static func buzz(device: UInt64) {
        tick(.strong, device: device)
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.08) {
            tick(.strong, device: device)
        }
    }

    // MARK: Volume and brightness, read and set directly (no system HUD)

    /// The default output device with output scope, or the default input device with input scope.
    private struct AudioTarget {
        let device: AudioDeviceID
        let scope: AudioObjectPropertyScope

        static func current(input: Bool) -> AudioTarget? {
            var device = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                    &size, &device)
            guard status == noErr, device != kAudioObjectUnknown else { return nil }
            return AudioTarget(device: device,
                               scope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        }

        func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        }

        func isSettable(_ selector: AudioObjectPropertySelector) -> Bool {
            var address = address(selector)
            guard AudioObjectHasProperty(device, &address) else { return false }
            var settable = DarwinBoolean(false)
            return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
        }

        func volume() -> (volume: Float, muted: Bool)? {
            var volume = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }

            var muted = UInt32(0)
            size = UInt32(MemoryLayout<UInt32>.size)
            address = self.address(kAudioDevicePropertyMute)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) != noErr { muted = 0 }
            return (volume, muted != 0)
        }

        func setVolume(_ value: Float) -> Bool {
            var volume = Float32(min(max(value, 0), 1))
            var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size),
                                              &volume) == noErr
        }

        func setMuted(_ muted: Bool) -> Bool {
            var value = UInt32(muted ? 1 : 0)
            var address = address(kAudioDevicePropertyMute)
            return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size),
                                              &value) == noErr
        }
    }

    static func outputVolume() -> (volume: Float, muted: Bool)? {
        AudioTarget.current(input: false)?.volume()
    }

    /// Returns false when the current output device has no adjustable volume (e.g. some HDMI outputs).
    @discardableResult
    static func setOutputVolume(_ value: Float) -> Bool {
        AudioTarget.current(input: false)?.setVolume(value) ?? false
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        AudioTarget.current(input: false)?.setMuted(muted) ?? false
    }

    // MARK: Microphone

    /// Nil when there's no input device or it has no readable volume.
    static func inputVolume() -> (volume: Float, muted: Bool)? {
        AudioTarget.current(input: true)?.volume()
    }

    /// Whether the input volume can be set at all. When it can't, an `inputVolume` slide does
    /// nothing; phase 3's zone editor shows such a binding as unavailable.
    static var inputVolumeAvailable: Bool {
        AudioTarget.current(input: true)?.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume) ?? false
    }

    /// Returns false when the input device has no settable volume.
    @discardableResult
    static func setInputVolume(_ value: Float) -> Bool {
        AudioTarget.current(input: true)?.setVolume(value) ?? false
    }

    @discardableResult
    static func setInputMuted(_ muted: Bool) -> Bool {
        AudioTarget.current(input: true)?.setMuted(muted) ?? false
    }

    /// The volume to restore when a mic that can't mute is "unmuted". Main thread only.
    private static var inputVolumeBeforeMute: Float?

    /// Mutes or unmutes the default input device and returns its new state, or nil if it can do
    /// neither. Many USB mics have a volume but no mute; for those, muting sets the volume to 0
    /// and unmuting puts back what it was. Main thread only.
    static func toggleInputMute() -> (volume: Float, muted: Bool)? {
        guard let target = AudioTarget.current(input: true), let current = target.volume() else { return nil }
        if target.isSettable(kAudioDevicePropertyMute) {
            guard target.setMuted(!current.muted) else { return nil }
            return (current.volume, !current.muted)
        }
        guard target.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume) else { return nil }
        if current.volume > 0 {
            inputVolumeBeforeMute = current.volume
            return target.setVolume(0) ? (0, true) : nil
        }
        // Already at 0, whether muted here or slid down: bring back the old level, or half.
        let restored = inputVolumeBeforeMute ?? 0.5
        inputVolumeBeforeMute = nil
        return target.setVolume(restored) ? (restored, false) : nil
    }

    static func brightness() -> Float? {
        var value = Float(0)
        return mr_get_brightness(&value) == 0 ? value : nil
    }

    @discardableResult
    static func setBrightness(_ value: Float) -> Bool {
        mr_set_brightness(min(max(value, 0), 1)) == 0
    }
}
