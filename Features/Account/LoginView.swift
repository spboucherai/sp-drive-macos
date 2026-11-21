// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Features/Account/LoginView.swift
// Description      : Welcome and sign-in: a passkey (Touch ID) first; otherwise
//                    a short code approved from a browser where the person is
//                    already signed in.
// Module           : Features
// Repository       : https://git.spboucher.ai/sp-drive-macos
// Created          : 2026-11-18
// Last Modified    : 2026-11-19
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

import SPDriveCore
import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            SPDTheme.canvas.ignoresSafeArea()
            VStack(spacing: 22) {
                DriveMark()
                VStack(spacing: 6) {
                    Text(AppEnvironment.productName).font(.system(size: 34, weight: .semibold, design: .serif))
                    Text("Vos fichiers MacLustr, dans le Finder et hors ligne.").font(.title3).foregroundStyle(SPDTheme.textSecondary)
                }
                Group {
                    if let link = model.link { linking(link) } else { actions }
                }
                .frame(maxWidth: 380)
                if let e = model.loginError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 420)
                        .accessibilityIdentifier("login-error")
                }
                Text(AppEnvironment.serverURL.host ?? "").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(40)
        }
    }
    private var actions: some View {
        VStack(spacing: 12) {
            Button { Task { await model.signInWithPasskey() } } label: {
                Label(model.signingIn ? "Connexion…" : "Se connecter avec une passkey", systemImage: "touchid").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.signingIn).keyboardShortcut(.defaultAction)
            Button("Relier ce Mac avec un code") { model.startDeviceLink() }.buttonStyle(.link)
            Text("Touch ID ou votre trousseau confirme votre identité : rien de biométrique ne quitte ce Mac. Sans passkey sur ce Mac, reliez-le depuis un navigateur où vous êtes déjà connecté.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
    private func linking(_ link: DeviceLinkStart) -> some View {
        VStack(spacing: 14) {
            Text("Approuvez ce code dans votre navigateur").font(.headline)
            Text(link.userCode).font(.system(size: 38, weight: .semibold, design: .monospaced)).tracking(4).textSelection(.enabled)
                .padding(.horizontal, 22).padding(.vertical, 12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("Code \(link.userCode.map(String.init).joined(separator: " "))").accessibilityIdentifier("link-code")
            HStack {
                Button("Ouvrir la page d’approbation") { openURL(link.verifyUrl) }.buttonStyle(.borderedProminent)
                Button("Annuler") { model.cancelDeviceLink() }
            }
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("En attente de l’approbation…").foregroundStyle(.secondary) }.font(.callout)
        }
    }
}

struct LockedView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 18) {
            DriveMark(size: 64)
            Text("SP Drive est verrouillé").font(SPDTheme.Typo.display)
            Button { Task { await model.unlock() } } label: { Label("Déverrouiller", systemImage: "touchid") }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.ultraThickMaterial)
        .task { await model.unlock() }
    }
}
