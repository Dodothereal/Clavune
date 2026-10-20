import Foundation

public struct ResourcePolicy: Decodable, Sendable {
    public let schemaVersion: Int
    public let sampleRate: Int
    public let sessionLimitSeconds: Int
    public let ringSlots: Int
    public let maxNativeBlockFrames: Int
    public let pumpIntervalMilliseconds: Int
    public let firstBufferTimeoutSeconds: Double
    public let stopDrainTimeoutSeconds: Double
    public let maxInputChannels: Int
    public let inferenceThreads: Int
    public let activeInferenceJobs: Int
    public let previewEnabled: Bool
    public var maxSamples: Int { sampleRate * sessionLimitSeconds }
    public static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "resource-policy", withExtension: "json", subdirectory: "Resources")
        else { throw DictationError.configuration }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1, value.sampleRate == 16000,
              (1...120).contains(value.sessionLimitSeconds),
              (2...128).contains(value.ringSlots),
              (128...16384).contains(value.maxNativeBlockFrames),
              (1...100).contains(value.pumpIntervalMilliseconds),
              (0.1...5).contains(value.stopDrainTimeoutSeconds),
              (0.1...10).contains(value.firstBufferTimeoutSeconds),
              (1...32).contains(value.maxInputChannels),
              (1...8).contains(value.inferenceThreads),
              value.activeInferenceJobs == 1, !value.previewEnabled
        else { throw DictationError.configuration }
        return value
    }
}

public enum DictationError: String, Error, LocalizedError, Sendable {
    case configuration, permissionDenied, privacyBlocked, unsupportedFormat, audioUnavailable
    case overflow, durationLimit, discontinuity, endpointUncertain, noAudio
    case modelMissing, modelMismatch, modelInvalid, inferenceFailed, cancelled, busy
    public var errorDescription: String? {
        switch self {
        case .configuration: return "Die lokale Konfiguration ist ungültig."
        case .permissionDenied: return "Mikrofonzugriff ist nicht erlaubt. Aufnahme wurde nicht gestartet."
        case .privacyBlocked: return "Secure Input oder Mikrofonberechtigung hat sich geändert. Aufnahme bleibt geschlossen."
        case .unsupportedFormat: return "Das Eingangsformat oder der gewählte Kanal wird nicht unterstützt."
        case .audioUnavailable: return "Das Mikrofon liefert keine nutzbaren Daten. Bitte Gerät und Berechtigung prüfen."
        case .overflow: return "Der begrenzte Audiopuffer ist übergelaufen. Diese Aufnahme wurde als unvollständig verworfen."
        case .durationLimit: return "Das Sitzungslimit wurde erreicht. Die Aufnahme wurde sicher beendet; bitte kürzer diktieren."
        case .discontinuity: return "Das Audiogerät oder seine Zeitachse hat sich geändert. Bitte erneut aufnehmen."
        case .endpointUncertain: return "Das Aufnahmeende ließ sich nicht vollständig bestätigen. Bitte erneut aufnehmen."
        case .noAudio: return "Es sind keine Audiodaten vorhanden."
        case .modelMissing: return "Bitte zuerst ein geprüftes Modell importieren."
        case .modelMismatch: return "Größe oder SHA-256 des Modells stimmt nicht mit dem Modellmanifest überein."
        case .modelInvalid: return "Das Modell konnte nicht geladen werden."
        case .inferenceFailed: return "Die lokale Transkription ist fehlgeschlagen."
        case .cancelled: return "Abgebrochen. Mikrofon geschlossen."
        case .busy: return "Eine Sitzung wird bereits verarbeitet."
        }
    }
}

public enum LanguageMode: String, CaseIterable, Identifiable, Sendable {
    case auto, de, en
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: return "Automatisch"
        case .de: return "Deutsch mit englischen Fachbegriffen"
        case .en: return "English"
        }
    }
}
