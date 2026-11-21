// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : App/PasskeyPresenter.swift
// Description      : Presents the system passkey sheet (Touch ID, iCloud
//                    Keychain, security key) for a challenge of the server and
//                    returns the signed assertion. Nothing biometric leaves the
//                    Mac.
// Module           : App
// Repository       : https://git.spboucher.ai/sp-drive-macos
// Created          : 2026-11-18
// Last Modified    : 2026-11-18
//
// =============================================================================
// AUTHOR & PROFESSIONAL AFFILIATION
// =============================================================================
//
// Author           : Simon-Pierre Boucher
// Position         : Professor of Finance
// Institution      : Université du Québec en Outaouais (UQO)
// Department       : Département des sciences administratives
// Organization     : SP Boucher
//
// Website          : https://spboucher.ai
// Git              : https://git.spboucher.ai
//
// =============================================================================
// OFFICIAL CONTACT DIRECTORY
// =============================================================================
//
// General          : info@spboucher.ai
// Professional     : contact@spboucher.ai
// Direct           : simon@spboucher.ai
// Research         : research@spboucher.ai
// Development      : dev@spboucher.ai
// Support          : support@spboucher.ai
// Security/Admin   : admin@spboucher.ai
// Notifications    : notifications@spboucher.ai
//
// Preferred Contact: support@spboucher.ai
//
// =============================================================================
// COPYRIGHT & INTELLECTUAL PROPERTY
// =============================================================================
//
// Copyright (c) 2026
// Simon-Pierre Boucher
//
// All rights reserved where applicable.
//
// This file is governed by the applicable project license,
// copyright notices, institutional agreements and relevant law.
//
// Unless expressly authorized by the applicable license or
// rights holder, copying, redistribution, sublicensing,
// publication and commercial exploitation are not permitted.
//
// Existing third-party rights and notices remain unaffected.
//
// =============================================================================
// CONFIDENTIALITY & SECURITY
// =============================================================================
//
// Classification   : Public
// Distribution     : Public repository; use is governed by the project license
// Security Contact : admin@spboucher.ai
//
// Access to this source does not independently grant permission
// to redistribute or disclose confidential materials.
//
// Do not embed credentials, private keys, access tokens,
// certificates or confidential personal information.
//
// =============================================================================
// LICENSE & MAINTENANCE
// =============================================================================
//
// License          : None specified (no license file in this repository)
// Maintainer       : Simon-Pierre Boucher
// Technical Contact: dev@spboucher.ai
//
// =============================================================================
// END OF SP BOUCHER SOURCE HEADER
// =============================================================================

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
