<!--
SP Drive — macOS
File: docs/ARCHITECTURE.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Architecture

## 1. Audit du système existant (2026-11-18)

| Sujet | Constat |
|---|---|
| Dépôt | spbgit `sp-drive.git`, source de vérité = clone du nœud **m5ma** `~/apps/sp-drive`, PM2 `sp-drive` (API + web, :8660), `sp-drive-worker`, clamd, sauvegarde nocturne |
| Frontend | SPA Vite / React 19 / Tailwind servie par l'API |
| Backend | Fastify 5 + PostgreSQL 17, monorepo pnpm ; modules `auth`, `tree`, `files`, `uploads`, `content`, `shares`, `requests`, `worker` |
| Authentification | passkeys WebAuthn seules, session par cookie `__Host-spd` (rotation quotidienne), en-tête CSRF, codes de récupération, TOTP facultatif |
| Arbre | `folders` / `files` par propriétaire, un dossier racine, noms uniques par dossier (clé NFC minuscule), verrou consultatif par propriétaire |
| Stockage physique | objets chiffrés AES-256-GCM par blocs de 64 Kio sur le SSD du nœud, clé par objet enveloppée par une clé maîtresse ; dédupliqués par (propriétaire, SHA-256, taille) |
| Téléversement | sessions résumables : création avec taille finale, blocs ≤ 16 Mio ajoutés à l'offset annoncé (SHA-256 par bloc), finalisation avec SHA-256 du fichier |
| Téléchargement | flux déchiffré, `Range` / `If-Range`, `ETag` = SHA-256 du contenu |
| Fichiers volumineux | jusqu'à 50 Go par fichier (configuration) |
| Partage | liens à jeton haché : lecture seule ou téléchargement, mot de passe, expiration, plafonds, usage unique, révocation, journal d'accès |
| Liens de dépôt | portails `/request/<jeton>` : le déposant n'obtient qu'un jeton de soumission ; quarantaine → antivirus → placement |
| Permissions | tout est filtré par propriétaire ; un identifiant étranger répond 404 |
| Versions | `file_versions` numérotées ; restaurer crée une version ; suppression d'une version non courante |
| Corbeille | suppression logique (`trashed_at`, `trash_root`), restauration, purge explicite |
| Recherche | par nom (sans accents ni casse), type, étiquette, dates, tailles, favoris |
| Quota | par compte, somme des objets ; exposé par `/auth/state` |
| Utilisateurs | comptes sur invitation, rôles admin / user |
| Absent | partage entre comptes (« partagés avec moi »), flux de changements, jeton pour client natif, détection de conflit |

## 2. Ajouts au backend (migration `002_native_clients`, tout additif)

- **Session d'appareil** : `POST /auth/login/verify` avec `client: {kind:"native", name}` renvoie un jeton porté en
  `Authorization: Bearer`, jamais tourné (plusieurs processus le partagent), durée glissante (fermé après 90 jours de
  silence), listé et révocable. Un jeton porteur n'étant pas une accréditation ambiante, il est dispensé de l'en-tête CSRF.
- **Liaison par code** : `auth/device/start|poll|info|decide` + page `/appareil` ; l'approbation exige une passkey fraîche.
- **Flux de changements** : colonne `rev` sur `folders` et `files`, tirée d'une séquence *après* la prise du verrou du
  propriétaire dans un déclencheur — pour un propriétaire, les révisions sont validées dans l'ordre, donc `rev > curseur`
  ne manque rien. Pierres tombales pour les purges. `GET /sync/changes`, `/sync/cursor`, `POST /sync/items`.
- **Conflits** : `baseVersionId` sur un téléversement de nouvelle version → 409 `version_conflict` (à la création et à la
  finalisation) ; `PATCH /uploads/:id/options {asNewFile}` transforme le même téléversement en fichier distinct.
- **AASA** : `/.well-known/apple-app-site-association` (`SPD_APPLE_APP_IDS`).

Vérifié : 75 tests d'intégration (63 existants + 12), 122 tests Playwright du site, aller-retour de migration.

## 3. Client macOS

```
┌──────────────── SP Drive.app (sandbox) ────────────────┐      ┌── SPDriveFileProvider.appex (sandbox) ──┐
│ SwiftUI ── AppModel ── SyncEngine                      │      │ NSFileProviderReplicatedExtension       │
│                        ├ OperationJournal (hors ligne) │      │  item / fetchContents / create / modify │
│                        ├ ChangeDetector (flux)         │      │  delete / enumerators / thumbnails      │
│                        ├ TransferQueue                 │      │  DriveServices                          │
│                        │   ├ UploadEngine              │      │   ├ UploadEngine  ├ DownloadEngine      │
│                        │   └ DownloadEngine            │      │   └ ChangeDetector └ ConflictResolver   │
│                        └ ConflictResolver              │      └─────────────────────────────────────────┘
└────────────┬───────────────────────────────────────────┘                        │
             │        conteneur du groupe 3YM54G49SN.ai.spboucher.spdrive         │
             ├── accounts/<serveur>-<compte>/metadata.sqlite  (miroir, journal, file, conflits) ──┤
             ├── trousseau, groupe …spdrive.shared  (jeton de session d'appareil) ────────────────┤
             └── notification Darwin « …changed »  ◀──────────────────────────────────────────────┘
                                   │ HTTPS (TLS système), Authorization: Bearer
                                   ▼
                        drive.spboucher.ai  (MacLustr, m5ma)
```

### Deux chemins d'écriture, un seul contrat

- **Dans le Finder** : le système tient la réplique locale et son propre journal ; il appelle l'extension pour pousser ce
  qui a été créé, modifié, renommé, déplacé, mis à la corbeille. Hors ligne, l'extension répond `serverUnreachable` et le
  système réessaie ; l'app signale la fin de la panne.
- **Dans l'application** : chaque action est écrite dans `ops` (journal SQLite) et appliquée au miroir au même instant,
  puis rejouée dans l'ordre contre le serveur. Les dossiers créés hors ligne portent un identifiant `local-…` échangé
  contre l'identifiant du serveur à la création. Les envois passent par `transfers` (copie mise en attente dans le conteneur).

Dans les deux cas : un contenu envoyé comme nouvelle version nomme la version dont il dérive. Si le serveur en a une
autre, rien n'est écrasé : les octets deviennent une **copie de conflit** (`nom (conflit <Mac> <date>).ext`), le conflit est
enregistré, et la personne choisit (garder les deux, la sienne, celle du serveur) — la version écartée va à la corbeille.

### Intégrité

Envoi : SHA-256 par bloc et du fichier entier, confirmé par le serveur avant tout « terminé » ; un fichier modifié pendant
l'envoi est refusé. Téléchargement : écriture dans un fichier partiel étiqueté par le SHA-256 attendu, reprise par
`Range` + `If-Range`, hachage en flux, puis `F_FULLFSYNC` et `rename` atomique seulement si taille et empreinte concordent ;
un partiel d'une autre version ou abîmé n'est jamais livré.

### Schéma du miroir (`metadata.sqlite`, version 1)

| Table | Rôle |
|---|---|
| `items` | un fichier ou dossier tel que décrit par le serveur (`rev`), + `name_key` (recherche sans accents), `seq` (compteur local de changements) |
| `tombstones` | identifiants supprimés définitivement (`seq`) |
| `pins` | éléments gardés hors ligne (un dossier couvre ses descendants) |
| `local_state` | copies présentes sur ce Mac, rapportées par le File Provider |
| `ops` | journal des opérations décidées ici (`pending` / `done` / `failed`) |
| `transfers` | file persistante des envois et téléchargements |
| `upload_sessions` | sessions de téléversement reprenables (destination + SHA-256 + taille → identifiant serveur) |
| `conflicts` | conflits et leur résolution |
| `meta` | curseur du flux, racine, génération du miroir, `seq` |

L'ancre de synchronisation donnée au File Provider est `génération:seq` : elle expire si le miroir est reconstruit.

## 4. Sécurité

HTTPS obligatoire (HTTP refusé hors boucle locale, et la version distribuée n'a aucune exception ATS) ; validation TLS du
système ; App Sandbox + runtime durci pour l'app et l'extension ; jeton dans le trousseau à protection des données
(`AfterFirstUnlockThisDeviceOnly`), jamais dans un fichier ni un journal ; noms assainis comme le serveur et chemins
contrôlés (`PathSafety`) avant toute écriture ; aucune adresse interne de stockage dans un lien.
Pas de chiffrement de bout en bout : le serveur détient les clés.
