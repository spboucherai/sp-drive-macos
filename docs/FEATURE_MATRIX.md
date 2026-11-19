<!--
SP Drive — macOS
File: docs/FEATURE_MATRIX.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Matrice de parité — site web ↔ client macOS

État au 2026-11-18. « Vérifié » dit **comment** : T = tests Swift contre le vrai backend local (`Scripts/t.sh`),
A = auto-vérification de l'app signée (`-spdSelfTest`), V = écran vu dans la tournée (`-spdTour`),
F = scénario par le Finder (`Scripts/finder-scenario.sh`). **Non vérifié** est écrit en toutes lettres.

## Existant sur le site, repris dans le client

| Fonction | Site | Client macOS | Vérifié |
|---|---|---|---|
| Connexion par passkey | oui | oui (feuille système, `webcredentials`) | serveur : T (authentificateur logiciel). **Feuille Touch ID réelle : non vérifiée** (exige la passkey du propriétaire) |
| Sessions, révocation d'appareil | oui | oui (Paramètres › Compte) | T |
| Parcourir dossiers et fichiers | oui | oui (liste, grille, fil d'Ariane) | T, A, V |
| Créer un dossier, renommer, déplacer, dupliquer | oui | oui (hors ligne aussi) | T, A |
| Favoris | oui | oui | T, A |
| Téléverser (résumable, blocs + SHA-256) | oui | oui (file persistante, blocs adaptatifs) | T (48 Mo, coupure, panne serveur), A |
| Téléverser un dossier | oui | oui (glisser-déposer, sélecteur) | **non vérifié de bout en bout** (code exercé fichier par fichier) |
| Télécharger (`Range`) | oui | oui (reprise, vérification SHA-256, placement atomique) | T, A |
| Aperçu | oui (pdf.js, images…) | oui (Coup d'œil natif sur copie vérifiée) | copie locale : A. **Panneau Coup d'œil : non vérifié à l'écran** |
| Vignettes | oui | dans le Finder (File Provider) | **non vérifié** |
| Corbeille, restauration, purge | oui | oui (purge après confirmation, en ligne seulement) | T, A |
| Versions : liste, téléchargement, restauration, suppression | oui | oui | T, A, V |
| Recherche (nom, type, dates, tailles, favoris) | oui | oui, locale, hors ligne (+ extension, dossier, partagés) | T, V |
| Liens de partage (mot de passe, expiration, plafonds, usage unique, révocation, journal) | oui | oui | T (accès public réel), A, V |
| Liens de dépôt (portails) | oui | oui (création, pause, renouvellement, révocation, dépôts reçus) | T (dépôt public réel), V |
| Notification de dépôt | dans le site | notification macOS | serveur : T. **Notification affichée : non vérifiée** |
| Quota | oui | oui (barre latérale, Stockage, barre de menus) | A, V |
| Étiquettes | oui | non repris | — |
| Doublons | oui | non repris | — |
| Administration (invitations, quotas) | oui | non repris (reste sur le site) | — |
| Récupération par code, TOTP, ajout de passkey | oui | non repris (reste sur le site) | — |

## Propre au client macOS (développé)

| Fonction | État | Vérifié |
|---|---|---|
| Emplacement SP Drive dans le Finder (File Provider répliqué) | oui | F : 22 / 22 sur la variante de test (lecture, modification, création, renommage, déplacement, conflit, hors ligne avec redémarrage de l'extension, suppression). Sur la version distribuée : après connexion et activation par le propriétaire, **non observé** |
| Liaison d'appareil par code | oui | T, et utilisée pour connecter l'app de test |
| Journal d'opérations hors ligne (créer, renommer, déplacer, corbeille, favoris), rejoué à la reconnexion | oui | T (serveur arrêté, « redémarrage », reprise) |
| Ajout de fichiers hors ligne | oui (copie mise en attente) | T |
| Synchronisation incrémentale (flux de changements) | oui | T |
| Détection de conflit, copie de conflit, résolution | oui | T (moteur, file), F (par le Finder) ; écran de résolution : V |
| Disponibilité hors ligne (épingler fichier / dossier) | oui, politique de contenu du File Provider + lecture immédiate par l'app | fichier : téléchargé, SHA-256 identique, éviction refusée par le système, A. **Dossier entier : non vérifié** |
| Libérer l'espace local / vider le cache | oui | éviction d'un fichier désépinglé puis relecture intacte : vérifiée ; cache : A |
| File de transferts : pause, reprise, annulation, réessai, priorités, parallélisme adaptatif, limites de débit | oui | T |
| Barre de menus | oui | **non vérifiée à l'écran** |
| Notifications (lot terminé, conflit, erreur persistante, espace, dépôt) | oui | **non vérifiées à l'écran** |
| Verrou Touch ID | oui | **non vérifié** |
| Ouverture à l'ouverture de session | oui (`SMAppService`) | **non vérifié** |
| Tableau de bord du stockage | oui | V |

## Absent du serveur, donc absent du client

| Fonction | Raison |
|---|---|
| « Partagés avec moi », partage privé entre comptes, permission de modification | le serveur n'a pas de partage entre comptes (hors V1 du backend) : rien n'est affiché plutôt qu'un écran vide |
| Recherche dans le contenu des documents | pas d'index de contenu côté serveur |
| Auteur d'une version | compte unique par arbre : non exposé |
| Chiffrement de bout en bout | non construit ; l'app le dit dans ses réglages |

---

# SP Drive 2.0 — branche `next`, état au 2026-11-19

Même légende, plus : **N** = tests du paquet `SPDriveNext` contre le backend 2.0 local, **S** = capture de la fenêtre
(`docs/next/shots/`). « API » signifie que l'app appelle la même fonction que celle vérifiée, sans que le geste à l'écran
ait été fait. Le fournisseur d'IA des essais est **faux** (`Scripts/fake-ai.mjs`) : aucun vrai modèle n'a été exercé.

| Fonction 2.0 | Client macOS | Vérifié |
|---|---|---|
| Découverte des capacités (`GET /meta`), sections masquées si absentes | oui | N, A |
| En-tête `X-SPD-Client: macos/2.0.0 (…)` (app et extension) | oui | N, A (session vue comme macos/2.0.0) ; extension : par construction, non observée séparément |
| Flux d'événements (SSE) → moteur, repli sondage 30 s, reconnexion | oui | T (changement poussé en 0,1 s ; flux tué → sondage → reconnexion), A (0,5 s) |
| Recherche noms + contenu, passages surlignés | oui (champ de la barre d'outils, Mon Drive) | N, A, S |
| Recherche par le sens | oui (bascule, masquée sans modèle) | N (disponible, résultats) ; écran : S de la tournée |
| SP Drive AI : demander à un document / dossier / Drive, flux, sources numérotées cliquables, choix du modèle (concepteur ≠ fournisseur), états « non configuré » et « rien trouvé » | oui (feuille, fenêtre ⌥⌘A, inspecteur) | N, A, S — **faux fournisseur**. Fenêtre « Demander à mon Drive » et clic sur une citation : non vérifiés |
| Consentement aux fournisseurs externes | oui (Paramètres › Compte) | N (drapeau du compte) ; interrupteur à l'écran : non vérifié |
| Suggestions de rangement (`ai/suggest`) | appel dans le paquet, **pas d'écran** | N (décodage ; le faux fournisseur ne produit pas de vraies suggestions) |
| Collections intelligentes : liste, résultats, éditeur de règle avec aperçu | oui | N, A, S ; enregistrement depuis l'éditeur : API |
| Activité : fichier (inspecteur), dossier, compte (paginé) | oui | N, A, S |
| Versions : frise avec auteur, restauration, comparaison (texte ligne à ligne ; images et PDF côte à côte ; énoncé sinon) | oui | N, A, S (texte). **Images et PDF côte à côte : non regardés** |
| Centre de stockage : espace, types, dossiers avec exploration, croissance 90 j, plus gros fichiers, doublons exacts et images ressemblantes ; aucune suppression automatique | oui | N, A, S ; exploration au clic et bouton Corbeille : API |
| Membres et rôles d'un dossier, nom d'espace de travail, activité du dossier | oui | N, A, S |
| « Partagés avec moi » : parcourir, aperçu, téléchargement, et selon le rôle création / renommage / envoi / corbeille ; dépôt seul | oui | N (toute la famille de routes, deux comptes), A (parcourir + envoi éditeur, 403 puis envoi déposant), S (liste). Gestes à l'écran dans un dossier partagé : non vérifiés |
| Code QR d'un lien (Core Image, local) | oui | A (relu par un détecteur) ; dans la feuille : non regardé |
| Appareils connectés (plateforme, version de l'app, dernière activité, révocation) | oui (Paramètres › Compte) | N, A ; écran : non regardé |
| Portails de dépôt : tous les champs de la demande (instructions, message de fin, en-tête, champs demandés, consentement, plafonds) | oui | corps accepté par le serveur (essai direct) ; création depuis la feuille : non vérifiée |
| Administration (lecture seule, administrateurs) | oui | N, A, S |
| Dossiers partagés dans le Finder | non (contrat : parcourus dans l'app) | — |
| Localisation anglaise | non | — |
