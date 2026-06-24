#!/usr/bin/env python3
# Import d'un dossier de documents (Word/Excel/PDF/TXT/MD…) dans une base
# « Connaissances » d'Open WebUI, via son API REST. Alternative au glisser-
# déposer dans l'UI : on dépose les fichiers dans corpus/ (à la racine du projet
# OllamaRAG, à côté de ce script) et on lance ceci.
#
# Open WebUI extrait (Docling) + vectorise (bge-m3) automatiquement à l'ajout.
# Le script est IDEMPOTENT : il garde une trace des fichiers déjà importés
# (.import-state.json) et ne réimporte que le nouveau ou le modifié.
#
# Aucune dépendance externe (stdlib uniquement).
#
# Usage :
#   export OPENWEBUI_API_KEY=sk-...        # clé créée dans Open WebUI
#   ./import-corpus.py                     # importe corpus/ → base "Connaissances"
#   ./import-corpus.py --dir corpus --collection "Connaissances"
#   ./import-corpus.py --url http://localhost:3001 --force
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-06-18
# Licence : CC BY-NC-SA 4.0 — https://creativecommons.org/licenses/by-nc-sa/4.0/
import argparse
import hashlib
import json
import mimetypes
import os
import sys
import threading
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed


def _load_dotenv(path=".env"):
    """Charge .env dans l'environnement (sans écraser l'existant).
    Appelé AVANT d'importer docling_ocr/image_extract, qui figent des réglages
    (sémaphore OCR, modèle vision) à partir des variables d'env dès leur import.
    Le .env vit à la racine du projet (avec OPENWEBUI_API_KEY), à côté de ce script."""
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


_load_dotenv()  # doit précéder les imports locaux ci-dessous

import image_extract  # conversion + OCR + description vision des images  # noqa: E402
import docling_ocr    # OCR forcé GPU des documents scannés (PDF sans texte) # noqa: E402

# Extensions de DOCUMENTS, gérées directement par l'extraction d'Open WebUI / Docling.
SUPPORTED = {
    ".pdf", ".txt", ".md", ".markdown", ".rst", ".csv",
    ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
    ".html", ".htm", ".json", ".xml",
}
# Les IMAGES (tous formats, cf. image_extract) sont aussi acceptées : leur
# CONTENU est extrait (OCR + vision) puis indexé comme texte.
SUPPORTED |= image_extract.IMAGE_EXTS

STATE_FILE = ".import-state.json"

# Fichiers parasites (recréés par Windows / Paint Shop Pro en naviguant dans le
# corpus depuis un poste Windows). Ce ne sont JAMAIS des documents : on les
# ignore SILENCIEUSEMENT, sans les compter comme « format non géré ».
#   - Thumbs.db, desktop.ini : vignettes / métadonnées de l'Explorateur Windows.
#   - pspbrwse.jbf           : cache de vignettes Paint Shop Pro.
#   - .DS_Store              : équivalent macOS.
JUNK_NAMES = {"thumbs.db", "desktop.ini", ".ds_store"}
JUNK_EXTS = {".jbf"}

# Journal PERSISTANT des fichiers écartés et de la RAISON : permet de garder la
# trace des exclusions légitimes (ex. scans purement photographiques sans texte)
# d'un run à l'autre, au lieu de les re-tenter en silence à chaque fois.
SKIPPED_LOG = ".import-skipped.log"


def log(msg):
    print(f"\033[1;34m==>\033[0m {msg}")


def warn(msg):
    print(f"\033[1;33m⚠\033[0m  {msg}", file=sys.stderr)


def skipped(msg):
    """Fichier écarté : raison EXPLICITE à l'écran (jaune, préfixe ⊘)."""
    print(f"\033[1;33m⊘\033[0m  {msg}", file=sys.stderr)


def die(msg, code=1):
    print(f"\033[1;31m✗\033[0m {msg}", file=sys.stderr)
    sys.exit(code)


def api(url, path, key, method="GET", data=None, multipart=None, tolerant=False,
        on_error=None):
    """Appel JSON ou multipart à l'API d'Open WebUI. Renvoie le JSON décodé.
    tolerant=True : sur erreur HTTP, n'arrête PAS le script — renvoie None et
    affiche un avertissement (utilisé pour les appels par-fichier, afin qu'un
    fichier vide/illisible ne bloque pas l'import des autres).
    on_error : callable(code, detail) appelé sur erreur HTTP tolérée AVANT tout
    affichage. S'il renvoie True, l'avertissement HTTP brut est supprimé (la
    raison qualifiée est alors loguée par l'appelant, pas un HTTP 400 cryptique)."""
    full = url.rstrip("/") + path
    headers = {"Authorization": f"Bearer {key}", "Accept": "application/json"}
    body = None
    if multipart is not None:
        filename, content = multipart
        boundary = uuid.uuid4().hex
        ctype = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        pre = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{os.path.basename(filename)}"\r\n'
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
        detail = e.read().decode(errors="replace")
        if tolerant:
            # L'appelant peut intercepter pour qualifier la raison (vide,
            # doublon…) et supprimer l'avertissement HTTP brut redondant.
            handled = on_error(e.code, detail) if on_error else False
            if not handled:
                warn(f"HTTP {e.code} sur {path} : {detail}")
            return None
        die(f"API {method} {path} → HTTP {e.code} : {detail}")
    except urllib.error.URLError as e:
        die(f"Open WebUI injoignable sur {url} : {e.reason}\n"
            f"   Lance la stack RAG : docker compose up -d")


def get_or_create_collection(url, key, name):
    """Retourne l'id de la base cible. On la cible en priorité par ID
    (RAG_COLLECTION_ID dans .env) : ainsi un renommage de la base par un admin ne
    casse pas l'import. À défaut d'ID, on la trouve par nom, et on la crée si elle
    n'existe pas. La réponse de l'API peut être une liste ou un objet {items}."""
    existing = api(url, "/api/v1/knowledge/", key)
    if isinstance(existing, dict):
        existing = existing.get("items", [])
    existing = existing or []

    cid = os.environ.get("RAG_COLLECTION_ID", "").strip()
    if cid:
        for kb in existing:
            if isinstance(kb, dict) and kb.get("id") == cid:
                log(f"Base ciblée par id {cid} (nom actuel : « {kb.get('name')} »).")
                return cid
        die(f"RAG_COLLECTION_ID={cid} introuvable dans Open WebUI.\n"
            "   Vérifie l'id dans .env (ou retire-le pour cibler par nom).")

    for kb in existing:
        if isinstance(kb, dict) and kb.get("name") == name:
            log(f"Base « {name} » existante (id {kb['id']}).")
            return kb["id"]
    created = api(url, "/api/v1/knowledge/create", key, method="POST",
                  data={"name": name, "description": f"Corpus importé depuis {name}"})
    log(f"Base « {name} » créée (id {created['id']}).")
    return created["id"]


def file_digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description="Importe un dossier de documents dans Open WebUI.")
    ap.add_argument("--dir", default="corpus", help="dossier des documents (défaut : corpus, à la racine du projet)")
    ap.add_argument("--collection", default="Connaissances", help="nom de la base (défaut : Connaissances)")
    ap.add_argument("--url", default=os.environ.get("OPENWEBUI_URL", "http://localhost:3001"),
                    help="URL d'Open WebUI (défaut : http://localhost:3001)")
    ap.add_argument("--force", action="store_true", help="réimporter même les fichiers déjà vus")
    ap.add_argument("--jobs", "-j", type=int, default=6,
                    help="nombre de fichiers traités en parallèle (défaut : 6). "
                         "Plus = plus de pression sur Docling/embeddings (max local).")
    args = ap.parse_args()

    # On se place dans le dossier du script pour résoudre les chemins relatifs.
    # (.env déjà chargé tout en haut, avant les imports locaux.)
    os.chdir(os.path.dirname(os.path.abspath(__file__)))

    key = os.environ.get("OPENWEBUI_API_KEY", "").strip()
    if not key:
        die("Variable OPENWEBUI_API_KEY non définie (ni dans .env, ni exportée).\n"
            "   Crée une clé dans Open WebUI → Paramètres → Compte → Clés API,\n"
            "   puis colle-la dans .env (OPENWEBUI_API_KEY=sk-...).")

    corpus = os.path.abspath(args.dir)
    if not os.path.isdir(corpus):
        die(f"Dossier introuvable : {corpus}")

    files = []
    for root, _, names in os.walk(corpus):
        for n in sorted(names):
            # Ignorer les fichiers internes (état d'import, gitkeep, cachés).
            if n in (".gitkeep", STATE_FILE) or n.startswith("."):
                continue
            # Ignorer SILENCIEUSEMENT les parasites Windows/PSP (Thumbs.db,
            # pspbrwse.jbf, etc.) : ce ne sont jamais des documents.
            if n.lower() in JUNK_NAMES or os.path.splitext(n)[1].lower() in JUNK_EXTS:
                continue
            if os.path.splitext(n)[1].lower() in SUPPORTED:
                files.append(os.path.join(root, n))
            else:
                warn(f"Ignoré (format non géré) : {n}")
    if not files:
        log(f"Aucun document à importer dans {corpus}. "
            f"Formats acceptés : {', '.join(sorted(SUPPORTED))}")
        return

    # État d'import (idempotence) : chemin relatif → sha256.
    state_path = os.path.join(corpus, STATE_FILE)
    state = {}
    if os.path.isfile(state_path) and not args.force:
        try:
            state = json.load(open(state_path))
        except (ValueError, OSError):
            state = {}

    col_id = get_or_create_collection(args.url, key, args.collection)

    # Filtrage idempotent en amont : on ne soumet au pool que le travail réel.
    todo = []
    up_to_date = 0
    for path in files:
        rel = os.path.relpath(path, corpus)
        digest = file_digest(path)
        if not args.force and state.get(rel) == digest:
            up_to_date += 1
        else:
            todo.append((path, rel, digest))

    lock = threading.Lock()
    counters = {"imported": 0, "failed": 0}
    skip_records = []  # (rel, raison) des fichiers écartés, pour le journal final

    def upload_and_attach(name, content):
        """Téléverse `content` sous `name` et le rattache à la collection.
        Renvoie un code QUALIFIÉ : 'ok', 'upload_fail', 'empty' (contenu jugé
        vide par Open WebUI), 'duplicate' (contenu déjà présent dans la base),
        ou 'attach_fail' (autre erreur d'attache)."""
        up = api(args.url, "/api/v1/files/", key, method="POST",
                 multipart=(name, content), tolerant=True)
        file_id = up.get("id") if up else None
        if not file_id:
            return "upload_fail"
        # On classe l'erreur d'attache d'après le message d'Open WebUI : 'empty'
        # et 'duplicate' sont des cas ATTENDUS (scan sans texte / doublon), pas
        # des bugs → on supprime l'avertissement HTTP brut et on retient le motif.
        outcome = {"reason": "attach_fail"}

        def classify(code, detail):
            low = detail.lower()
            if "content provided is empty" in low:
                outcome["reason"] = "empty"
                return True
            if "duplicate content" in low:
                outcome["reason"] = "duplicate"
                return True
            return False

        res = api(args.url, f"/api/v1/knowledge/{col_id}/file/add", key,
                  method="POST", data={"file_id": file_id}, tolerant=True,
                  on_error=classify)
        return "ok" if res is not None else outcome["reason"]

    def reject(rel, reason):
        """Enregistre un rejet AVEC sa raison : affichage + comptage + journal."""
        skipped(f"Écarté : {rel}\n     ↳ raison : {reason}")
        with lock:
            counters["failed"] += 1
            skip_records.append((rel, reason))
        return False

    def process(item):
        """Traite UN fichier. Tourne dans un thread → recouvre extraction Docling
        (multi-worker) et embedding GPU. Renvoie True si importé."""
        path, rel, digest = item

        # 1) Images : on indexe le CONTENU reconnu (vision + OCR), pas le binaire.
        if image_extract.is_image(path):
            log(f"Image → contenu : {rel}")
            try:
                text, tmp_png = image_extract.extract(path)
            except RuntimeError as e:
                return reject(rel, f"image illisible/non convertible : {e}")
            if tmp_png and os.path.isfile(tmp_png):
                os.remove(tmp_png)
            if not text.strip():
                return reject(rel, "image sans texte ni description exploitable "
                                   "(OCR vide et modèle vision indisponible)")
            status = upload_and_attach(path + ".txt", text.encode("utf-8"))
            if status == "upload_fail":
                return reject(rel, "téléversement du texte d'image échoué (réseau/API)")
            if status == "empty":
                return reject(rel, "contenu d'image jugé vide par Open WebUI "
                                   "(texte reconnu trop pauvre pour être indexé)")
            if status == "duplicate":
                return reject(rel, f"texte d'image ({len(text)} car.) déjà présent "
                                   "dans la base (doublon refusé par Open WebUI)")
            if status == "attach_fail":
                return reject(rel, "rattachement du texte d'image à la base échoué (API)")
        else:
            # 2) Documents : upload direct (rapide pour les PDF avec couche texte).
            log(f"Téléversement : {rel}")
            with open(path, "rb") as f:
                content = f.read()
            status = upload_and_attach(path, content)
            if status == "upload_fail":
                return reject(rel, "téléversement du document échoué (réseau/API)")
            if status == "duplicate":
                return reject(rel, "document déjà présent dans la base "
                                   "(doublon refusé par Open WebUI)")
            if status == "attach_fail":
                return reject(rel, "rattachement du document à la base échoué (API)")

            # 3) Repli OCR-GPU : si le doc revient vide (PDF scanné sans texte),
            #    on force l'OCR via Docling sur la RTX et on indexe le texte obtenu.
            if status == "empty":
                if not docling_ocr.is_document(path):
                    return reject(rel, "document sans couche texte et type non "
                                       "OCRisable (pas de repli OCR pour ce format)")
                log(f"OCR GPU forcé (scan) : {rel}")
                text = (docling_ocr.ocr_document(path, force=True) or "").strip()
                if not text:
                    return reject(rel, "scan sans texte exploitable : OCR GPU forcé "
                                       "n'a extrait aucun texte (page purement "
                                       "graphique/photographique, ex. planche photo)")
                status = upload_and_attach(path + ".ocr.txt", text.encode("utf-8"))
                if status == "upload_fail":
                    return reject(rel, "téléversement du texte OCR échoué (réseau/API)")
                if status == "duplicate":
                    return reject(rel, f"texte OCR ({len(text)} car.) déjà présent "
                                       "dans la base : doublon refusé par Open WebUI "
                                       "(même contenu déjà indexé sous un autre fichier)")
                if status == "empty":
                    return reject(rel, f"texte OCR ({len(text)} car.) jugé vide par "
                                       "Open WebUI (ex. uniquement « <!--image--> », "
                                       "page purement graphique)")
                if status == "attach_fail":
                    return reject(rel, "rattachement du texte OCR à la base échoué (API)")

        # Section critique : MAJ de l'état partagé + sauvegarde au fil de l'eau.
        with lock:
            state[rel] = digest
            counters["imported"] += 1
            json.dump(state, open(state_path, "w"), indent=2, ensure_ascii=False)
        return True

    log(f"{len(todo)} fichier(s) à traiter en {args.jobs} workers parallèles "
        f"({up_to_date} déjà à jour).")
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(process, it) for it in todo]
        for _ in as_completed(futures):
            pass

    imported, failed = counters["imported"], counters["failed"]
    log(f"Terminé : {imported} importé(s), {up_to_date} déjà à jour, "
        f"{failed} écarté(s). Base « {args.collection} » (id {col_id}).")

    # Journal PERSISTANT des fichiers écartés + récap groupé par raison à l'écran.
    if skip_records:
        skip_path = os.path.join(corpus, SKIPPED_LOG)
        with open(skip_path, "w", encoding="utf-8") as fh:
            fh.write("# Fichiers écartés à l'import (non indexés dans le RAG) et "
                     "raison.\n# Régénéré à chaque exécution de import-corpus.py.\n\n")
            for rel, reason in sorted(skip_records):
                fh.write(f"{rel}\n    ↳ {reason}\n")
        # Récap groupé : combien de fichiers par raison.
        by_reason = {}
        for _, reason in skip_records:
            by_reason[reason] = by_reason.get(reason, 0) + 1
        warn(f"{len(skip_records)} fichier(s) écarté(s), par raison :")
        for reason, n in sorted(by_reason.items(), key=lambda x: -x[1]):
            print(f"     • {n}× {reason}", file=sys.stderr)
        print(f"     → détail complet : {os.path.join(args.dir, SKIPPED_LOG)}",
              file=sys.stderr)

    print(f"  → Base « Connaissances » prête (id {col_id}). "
          f"Sélectionne-la dans Open WebUI pour interroger ces documents.")


if __name__ == "__main__":
    main()
