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

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : nil
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func outputVolume() -> (volume: Float, muted: Bool)? {
        guard let device = defaultOutputDevice() else { return nil }

        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }

        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address = outputAddress(kAudioDevicePropertyMute)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) != noErr { muted = 0 }
        return (volume, muted != 0)
    }

    /// Returns false when the current output device has no adjustable volume (e.g. some HDMI outputs).
    @discardableResult
    static func setOutputVolume(_ value: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var volume = Float32(min(max(value, 0), 1))
        var address = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume) == noErr
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var value = UInt32(muted ? 1 : 0)
        var address = outputAddress(kAudioDevicePropertyMute)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
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
