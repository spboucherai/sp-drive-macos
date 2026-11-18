<!--
SP Drive — macOS
File: docs/TEST_REPORT.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Rapport de tests — 2026-11-18

Machine : MacBook Pro (Mac17,6), macOS 27.0, Xcode 27.2, Swift 6.4. Aucun résultat n'est simulé : chaque test lit le
serveur ou le disque.

## Backend (dépôt `sp-drive`, branche `native-clients`, en production)

| Suite | Résultat |
|---|---|
| Vitest, vrai PostgreSQL | **75 / 75** (63 existants + 12 : sessions d'appareil, liaison par code, flux de changements — ordre sous écritures concurrentes, pagination —, conflit de version, AASA, aller-retour de migration) |
| Playwright du site (bureau, mobile, iPhone public) | **122 réussis, 6 ignorés (captures), 0 échec** sur le backend modifié |
| Production après déploiement | `health/ready` 200, migrations `001_init, 002_native_clients`, 24/24 fichiers et 7/7 dossiers numérotés, 4 sessions web intactes, AASA servi, `/appareil` 200 ; dump avant migration `m5ma:~/backups/sp-drive/pre-native/` |

## Paquets Swift — `Scripts/t.sh` : **42 / 42**

Backend réel local (`Scripts/backend-dev.sh`), compte créé par invitation + passkey (authentificateur WebAuthn logiciel :
la vérification côté serveur est le code de production).

- **Unitaires (15)** : règles de nommage identiques au serveur ; refus de traversée de chemin et de lien symbolique sortant ;
  miroir (révisions qui n'avancent que vers l'avant, ancres paginées avec pierres tombales, épingles héritées et persistantes,
  recherche et filtres, 60 000 éléments en moins de 2 s, reconstruction) ; classement des changements ; conseiller de
  parallélisme ; limiteur de débit ; refus du HTTP en clair.
- **Sessions (2)** : jeton porteur, jeton refusé ; liaison par code approuvée, remise une seule fois, déconnexion = révocation.
- **Arbre (1)** : cycle complet dossier / fichier, purge seulement depuis la corbeille.
- **Transferts (8)** : 48 Mo aller-retour en flux et vérifié ; fichier vide ; envoi coupé puis repris à l'offset du serveur
  après « redémarrage » ; envoi qui traverse un arrêt du serveur ; échec propre si le serveur reste arrêté ; téléchargement
  coupé puis repris par `Range` ; partiel abîmé jamais livré ; reprise après changement de contenu qui repart de zéro.
- **Conflits (2)** : édition périmée → copie de conflit, original intact, contenu local préservé ; résolutions « la mienne »
  et « celle du serveur » (la version écartée est à la corbeille).
- **Partage (3)** : lien protégé (mauvais mot de passe, plafond, journal, renouvellement, révocation) vu par un visiteur
  anonyme réel ; lien de dossier confiné ; portail de dépôt (dépôt anonyme réel, limites imposées par le serveur, jeton de
  soumission sans accès au compte, notification, pause, révocation).
- **Versions (1)**, **flux de changements (3)**, **journal hors ligne (2)** — dont : serveur arrêté, 6 opérations + un
  fichier ajouté, objets détruits et base rouverte, serveur relancé, tout rejoué dans l'ordre, zéro perte —,
  **file de transferts (3)**, **boucle de synchronisation (2)** (hors ligne, pause, session révoquée).

## Application signée

| Vérification | Résultat |
|---|---|
| `-spdSelfTest` dans la variante de test, signée Developer ID, sandboxée, contre le backend local | **19 / 19** : jeton lisible dans le trousseau partagé, session d'appareil, dossier / renommage / favori confirmés par le serveur, envoi et téléchargement dans `~/Downloads` vérifiés par SHA-256, copie d'aperçu, versions et restauration, lien de partage et révocation, duplication, corbeille et restauration, refus expliqué de l'épinglage sans emplacement Finder, journal vide à la fin |
| `-spdTour` | 22 écrans et feuilles affichés sans plantage (liste, grille, inspecteur, recherche, filtres, récents, favoris, hors ligne, partages, dépôts, transferts, téléchargements, conflits, corbeille, stockage, 6 feuilles) |
| Connexion réelle de l'app de test | par code d'appareil, approuvé par le compte de test |
| Extension File Provider | reconnue par `pluginkit`, domaine créé (`~/Library/CloudStorage/SPDriveDev-Dev`), état `user-disabled` |

Plantage rencontré et corrigé pendant ces essais : cellules de tableau, menus et barre d'outils lisaient le modèle dans
l'environnement SwiftUI, absent à ces endroits sur macOS 27 ; le modèle leur est maintenant passé explicitement.

## Distribution

| Étape | Résultat |
|---|---|
| Identité | `Developer ID Application: Simon-Pierre Boucher (3YM54G49SN)`, existante |
| Profils | 4 profils Developer ID créés par l'API App Store Connect (clé existante) : app, extension, et leurs variantes `.dev` |
| `Scripts/release.sh` | archive Release universelle ; un premier essai a échoué sur « The timestamp service is not available » (service d'Apple), le suivant a réussi |
| `Scripts/verify-release.sh` | **32 contrôles, 0 échec** (app et extension : signature, runtime durci, horodatage, sandbox, groupe, trousseau, profils ; domaine associé ; point d'extension ; aucun moteur web ; aucun reliquat de développement ; aucune exception ATS) |
| Notarisation | app : **Accepted** (`09917a48-b804-445c-af33-0f52ee867c4b`) ; DMG : **Accepted** (`21ed54f6-3f90-4eec-8059-33eb050cbbeb`) ; tickets agrafés |
| Gatekeeper | `spctl` : app et DMG « accepted — Notarized Developer ID » |
| DMG | `dist/SPDrive-1.0.0.dmg`, SHA-256 dans `dist/SPDrive-1.0.0.dmg.sha256` |

## Non vérifié

1. **Tout ce qui passe par le Finder** : ouvrir, modifier, enregistrer, renommer, supprimer dans l'emplacement SP Drive ;
   synchronisation des modifications ; conflit vu par le système ; hors ligne par le Finder ; épinglage et éviction ;
   vignettes. Cause : macOS garde l'emplacement désactivé jusqu'à l'accord du propriétaire dans Réglages Système, et le
   mode de test d'Apple exige un droit que l'API ne permet pas d'obtenir. Le scénario `Scripts/finder-scenario.sh` est
   écrit et **n'a pas été exécuté**.
2. **Passkey réelle (Touch ID)** dans l'application distribuée, contre la production.
3. **Version distribuée contre la production** : elle n'a pas été lancée connectée (aucun compte de test en production).
4. **Redémarrage réel du Mac** ; **reprise après veille** (le code réagit au réveil, non observé).
5. Notifications, barre de menus, verrou Touch ID, ouverture de session, Coup d'œil : non observés à l'écran.
6. VoiceOver ; autre Mac, Intel, macOS 14–26 ; test d'installation depuis le DMG.
7. Tests d'interface XCUITest : aucun (la tournée et l'auto-vérification en tiennent lieu, sans piloter la souris).
8. Débit sur liaison lente ou coûteuse : le conseiller de parallélisme n'est testé que par ses règles.
