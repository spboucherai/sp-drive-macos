// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: App/PasskeyPresenter.swift
// Description: Presents the system passkey sheet (Touch ID, iCloud Keychain, security key) for a challenge of the server and returns the signed assertion. Nothing biometric leaves the Mac.
import AppKit
import AuthenticationServices
import SPDriveCore

@MainActor final class PasskeyPresenter: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<PasskeyAssertion, Error>?
    private var controller: ASAuthorizationController?

    /// Asks the person to confirm with a passkey of `drive.spboucher.ai`. Throws `.cancelled` when the sheet is dismissed.
    func assert(_ challenge: PasskeyChallenge) async throws -> PasskeyAssertion {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: challenge.relyingParty)
        let request = provider.createCredentialAssertionRequest(challenge: challenge.challenge)
        request.userVerificationPreference = .required
        request.allowedCredentials = challenge.allowedCredentials.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
        let c = ASAuthorizationController(authorizationRequests: [request])
        c.delegate = self; c.presentationContextProvider = self; controller = c
        return try await withCheckedThrowingContinuation { cont in continuation = cont; c.performRequests() }
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        defer { continuation = nil; self.controller = nil }
        guard let a = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else { continuation?.resume(throwing: DriveError.local("réponse de passkey inattendue")); return }
        continuation?.resume(returning: PasskeyAssertion(credentialID: a.credentialID, clientDataJSON: a.rawClientDataJSON, authenticatorData: a.rawAuthenticatorData, signature: a.signature, userHandle: a.userID))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        defer { continuation = nil; self.controller = nil }
        let ns = error as NSError
        if ns.domain == ASAuthorizationError.errorDomain, ns.code == ASAuthorizationError.canceled.rawValue { continuation?.resume(throwing: DriveError.cancelled) }
        else { continuation?.resume(throwing: DriveError.local("Passkey : \(ns.localizedDescription) (\(ns.code))")) }
    }
}
