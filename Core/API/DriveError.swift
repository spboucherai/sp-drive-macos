// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Core/API/DriveError.swift
// Description: The errors SP Drive distinguishes: unreachable server, ended session, an answer of the server with its stable code, damaged content, local failures.
import Foundation

public enum DriveError: Error, Sendable, Equatable, LocalizedError {
    /// No network, or the server did not answer. Nothing was decided: the operation can be tried again.
    case offline(String)
    /// The session is over (revoked, expired) — the person must sign in again.
    case unauthenticated
    /// The server refused; `code` is stable ("name_conflict", "version_conflict", "quota_exceeded", "not_found"…).
    case server(status: Int, code: String, message: String, extra: [String: JSONValue])
    case invalidResponse(String)
    /// Bytes received or stored do not match their SHA-256 or their size.
    case integrity(String)
    case cancelled
    case local(String)

    public var code: String {
        switch self {
        case .offline: return "offline"
        case .unauthenticated: return "unauthenticated"
        case .server(_, let code, _, _): return code
        case .invalidResponse: return "invalid_response"
        case .integrity: return "integrity"
        case .cancelled: return "cancelled"
        case .local: return "local"
        }
    }
    public var status: Int? { if case .server(let s, _, _, _) = self { return s }; return nil }
    public var extra: [String: JSONValue] { if case .server(_, _, _, let e) = self { return e }; return [:] }
    /// True when trying again later can succeed without anyone deciding anything (network, overload, server restart).
    public var isTransient: Bool {
        switch self {
        case .offline: return true
        case .server(let status, let code, _, _): return status >= 500 || status == 429 || code == "rate_limited"
        default: return false
        }
    }
    public var isNotFound: Bool { code == "not_found" }
    public var errorDescription: String? {
        switch self {
        case .offline: return "Serveur injoignable. L’opération reprendra dès le retour de la connexion."
        case .unauthenticated: return "La session est terminée. Reconnectez-vous."
        case .server(_, let code, let message, _): return DriveError.french[code] ?? message
        case .invalidResponse(let m): return "Réponse inattendue du serveur (\(m))."
        case .integrity(let m): return "Contrôle d’intégrité échoué : \(m)."
        case .cancelled: return "Opération annulée."
        case .local(let m): return m
        }
    }
    private static let french: [String: String] = [
        "name_conflict": "Un élément porte déjà ce nom à cet endroit.", "version_conflict": "Le fichier a changé sur le serveur entre-temps.",
        "quota_exceeded": "Espace de stockage insuffisant sur SP Drive.", "file_too_large": "Ce fichier dépasse la taille maximale acceptée.",
        "not_found": "Élément introuvable (supprimé ou déplacé).", "infected": "Ce fichier a été bloqué par l’antivirus.",
        "move_into_self": "Un dossier ne peut pas être déplacé dans lui-même.", "root_immutable": "Le dossier racine ne peut pas être modifié.",
        "rate_limited": "Trop de requêtes : nouvel essai dans un instant.", "reauth_required": "Confirmez avec votre passkey.",
        "authentication_failed": "Passkey refusée.", "challenge_expired": "Demande expirée, recommencez.", "bad_expiry": "La date d’expiration doit être dans le futur.",
        "current_version": "La version courante ne peut pas être supprimée.", "upload_closed": "Ce téléversement n’est plus actif.",
        "checksum_mismatch": "Le fichier reçu par le serveur diffère du fichier envoyé.", "device_code_invalid": "Code inconnu ou expiré.",
    ]
    /// Maps anything thrown by Foundation networking into a DriveError.
    public static func wrap(_ error: Error) -> DriveError {
        if let d = error as? DriveError { return d }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorCancelled { return .cancelled }
            return .offline(ns.localizedDescription)
        }
        if ns.domain == NSPOSIXErrorDomain, [Int(ENETDOWN), Int(ENETUNREACH), Int(ECONNREFUSED), Int(ECONNRESET), Int(ETIMEDOUT), Int(EPIPE)].contains(ns.code) { return .offline(ns.localizedDescription) }
        return .local(ns.localizedDescription)
    }
}
