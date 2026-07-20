#!/usr/bin/env python3
# Corriger en lot les réponses du RAG (OUTIL D'ADMINISTRATION). Quand une réponse
# est fausse (souvent à cause d'une erreur OCR sur un scan), on enregistre ici la
# bonne information, ajoutée à la base « Connaissances » d'Open WebUI : ce texte
# propre et ciblé prime sur l'OCR bruité aux questions suivantes.
#
# CONTRÔLE D'ACCÈS : la modération est réservée à des modérateurs identifiés.
# La voie normale passe par l'INTERFACE Open WebUI, où chaque modérateur agit
# avec SON propre compte (cf. MODERATION.md). Ce script, lui, emploie la clé API
# ADMIN de .env, il n'est donc destiné qu'aux ADMINS, pour des ajouts en lot.
# Pour éviter qu'un simple accès au fichier .env suffise, il EXIGE de tracer
# l'opérateur via la variable d'environnement MODERATEUR (nom de la personne).
# Chaque correction est estampillée à ce nom.
#
# Le scan d'origine n'est PAS modifié. On superpose la vérité dans la base
# « Connaissances », on ne réécrit pas l'archive, donc le bon fait remonte.
#
# Aucune dépendance externe (stdlib uniquement).
#
# Usage (admin) :
#   export OPENWEBUI_API_KEY=sk-...   (ou laissé dans .env, lu automatiquement)
#   export MODERATEUR="Prénom Nom"    (obligatoire pour écrire : trace l'auteur)
#
#   ./corriger.py "sujet de la correction" --texte "le fait correct, en clair"
#   ./corriger.py "date de l'évènement" --texte "..." --source "rapport 1963.pdf"
#   ./corriger.py "nom du responsable"            # demande le texte au clavier
#
#   ./corriger.py --liste              # liste les corrections (lecture, sans MODERATEUR)
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-06-23
# Licence : CC BY-NC-SA 4.0, https://creativecommons.org/licenses/by-nc-sa/4.0/
import argparse
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.request
import uuid

# Les corrections sont écrites dans la MÊME base que le corpus : une seule base à
# interroger, plus besoin d'en sélectionner deux. Le texte de correction, propre
# et ciblé, prime quand même sur l'OCR bruité au retrieval.
# Nom par défaut de la base, en dernier recours seulement : --collection (lu au
# moment de main(), après chargement du .env) et RAG_COLLECTION_NAME priment.
COLLECTION = "Connaissances"


def _load_dotenv(path=".env"):
    here = os.path.dirname(os.path.abspath(__file__))
    full = os.path.join(here, path)
    if not os.path.isfile(full):
        return
    for line in open(full, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


_load_dotenv()


def die(msg, code=1):
    print(f"\033[1;31m✗\033[0m {msg}", file=sys.stderr)
    sys.exit(code)


def log(msg):
    print(f"\033[1;32m✓\033[0m {msg}")


def api(url, path, key, method="GET", data=None, multipart=None):
    """Appel JSON ou multipart à l'API d'Open WebUI. Renvoie le JSON décodé."""
    full = url.rstrip("/") + path
    headers = {"Authorization": f"Bearer {key}", "Accept": "application/json"}
    body = None
    if multipart is not None:
        filename, content = multipart
        boundary = uuid.uuid4().hex
        ctype = mimetypes.guess_type(filename)[0] or "text/plain"
        pre = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; '
            f'filename="{os.path.basename(filename)}"\r\n'
            f"Content-Type: {ctype}\r\n\r\n"
        ).encode()
        post = f"\r\n--{boundary}--\r\n".encode()
        body = pre + content + post
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
    elif data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(full, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        die(f"API {method} {path} → HTTP {e.code} : {e.read().decode(errors='replace')}")
    except urllib.error.URLError as e:
        die(f"Open WebUI injoignable sur {url} : {e.reason}\n"
            f"   Lance la stack RAG : docker compose up -d")


def get_or_create_collection(url, key, name):
    """Résout la base cible. On la cible en priorité par ID (RAG_COLLECTION_ID
    dans .env) : ainsi un renommage de la base par un admin ne casse rien. À
    défaut d'ID, on la trouve par nom, et on la crée si elle n'existe pas."""
    existing = api(url, "/api/v1/knowledge/", key)
    if isinstance(existing, dict):
        existing = existing.get("items", [])
    existing = existing or []

    cid = os.environ.get("RAG_COLLECTION_ID", "").strip()
    if cid:
        for kb in existing:
            if isinstance(kb, dict) and kb.get("id") == cid:
                return cid
        die(f"RAG_COLLECTION_ID={cid} introuvable dans Open WebUI.\n"
            "   Vérifie l'id dans .env (ou retire-le pour cibler par nom).")

    for kb in existing:
        if isinstance(kb, dict) and kb.get("name") == name:
            return kb["id"]
    created = api(url, "/api/v1/knowledge/create", key, method="POST",
                 data={"name": name,
                       "description": "Base de connaissances du RAG."})
    log(f"Base « {name} » créée (id {created['id']}).")
    return created["id"]


def add_correction(url, key, col_id, sujet, texte, source, moderateur):
    """Téléverse la correction en .txt et la rattache à la base Connaissances.
    La fiche est estampillée au nom du modérateur (traçabilité de l'auteur)."""
    src_line = f"Document source concerné : {source}\n" if source else ""
    contenu = (
        f"CORRECTION (fait validé manuellement)\n"
        f"Sujet : {sujet}\n"
        f"Validée par : {moderateur}\n"
        f"{src_line}"
        f"\n"
        f"Information correcte :\n{texte}\n"
        f"\n"
        f"Note : cette fiche corrige une donnée erronée du corpus indexé "
        f"(souvent une erreur d'OCR). Elle fait autorité sur ce point.\n"
    ).encode("utf-8")

    # Nom de fichier lisible et unique (sujet tronqué + court id).
    slug = "".join(c if c.isalnum() or c in " -_" else "_" for c in sujet)[:60].strip()
    fname = f"correction - {slug} - {uuid.uuid4().hex[:8]}.txt"

    up = api(url, "/api/v1/files/", key, method="POST", multipart=(fname, contenu))
    fid = (up or {}).get("id")
    if not fid:
        die(f"Téléversement de la correction échoué : {up}")
    api(url, f"/api/v1/knowledge/{col_id}/file/add", key, method="POST",
        data={"file_id": fid})
    return fname


def list_corrections(url, key, col_id):
    info = api(url, f"/api/v1/knowledge/{col_id}", key)
    files = info.get("files") or (info.get("data") or {}).get("file_ids") or []
    print(f"Base « {COLLECTION} » : {len(files)} correction(s) enregistrée(s).")
    for f in files:
        if isinstance(f, dict):
            meta = f.get("meta") or {}
            print(f"  • {meta.get('name') or f.get('id')}")


def main():
    ap = argparse.ArgumentParser(
        description="Corriger au fil de l'eau les réponses du RAG (cas par cas).")
    ap.add_argument("sujet", nargs="?", help="sujet / intitulé de la correction")
    ap.add_argument("--texte", "-t", help="le fait correct (sinon demandé au clavier)")
    ap.add_argument("--source", "-s", default="",
                    help="document source concerné (optionnel, pour traçabilité)")
    ap.add_argument("--liste", "-l", action="store_true",
                    help="lister les corrections existantes")
    ap.add_argument("--url", default=os.environ.get("OPENWEBUI_URL", "http://localhost:3001"),
                    help="URL d'Open WebUI (défaut : http://localhost:3001)")
    ap.add_argument("--collection", default=os.environ.get("RAG_COLLECTION_NAME", COLLECTION),
                    help="nom de la base cible (défaut : $RAG_COLLECTION_NAME, "
                         f"sinon « {COLLECTION} »). Doit correspondre à import-corpus.py.")
    args = ap.parse_args()

    key = os.environ.get("OPENWEBUI_API_KEY", "").strip()
    if not key:
        die("Variable OPENWEBUI_API_KEY non définie (ni dans .env, ni exportée).")

    col_id = get_or_create_collection(args.url, key, args.collection)

    if args.liste:
        list_corrections(args.url, key, col_id)
        return

    if not args.sujet:
        die("Précise un sujet de correction (ou --liste).\n"
            "   Ex : ./corriger.py \"nom du responsable\" --texte \"...\"")

    # Contrôle d'accès : écrire exige d'identifier l'opérateur. La simple
    # possession de la clé admin de .env ne suffit pas, il faut déclarer qui
    # corrige (trace conservée dans la fiche). La voie modérateur normale reste
    # l'interface Open WebUI avec un compte personnel (cf. MODERATION.md).
    moderateur = os.environ.get("MODERATEUR", "").strip()
    if not moderateur:
        die("Écriture refusée : opérateur non identifié.\n"
            "   Identité à déclarer avant de corriger :\n"
            "     export MODERATEUR=\"Prénom Nom\"\n"
            "   La voie normale pour un modérateur est l'interface Open WebUI\n"
            "   avec son propre compte (cf. MODERATION.md).")

    texte = args.texte
    if not texte:
        print(f"Sujet : {args.sujet}")
        print("Saisis l'information correcte (termine par une ligne vide) :")
        lines = []
        try:
            while True:
                line = input()
                if line == "":
                    break
                lines.append(line)
        except EOFError:
            pass
        texte = "\n".join(lines).strip()
    if not texte:
        die("Aucun texte de correction fourni.")

    fname = add_correction(args.url, key, col_id, args.sujet, texte, args.source,
                           moderateur)
    log(f"Correction enregistrée par {moderateur} : {fname}")
    print("   Elle est indexée et sera prise en compte dès la prochaine question.")
    print(f"   Dans Open WebUI, interroge avec la base « {COLLECTION} » sélectionnée.")


if __name__ == "__main__":
    main()
