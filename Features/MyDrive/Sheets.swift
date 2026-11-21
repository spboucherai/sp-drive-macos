// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : SP Drive pour macOS
// File             : Features/MyDrive/Sheets.swift
// Description      : Sheets of the browser: naming (new folder, rename) and
//                    choosing a destination folder.
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

struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let action: String
    let run: (String) -> Void
    @State private var name: String
    @FocusState private var focused: Bool
    init(title: String, initial: String, action: String, selectStem: Bool = false, run: @escaping (String) -> Void) {
        self.title = title; self.action = action; self.run = run; _name = State(initialValue: initial)
    }
    private var clean: String { NameRules.sanitize(name, fallback: "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Nom", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit(submit).accessibilityIdentifier("name-field")
            if !name.isEmpty, clean != name.trimmingCharacters(in: .whitespaces), !clean.isEmpty {
                Text("Sera enregistré sous « \(clean) » (caractères non admis remplacés).").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction); Button(action, action: submit).keyboardShortcut(.defaultAction).disabled(clean.isEmpty) }
        }
        .padding(20).frame(width: 420).onAppear { focused = true }
    }
    private func submit() { guard !clean.isEmpty else { return }; run(name); dismiss() }
}

/// Folder tree of the mirror to choose where to move items.
struct MoveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [DriveItem]
    @State private var target: String?
    struct Node: Identifiable { let id: String; let name: String; var children: [Node]? }

    private func nodes(of parent: String, excluding: Set<String>, depth: Int = 0) -> [Node] {
        guard depth < 12 else { return [] }
        return model.children(of: parent).filter { $0.isFolder && !excluding.contains($0.id) }.map { f in
            let kids = nodes(of: f.id, excluding: excluding, depth: depth + 1)
            return Node(id: f.id, name: f.name, children: kids.isEmpty ? nil : kids)
        }
    }
    var body: some View {
        let moving = Set(items.map(\.id))
        let root = model.rootID ?? ""
        VStack(alignment: .leading, spacing: 12) {
            Text("Déplacer \(items.count == 1 ? "« \(items[0].name) »" : "\(items.count) éléments") vers…").font(.headline)
            List(selection: $target) {
                Label("Mon Drive", systemImage: "externaldrive").tag(root)
                OutlineGroup(nodes(of: root, excluding: moving), children: \.children) { n in Label(n.name, systemImage: "folder").tag(n.id) }
            }
            .frame(minHeight: 280).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Déplacer") { if let t = target { model.move(items, to: t) }; dismiss() }.keyboardShortcut(.defaultAction).disabled(target == nil || items.allSatisfy { $0.parentID == target })
            }
        }
        .padding(20).frame(width: 460, height: 440)
    }
}

