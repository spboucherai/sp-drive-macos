// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Core/Authentication/AuthAPI.swift
// Description      : Signing a device in: the WebAuthn passkey ceremony
//                    expressed as JSON for the server, and the fallback where a
//                    signed-in browser approves a short code. The system
//                    passkey sheet itself is presented by the application.
// Module           : Core
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

import Foundation

/// What the server asks the authenticator to sign.
public struct PasskeyChallenge: Sendable {
    public let challengeID: String
    public let challenge: Data
    public let relyingParty: String
    public let allowedCredentials: [Data]
}
/// What the platform authenticator answered (fields of ASAuthorizationPlatformPublicKeyCredentialAssertion).
public struct PasskeyAssertion: Sendable {
    public var credentialID: Data; public var clientDataJSON: Data; public var authenticatorData: Data; public var signature: Data; public var userHandle: Data?
    public init(credentialID: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data, userHandle: Data?) {
        self.credentialID = credentialID; self.clientDataJSON = clientDataJSON; self.authenticatorData = authenticatorData; self.signature = signature; self.userHandle = userHandle
    }
    /// The AuthenticationResponseJSON the server verifies (WebAuthn level 3 serialisation).
    var json: JSONValue {
        var response: [String: JSONValue] = ["clientDataJSON": .string(clientDataJSON.base64URL), "authenticatorData": .string(authenticatorData.base64URL), "signature": .string(signature.base64URL)]
        if let userHandle { response["userHandle"] = .string(userHandle.base64URL) }
        return .object(["id": .string(credentialID.base64URL), "rawId": .string(credentialID.base64URL), "type": .string("public-key"), "authenticatorAttachment": .string("platform"),
                        "clientExtensionResults": .object([:]), "response": .object(response)])
    }
}
public struct DeviceLinkStart: Decodable, Sendable {
    public var deviceCode: String; public var userCode: String; public var verifyUrl: URL; public var expiresInS: Int; public var intervalS: Int
}
public enum DeviceLinkStatus: Sendable, Equatable { case pending, denied, expired, approved }

extension APIClient {
    private struct Options: Decodable {
        struct Cred: Decodable { var id: String }
        struct O: Decodable { var challenge: String; var rpId: String?; var allowCredentials: [Cred]? }
        var challengeId: String; var options: O
    }
    private func challenge(_ path: String, authenticated: Bool) async throws -> PasskeyChallenge {
        let o: Options = try await send("POST", path, authenticated: authenticated)
        guard let c = Data(base64URL: o.options.challenge), let rp = o.options.rpId ?? baseURL.host else { throw DriveError.invalidResponse("challenge") }
        return PasskeyChallenge(challengeID: o.challengeId, challenge: c, relyingParty: rp, allowedCredentials: (o.options.allowCredentials ?? []).compactMap { Data(base64URL: $0.id) })
    }
    public func loginChallenge() async throws -> PasskeyChallenge { try await challenge("/auth/login/options", authenticated: false) }
    /// Completes the sign-in: the server opens a device session and its token is stored in the token store.
    public func completeLogin(_ challenge: PasskeyChallenge, assertion: PasskeyAssertion, deviceName: String) async throws {
        struct Client: Encodable { var kind = "native"; var name: String }
        struct B: Encodable { var challengeId: String; var response: JSONValue; var client: Client }
        struct R: Decodable { var token: String }
        let r: R = try await send("POST", "/auth/login/verify", body: B(challengeId: challenge.challengeID, response: assertion.json, client: Client(name: deviceName)), authenticated: false)
        try tokens.writeToken(r.token)
    }
    /// A passkey confirmation for a sensitive operation of an open session.
    public func reauthChallenge() async throws -> PasskeyChallenge { try await challenge("/auth/reauth/options", authenticated: true) }
    public func completeReauth(_ challenge: PasskeyChallenge, assertion: PasskeyAssertion) async throws {
        struct B: Encodable { var challengeId: String; var response: JSONValue }
        let _: OK = try await send("POST", "/auth/reauth/verify", body: B(challengeId: challenge.challengeID, response: assertion.json))
    }

    /// Starts linking this device: `userCode` is shown to the person, who approves it in a signed-in browser.
    public func startDeviceLink(deviceName: String) async throws -> DeviceLinkStart {
        struct B: Encodable { var name: String }
        return try await send("POST", "/auth/device/start", body: B(name: deviceName), authenticated: false)
    }
    /// Asks whether the code was approved. On approval the token is stored and `.approved` is returned — once.
    public func pollDeviceLink(_ deviceCode: String) async throws -> DeviceLinkStatus {
        struct B: Encodable { var deviceCode: String }
        struct R: Decodable { var status: String; var token: String? }
        let r: R = try await send("POST", "/auth/device/poll", body: B(deviceCode: deviceCode), authenticated: false)
        switch r.status {
        case "approved": guard let t = r.token else { throw DriveError.invalidResponse("jeton absent") }; try tokens.writeToken(t); return .approved
        case "pending": return .pending
        case "denied": return .denied
        default: return .expired
        }
    }
    /// Ends the device session on the server (best effort) and forgets the token.
    public func signOut() async {
        _ = try? await logout()
        try? tokens.deleteToken()
    }
}
