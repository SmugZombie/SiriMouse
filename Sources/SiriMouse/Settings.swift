import Foundation

enum Mode: String, CaseIterable {
    case presenter, mouse, media

    var title: String {
        switch self {
        case .presenter: return "Presenter"
        case .mouse: return "Mouse"
        case .media: return "Media"
        }
    }

    var symbol: String {
        switch self {
        case .presenter: return "play.rectangle"
        case .mouse: return "cursorarrow.rays"
        case .media: return "music.note"
        }
    }

    var next: Mode {
        let all = Mode.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum SiriAction: String, CaseIterable {
    case siri, dictation, none

    var title: String {
        switch self {
        case .siri: return "Open Siri"
        case .dictation: return "Dictate Text (hold to talk)"
        case .none: return "Do Nothing"
        }
    }
}

enum PointerSpeed: String, CaseIterable {
    case slow, normal, fast, veryFast

    var title: String {
        switch self {
        case .slow: return "Slow"
        case .normal: return "Normal"
        case .fast: return "Fast"
        case .veryFast: return "Very Fast"
        }
    }

    /// Screen points per full width of the touch surface, before acceleration.
    var gain: Double {
        switch self {
        case .slow: return 700
        case .normal: return 1100
        case .fast: return 1700
        case .veryFast: return 2500
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    var mode: Mode {
        get { Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .presenter }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }

    var siriAction: SiriAction {
        get { SiriAction(rawValue: defaults.string(forKey: "siriAction") ?? "") ?? .siri }
        set { defaults.set(newValue.rawValue, forKey: "siriAction") }
    }

    var pointerSpeed: PointerSpeed {
        get { PointerSpeed(rawValue: defaults.string(forKey: "pointerSpeed") ?? "") ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: "pointerSpeed") }
    }

    var verboseLogging: Bool {
        get { defaults.bool(forKey: "verboseLogging") }
        set { defaults.set(newValue, forKey: "verboseLogging") }
    }
}
