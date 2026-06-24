# Modération de la base de connaissances

Seuls des **modérateurs identifiés** peuvent corriger la base de connaissances du
RAG. Le contrôle d'accès s'appuie sur les **rôles et groupes natifs d'Open WebUI**,
pas sur une clé partagée. La gouvernance est assurée par le **groupe Admins**.

## Modèle d'accès

| Rôle | Interroger le RAG | Corriger la base « Connaissances » | Gérer les modérateurs |
|------|-------------------|------------------------------------|-----------------------|
| Visiteur (`user`) | oui | non | non |
| Modérateur (groupe « Modérateurs ») | oui | oui | non |
| Admin (`admin`) | oui | oui | oui |

- Les corrections manuelles sont ajoutées dans la base **« Connaissances »**
  elle-même. Ce texte propre prime sur l'OCR fautif (cf. README, section
  « Corriger les réponses »). Une seule base à gérer.
- L'écriture sur « Connaissances » est réservée au groupe **« Modérateurs »**.
- Le groupe **« Modérateurs »** existe déjà (créé à l'installation).

## Procédure (interface admin Open WebUI, http://localhost:3001)

Ces opérations se font dans l'interface, l'outil conçu pour gérer les accès de
façon fiable et auditable. Elles sont rares (ajouter ou retirer un modérateur).

### 1. Créer le compte d'un modérateur

1. La personne crée son compte sur http://localhost:3001 (inscription).
2. Le nouveau compte arrive en statut **pending** (en attente).
3. Admin, *Panneau admin, Utilisateurs* : passer le compte en rôle **user**
   (utilisateur standard, pas admin).

### 2. Le déclarer modérateur

1. Admin, *Panneau admin, Groupes* : ouvrir le groupe **Modérateurs**.
2. Ajouter le compte à ce groupe.

### 3. Réserver l'écriture de « Connaissances » aux modérateurs

À faire une seule fois pour la base « Connaissances » :

1. *Espace de travail, Connaissances* : ouvrir la base **Connaissances**.
2. Bouton de partage / contrôle d'accès de la base.
3. Donner au groupe **Modérateurs** l'accès en **écriture**, et le retirer à
   « tout le monde ». Garder l'accès en lecture suffisamment large pour que le
   RAG puisse interroger la base.

Une fois ceci en place, un modérateur corrige directement depuis l'interface
(*Espace de travail, Connaissances*, ajout d'un document) avec son propre compte.
Un visiteur standard n'a pas le bouton d'ajout sur cette base.

### 4. Révoquer un modérateur

*Panneau admin, Groupes, Modérateurs* : retirer le compte du groupe. Il perd
aussitôt le droit d'écrire sur « Connaissances », sans perdre l'accès en lecture.

## Gouvernance par le groupe Admins

- Tout compte en rôle **admin** peut gérer les utilisateurs, les groupes et les
  partages, donc promouvoir ou révoquer des modérateurs.
- Pour ajouter un admin : *Panneau admin, Utilisateurs*, passer le compte en
  rôle **admin**. À n'accorder qu'à des personnes de confiance, un admin a tous
  les droits sur l'instance.
- **Renommer une collection** est réservé aux admins (interface Open WebUI, ou
  `gerer-collections.py`, cf. README). Sans danger pour les scripts, qui ciblent
  la base par id (`RAG_COLLECTION_ID`).

## Outils en ligne de commande (admin uniquement)

Ces outils emploient la clé API admin de `.env` et exigent d'identifier
l'opérateur. Ils ne sont PAS destinés aux modérateurs, qui passent par
l'interface avec leur propre compte.

- `corriger.py` : ajout de corrections en lot (variable `MODERATEUR`).
- `gerer-collections.py` : lister et renommer les collections (variable `ADMIN`).
