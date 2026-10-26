import ClavuneCore

/// Presentation-only guidance: never retains audio, retries a decoder or changes permissions.
struct DictationRecovery: Equatable {
    let error: DictationError

    init?(session: SessionMachine) {
        guard session.phase == .failed, let error = session.failure else { return nil }
        self.error = error
    }

    var guidance: String {
        switch error {
        case .permissionDenied:
            return "Erlaube Clavune den Mikrofonzugriff in den macOS-Systemeinstellungen. Starte danach bewusst eine neue Aufnahme."
        case .privacyBlocked:
            return "Prüfe Mikrofonberechtigung und Secure Input. Starte erst danach bewusst eine neue Aufnahme."
        case .unsupportedFormat:
            return "Wähle in den Clavune-Einstellungen ein verfügbares Mikrofon und einen unterstützten Eingangskanal."
        case .audioUnavailable, .discontinuity:
            return "Verbinde dein Mikrofon erneut und prüfe Gerät und Eingangskanal in den Clavune-Einstellungen."
        case .overflow, .durationLimit:
            return "Nimm einen kürzeren Abschnitt neu auf und stoppe vor dem Sitzungslimit. Die fehlgeschlagene Aufnahme wird nicht fortgesetzt."
        case .endpointUncertain, .noAudio:
            return "Prüfe das Mikrofon und nimm den Abschnitt neu auf. Die fehlgeschlagene Aufnahme wird nicht fortgesetzt."
        case .modelMissing, .modelMismatch, .modelInvalid:
            return "Importiere in den Clavune-Einstellungen erneut ein geprüftes Modell. Es wird nichts automatisch heruntergeladen."
        case .inferenceFailed:
            return "Versuche eine neue, kurze Aufnahme. Falls der Fehler bleibt, prüfe das Modell in den Clavune-Einstellungen."
        case .configuration:
            return "Starte Clavune neu. Falls der Fehler bleibt, muss der Entwicklungsbuild geprüft werden."
        case .busy:
            return "Warte, bis die laufende Arbeit beendet ist, bevor du eine neue Aufnahme startest."
        case .cancelled:
            return "Die Aufnahme wurde abgebrochen. Eine neue Aufnahme startet nur auf deinen Befehl."
        }
    }

    var offersNewRecording: Bool {
        switch error {
        case .configuration, .modelMissing, .modelMismatch, .modelInvalid, .busy, .cancelled:
            return false
        default:
            return true
        }
    }
}

@MainActor
extension AppCoordinator {
    var dictationRecovery: DictationRecovery? {
        audioFileSession ? nil : DictationRecovery(session: session)
    }

    var canRetryFailedRecording: Bool {
        dictationRecovery?.offersNewRecording == true && canStart && microphone.state == .closed
    }

    /// A stale or repeated recovery action cannot replace a review or start during drain.
    /// This is a fresh recording through normal admission, never replay of failed audio.
    func retryFailedRecording() {
        guard canRetryFailedRecording else { return }
        start()
    }
}
