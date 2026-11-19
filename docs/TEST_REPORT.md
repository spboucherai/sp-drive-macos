<!--
SP Drive — macOS
File: docs/TEST_REPORT.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Rapport de tests — SP Drive 2.0 (branche `next`), 2026-11-19

Même machine. Variante de test « SP Drive Dev » contre le backend **2.0** local (`Scripts/backend-dev.sh start` :
clone de `sp-drive.git` branche `next` @ 0742bf2, base `sp_drive_macdev`, port 8665, deux comptes, aide locale
d'extraction de texte construite). Le fournisseur d'IA est **faux** (`Scripts/fake-ai.mjs`, protocole OpenAI) :
aucun vrai modèle, aucune vraie clé. La production n'a pas été touchée.

| Suite | Résultat |
|---|---|
| `Scripts/t.sh` — `CoreTests` | **61 / 61** (42 de la 1.0 + 18 politiques du moteur 2.0 + flux SSE réel) |
| `Scripts/t.sh` — `NextTests` (`SPDriveNext`, HTTP réel) | **14 / 14** : capacités, sessions et en-tête client, flux d'événements, flux muet coupé par le délai, recherche et extraits, recherche par le sens, IA (faux fournisseur), partage privé à deux comptes par rôle, collections, activité, stockage, doublons, versions, historique d'envois, administration |
| Auto-vérification de l'app (`-spdSelfTest YES`) | **65 / 65** au deuxième lancement. Le premier, juste après la liaison de l'appareil, a rendu 18 / 20 (« fenêtre principale » et épinglage) puis s'est arrêté : non reproduit |
| Tournée (`-spdTour YES`) | 36 écrans, aucun plantage |
| Scénario Finder (`Scripts/finder-scenario.sh`) | **22 / 22** |
| `Scripts/release.sh` puis `Scripts/verify-release.sh` | archive Release 2.0.0 (2), x86_64 + arm64, **32 contrôles, 0 échec**. **Pas de notarisation, pas d'installation, pas d'étiquette** |

Mesures : changement poussé par le flux reflété en 0,10 s (essai du moteur) et 0,47 s (dans l'app) ; plafond 1 Mio/s :
envoi de 4 Mio en 4,0 s ; reprise après `SIGKILL` : 5,2 Mo sur 12,6 déjà sur le serveur, même session terminée.

Détail fonction par fonction, et tout ce qui n'a **pas** été vérifié : `docs/next/AUDIT-macOS.md` (§7) et la seconde
partie de `docs/FEATURE_MATRIX.md`.

---

# Rapport de tests — 1.0, 2026-11-18

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
| Extension File Provider | reconnue par `pluginkit`, domaine créé (`~/Library/CloudStorage/SPDriveDev-Dev`), activé par le propriétaire dans Réglages Système à 15:50 |

## Par le Finder — `Scripts/finder-scenario.sh` : **22 / 22**

Variante de test, emplacement « SP Drive Dev », backend local. Toutes les opérations passent par le système de fichiers
(`~/Library/CloudStorage/SPDriveDev-Dev`), donc par `fileproviderd` et l'extension ; chaque contrôle lit le serveur ou le disque.

| Étape | Vérifié |
|---|---|
| 1. Parcourir, télécharger | dossier créé par un autre appareil visible ; petit fichier lu = contenu du serveur ; fichier de 20 Mo lu avec le SHA-256 du serveur |
| 2. Modifier | fichier modifié dans le Finder → version 2 sur le serveur, contenu identique |
| 3. Créer, renommer, déplacer | fichier et dossier créés, renommage, déplacement : confirmés par le serveur |
| 4. Conflit | fichier changé par un autre appareil puis modifié ici depuis l'ancienne version → copie « (conflit …) » sur le serveur, version de l'autre appareil **non écrasée**, version de ce Mac préservée, le Finder montre les deux |
| 5. Hors ligne | serveur arrêté : modification d'un petit fichier et d'un fichier de 20 Mo, ajout d'un fichier, création d'un dossier avec un fichier ; application et extension tuées puis relancées ; changements toujours sur le Mac ; serveur relancé → tout arrive intact (SHA-256) |
| 6. Supprimer | suppression dans le Finder → corbeille du serveur (pas de destruction) ; restauration sur le serveur → retour dans le Finder |

Épinglage hors ligne (essai dédié, fichier de 6 Mo jamais ouvert) : épinglé par l'app → téléchargé (0 → 11 720 blocs),
SHA-256 identique ; éviction demandée → **refusée par le système** tant qu'il est épinglé ; désépinglé → évincé (0 bloc) ;
relu → contenu identique. Constat au passage : `requestDownloadForItem` est accepté mais différé par macOS sur batterie ;
l'app lit donc elle-même les fichiers épinglés (lecture coordonnée) pour un téléchargement immédiat.
Auto-vérification relancée avec l'emplacement actif : **19 / 19**, épinglage compris.

Plantage rencontré et corrigé pendant ces essais : cellules de tableau, menus et barre d'outils lisaient le modèle dans
l'environnement SwiftUI, absent à ces endroits sur macOS 27 ; le modèle leur est maintenant passé explicitement.

## Distribution

| Étape | Résultat |
|---|---|
| Identité | `Developer ID Application: Simon-Pierre Boucher (3YM54G49SN)`, existante |
| Profils | 4 profils Developer ID créés par l'API App Store Connect (clé existante) : app, extension, et leurs variantes `.dev` |
| `Scripts/release.sh` | archive Release universelle ; un premier essai a échoué sur « The timestamp service is not available » (service d'Apple), le suivant a réussi |
| `Scripts/verify-release.sh` | **32 contrôles, 0 échec** (app et extension : signature, runtime durci, horodatage, sandbox, groupe, trousseau, profils ; domaine associé ; point d'extension ; aucun moteur web ; aucun reliquat de développement ; aucune exception ATS) |
| Notarisation | build final — app : **Accepted** (`1ca74420-e135-4316-8a57-75d47371b32f`) ; DMG : **Accepted** (`62555e76-2f34-4708-ad37-d6c2aa2ab8ee`) ; tickets agrafés (un premier build avait été accepté à 15:27 : `09917a48…`, `21ed54f6…`) |
| Gatekeeper | `spctl` : app et DMG « accepted — Notarized Developer ID » |
| DMG | `dist/SPDrive-1.0.0.dmg`, SHA-256 dans `dist/SPDrive-1.0.0.dmg.sha256` |
| Installation | DMG monté, signature et ticket validés sur l'image, app copiée dans `/Applications`, acceptée par Gatekeeper, lancée : écran de connexion sur drive.spboucher.ai |

## Non vérifié

1. **Le Finder sur la version distribuée** : le scénario a été exécuté sur la variante de test (même code, autres
   identifiants). L'emplacement « SP Drive » de production n'existe qu'après connexion du propriétaire, qui devra aussi
   l'activer dans Réglages Système. Vignettes dans le Finder : non observées. Ouverture et enregistrement depuis une
   application graphique (Pages, Aperçu…) : non observés — les écritures ont été faites par le système de fichiers.
2. Passkey réelle (Touch ID) dans l'application distribuée, contre la production : **fonctionne**, constaté par le propriétaire et non par un test automatisé. Premier essai du propriétaire à
   15:50 : erreur 1004. Cause établie : le robot d'Apple avait demandé le fichier d'association à 15:08, avant la mise en
   production de la route ; le site avait répondu sa page HTML et le CDN d'Apple a gardé « Bad JSON content » une heure
   (visible avec `nscurl -i https://app-site-association.cdn-apple.com/a/v1/drive.spboucher.ai`, pas avec `curl`, dont
   l'en-tête `Accept-Encoding` désigne une autre entrée du cache). À 16:08 le CDN renvoie le bon fichier et `swcd` ne
   journalise plus de refus. Nouvel essai du propriétaire vers 16:10 : **connexion réussie** (confirmée par lui ; l'emplacement
   « SP Drive » de production est alors créé, en attente de son activation dans Réglages Système).
3. **Version distribuée contre la production** : elle n'a pas été lancée connectée (aucun compte de test en production).
4. **Redémarrage réel du Mac** ; **reprise après veille** (le code réagit au réveil, non observé).
5. Notifications, barre de menus, verrou Touch ID, ouverture de session, Coup d'œil : non observés à l'écran.
6. VoiceOver ; autre Mac, Intel, macOS 14–26.
7. Tests d'interface XCUITest : aucun (la tournée et l'auto-vérification en tiennent lieu, sans piloter la souris).
8. Débit sur liaison lente ou coûteuse : le conseiller de parallélisme n'est testé que par ses règles.
