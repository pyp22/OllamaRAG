#!/usr/bin/env python3
# Gérer les noms des collections (bases de connaissances) du RAG. OUTIL
# D'ADMINISTRATION : renommer une collection est réservé aux ADMINS. Le script
# emploie la clé API admin de .env.
#
# Cibler une collection par son ID est sûr : le renommage ne change pas l'ID, et
# les scripts (import-corpus.py, corriger.py) ciblent la base par RAG_COLLECTION_ID
# dans .env, donc un renommage ne casse rien.
#
# Aucune dépendance externe (stdlib uniquement).
#
# Usage (admin) :
#   export OPENWEBUI_API_KEY=sk-...   (ou laissé dans .env, lu automatiquement)
#
#   ./collections.py --liste                       # lister les collections (id + nom)
#
#   export ADMIN="Prénom Nom"                       # obligatoire pour renommer
#   ./collections.py --renommer <id> "Nouveau nom"
#   ./collections.py --renommer <id> "Nouveau nom" --description "..."
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-06-23
# Licence : CC BY-NC-SA 4.0, https://creativecommons.org/licenses/by-nc-sa/4.0/
import argparse
import json
import os
import sys
import urllib.error
import urllib.request


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


def api(url, path, key, method="GET", data=None):
    full = url.rstrip("/") + path
    headers = {"Authorization": f"Bearer {key}", "Accept": "application/json"}
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(full, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        die(f"API {method} {path} → HTTP {e.code} : {e.read().decode(errors='replace')}")
    except urllib.error.URLError as e:
        die(f"Open WebUI injoignable sur {url} : {e.reason}\n"
            f"   Lance la stack RAG : docker compose up -d")


def list_collections(url, key):
    d = api(url, "/api/v1/knowledge/", key)
    ks = d.get("items", d) if isinstance(d, dict) else d
    if not ks:
        print("  (aucune collection)")
        return []
    for k in ks:
        print(f"  {k.get('id')}  |  {k.get('name')}")
    return ks


def rename_collection(url, key, cid, new_name, description):
    # On récupère la description actuelle si non fournie, pour ne pas l'écraser.
    current = api(url, f"/api/v1/knowledge/{cid}", key)
    if not current or not current.get("id"):
        die(f"Collection introuvable : {cid}")
    old_name = current.get("name")
    desc = description if description is not None else current.get("description", "")
    updated = api(url, f"/api/v1/knowledge/{cid}/update", key, method="POST",
                  data={"name": new_name, "description": desc})
    if (updated or {}).get("name") != new_name:
        die(f"Renommage non confirmé : {updated}")
    return old_name


def main():
    ap = argparse.ArgumentParser(
        description="Gérer les noms des collections du RAG (admin).")
    ap.add_argument("--liste", "-l", action="store_true",
                    help="lister les collections (id + nom)")
    ap.add_argument("--renommer", "-r", nargs=2, metavar=("ID", "NOUVEAU_NOM"),
                    help="renommer la collection d'id ID en NOUVEAU_NOM")
    ap.add_argument("--description", "-d", default=None,
                    help="changer aussi la description (optionnel)")
    ap.add_argument("--url", default=os.environ.get("OPENWEBUI_URL", "http://localhost:3001"),
                    help="URL d'Open WebUI (défaut : http://localhost:3001)")
    args = ap.parse_args()

    key = os.environ.get("OPENWEBUI_API_KEY", "").strip()
    if not key:
        die("Variable OPENWEBUI_API_KEY non définie (ni dans .env, ni exportée).")

    if args.liste or not args.renommer:
        print("Collections :")
        list_collections(args.url, key)
        if not args.renommer:
            return

    # Renommer est une opération d'admin : on exige d'identifier l'opérateur.
    # La simple possession de la clé admin de .env ne suffit pas.
    admin = os.environ.get("ADMIN", "").strip()
    if not admin:
        die("Renommage refusé : opérateur non identifié.\n"
            "   Déclare ton identité avant de renommer :\n"
            "     export ADMIN=\"Prénom Nom\"")

    cid, new_name = args.renommer
    new_name = new_name.strip()
    if not new_name:
        die("Le nouveau nom est vide.")

    old_name = rename_collection(args.url, key, cid, new_name, args.description)
    log(f"Collection renommée par {admin} : « {old_name} » → « {new_name} » (id {cid}).")
    if os.environ.get("RAG_COLLECTION_ID", "").strip() == cid:
        print("   Cette collection est celle ciblée par les scripts "
              "(RAG_COLLECTION_ID). Ils continuent de fonctionner : ils ciblent "
              "par id, pas par nom.")
    else:
        print("   Note : si des scripts ciblent cette base par NOM, ajuste-les. "
              "Le plus sûr est de renseigner RAG_COLLECTION_ID dans .env.")


if __name__ == "__main__":
    main()
