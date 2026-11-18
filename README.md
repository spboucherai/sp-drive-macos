<!--
SP Drive — macOS
File: README.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# SP Drive — macOS

Client macOS **natif** de [drive.spboucher.ai](https://drive.spboucher.ai) (stockage privé sur le cluster MacLustr) :
Swift 6, SwiftUI/AppKit, extension File Provider pour le Finder, moteur de synchronisation et de transferts en Swift.
Aucun WebView, aucun moteur web, aucune dépendance tierce.

| | |
|---|---|
| Application | `ai.spboucher.spdrive` — macOS 14+, universelle (arm64 + x86_64), App Sandbox, runtime durci |
| Extension Finder | `ai.spboucher.spdrive.fileprovider` (File Provider répliqué) |
| Serveur | https://drive.spboucher.ai (dépôt `sp-drive.git`, nœud m5ma) — routes pour clients natifs ajoutées le 2026-11-18 |
| Paquets Swift | `SPDriveCore` (`Core/`) et `SPDriveSync` (`Sync/`), aussi liés par l'app iOS |

État réel, fonction par fonction : [`docs/FEATURE_MATRIX.md`](docs/FEATURE_MATRIX.md). Preuves et limites : [`docs/TEST_REPORT.md`](docs/TEST_REPORT.md).
Conception : [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Organisation

```
App/                    entrée, modèle (AppModel), environnement partagé app/extension, passkey, réglages, notifications
Core/                   SPDriveCore : API, Authentication, Persistence (SQLite), Security, Networking, Metadata, Models
Sync/                   SPDriveSync : SyncEngine, ChangeDetector, ConflictResolver, TransferQueue, UploadManager,
                        DownloadManager, IntegrityVerifier, OperationJournal
FileProviderExtension/  extension Finder (FileProviderExtension, Enumerator, Item, DriveServices) + gestion du domaine côté app
Features/               écrans SwiftUI (Home, MyDrive, Shared, Transfers, Offline, Settings, Account…)
Components/             vues et formats partagés
Resources/              Info.plist, droits, catalogue d'images, icône (source SVG)
Tests/CoreTests/        tests unitaires et d'intégration (vrai backend local)
Scripts/                construction, backend de test, tests, distribution
```

## Commandes

```bash
Scripts/backend-dev.sh start        # vrai backend SP Drive local (clone ~/dev/sp-drive-testbed, base sp_drive_macdev, port 8665)
Scripts/t.sh [filtre] [secondes]    # swift test : 15 tests unitaires + 27 d'intégration contre ce backend
python3 Scripts/provision.py        # identifiants + profils Developer ID (clé App Store Connect existante), idempotent
Scripts/build.sh [Debug|Release]    # Debug = variante « SP Drive Dev » (identifiants .dev, backend local)
Scripts/run-dev.sh --link --keep    # lance la variante de test et la connecte par code d'appareil
Scripts/run-dev.sh --keep -- -spdSelfTest YES   # 19 vérifications faites par l'app signée elle-même
Scripts/run-dev.sh --keep -- -spdTour YES       # parcourt les 22 écrans et enregistre une image de chacun
Scripts/finder-scenario.sh          # scénario de validation par le Finder (exige l'emplacement activé dans Réglages Système)
Scripts/release.sh && Scripts/verify-release.sh && Scripts/notarize.sh   # archive, 32 contrôles, notarisation + DMG
```

Les produits de construction vont dans `~/Library/Developer/SPDrive/` (hors de `~/Desktop`, que les services système
qui chargent l'extension ne peuvent pas lire).

## À savoir

- **Activation dans le Finder** : macOS garde un nouvel emplacement File Provider désactivé jusqu'à ce que la personne
  l'active dans Réglages Système › Général › Ouverture et extensions › Fournisseurs de fichiers. L'application le détecte,
  l'explique et ouvre le bon panneau ; elle ne contourne pas ce consentement.
- **Connexion** : passkey (Touch ID) via `webcredentials:drive.spboucher.ai`, ou liaison par code approuvé dans un
  navigateur déjà connecté (`/appareil`). Le jeton de session d'appareil est dans le trousseau, groupe partagé avec l'extension.
- **Chiffrement** : TLS en transit, chiffrement au repos côté serveur. Ce n'est **pas** du chiffrement de bout en bout.
- **Suppression** : une suppression faite dans l'app ou dans le Finder met à la corbeille de SP Drive. Seule une action
  explicite sur un élément déjà dans la corbeille supprime définitivement.
