import CoreAudio
import Foundation

/// **Where the sound is going**, as distinct from what this Mac was built
/// with. The two questions `AudioProfile.detected` has to answer.
enum OutputRoute: Equatable {
    /// The Mac's own speakers.
    case builtInSpeakers
    /// The 3.5 mm jack. On Apple Silicon this is a separate device called
    /// "External Headphones", and it is also what a wired headset reports.
    case headphoneJack
    /// AirPods, or a Bluetooth speaker — CoreAudio cannot tell them apart,
    /// and headphones are the far more common case on a laptop.
    case bluetooth
    /// USB, Thunderbolt, HDMI, DisplayPort: an interface, a dock, a monitor.
    /// Could be studio monitors, could be a display's two tiny tweeters.
    case external
    case airPlay
    case unknown
}

/// **Which speakers Apple built into a given Mac.**
///
/// `hw.model` says `Mac15,13`, not "MacBook Air 15-inch", and Apple stopped
/// putting the product name in the identifier with the M1 generation — so
/// the first version of this, which looked for the substring "macbookair",
/// **never fired on any Apple Silicon Air**, including the one this project
/// is developed on. A table is the only way, and it is silently wrong for
/// every machine shipped after it was written, which is why unknown returns
/// `unknown` rather than guessing.
enum MacSpeakers: Equatable {
    /// Six drivers, force-cancelling woofers: MacBook Pro 14″/16″, iMac.
    case fullRange
    /// Stereo with some real low end: MacBook Air 15″, MacBook Pro 13″.
    case laptop
    /// Four small drivers: MacBook Air 13″.
    case compactLaptop
    /// A single small mono speaker: Mac mini, Mac Studio. A real output
    /// device and the default until something better is connected, not just
    /// what plays the startup chime.
    case beeper
    case unknown

    static func inModel(_ model: String) -> MacSpeakers {
        let key = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = table[key] { return known }
        // The Intel-era identifiers do carry the name, and are still a
        // reasonable guess for the class of speaker.
        let lower = key.lowercased()
        if lower.hasPrefix("macbookpro") { return .fullRange }
        if lower.hasPrefix("macbookair") { return .compactLaptop }
        if lower.hasPrefix("macmini") { return .beeper }
        if lower.hasPrefix("imac") { return .fullRange }
        return .unknown
    }

    /// Apple Silicon Macs by model identifier. One row per machine, and a
    /// new machine needs a new row.
    static let table: [String: MacSpeakers] = [
        // MacBook Air
        "MacBookAir10,1": .compactLaptop,  // M1, 13″
        "Mac14,2": .compactLaptop,         // M2, 13″
        "Mac14,15": .laptop,               // M2, 15″
        "Mac15,12": .compactLaptop,        // M3, 13″
        "Mac15,13": .laptop,               // M3, 15″
        "Mac16,12": .compactLaptop,        // M4, 13″
        "Mac16,13": .laptop,               // M4, 15″

        // MacBook Pro
        "MacBookPro17,1": .laptop,         // M1, 13″ — stereo, no woofers
        "MacBookPro18,1": .fullRange,      // M1 Pro/Max, 16″
        "MacBookPro18,2": .fullRange,
        "MacBookPro18,3": .fullRange,      // M1 Pro/Max, 14″
        "MacBookPro18,4": .fullRange,
        "Mac14,7": .laptop,                // M2, 13″
        "Mac14,5": .fullRange,             // M2 Pro/Max, 14″
        "Mac14,9": .fullRange,
        "Mac14,6": .fullRange,             // M2 Pro/Max, 16″
        "Mac14,10": .fullRange,
        "Mac15,3": .fullRange,             // M3, 14″
        "Mac15,6": .fullRange,             // M3 Pro/Max, 14″
        "Mac15,8": .fullRange,
        "Mac15,10": .fullRange,
        "Mac15,7": .fullRange,             // M3 Pro/Max, 16″
        "Mac15,9": .fullRange,
        "Mac15,11": .fullRange,
        "Mac16,1": .fullRange,             // M4, 14″
        "Mac16,6": .fullRange,             // M4 Pro/Max, 14″
        "Mac16,8": .fullRange,
        "Mac16,5": .fullRange,             // M4 Pro/Max, 16″
        "Mac16,7": .fullRange,

        // iMac
        "iMac21,1": .fullRange,            // M1
        "iMac21,2": .fullRange,
        "Mac15,4": .fullRange,             // M3
        "Mac15,5": .fullRange,
        "Mac16,2": .fullRange,             // M4
        "Mac16,3": .fullRange,

        // Mac mini
        "Macmini9,1": .beeper,             // M1
        "Mac14,3": .beeper,                // M2
        "Mac14,12": .beeper,               // M2 Pro
        "Mac16,10": .beeper,               // M4
        "Mac16,11": .beeper,               // M4 Pro

        // Mac Studio
        "Mac13,1": .beeper,                // M1 Max
        "Mac13,2": .beeper,                // M1 Ultra
        "Mac14,13": .beeper,               // M2 Max
        "Mac14,14": .beeper,               // M2 Ultra
        "Mac15,14": .beeper,               // M3 Ultra
        "Mac16,9": .beeper,                // M4 Max
    ]
}

/// Asks CoreAudio where the default output is going right now.
///
/// This is the one place in `Audio/` that talks to the system, and it is
/// read-only: it never opens the device or starts an engine. The mapping from
/// its answer to a profile is pure and lives in `AudioProfile.detected`, so
/// every combination can be tested without a device.
enum AudioRoute {

    static func current() -> OutputRoute {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr, device != 0 else {
            return .unknown
        }

        address.mSelector = kAudioDevicePropertyTransportType
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return .unknown
        }

        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            // The built-in device says which of its outputs is live: the
            // speakers ('ispk') or the jack ('hdpn').
            address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var source = UInt32(0)
            size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr {
                return source == fourCharCode("hdpn") ? .headphoneJack : .builtInSpeakers
            }
            return .builtInSpeakers
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI:
            return .external
        default:
            return .unknown
        }
    }

    private static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
