#!/usr/bin/env python3
# OCR forcé d'un document (PDF scanné, etc.) via le service Docling.
# Open WebUI n'active PAS l'OCR par défaut → les PDF scannés (sans couche texte)
# reviennent vides. Ce module appelle Docling avec do_ocr+force_ocr pour océriser
# les pages-images et renvoyer le texte. Moteur par défaut = Tesseract (fra) :
# sur les scans d'archives anciens il bat nettement EasyOCR (séparation des mots,
# accents, moins de confusions de lettres), même arbitrage que ocr.sh.
#
# Utilisé par import-corpus.py pour les documents ; exécutable seul pour tester :
#   ./docling_ocr.py "corpus/1960 - Hauteurs pluviométriques.pdf"
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-06-18
# Licence : CC BY-NC-SA 4.0, https://creativecommons.org/licenses/by-nc-sa/4.0/
import json
import mimetypes
import os
import sys
import threading
import urllib.error
import urllib.request
import uuid

DOCLING_URL = os.environ.get("DOCLING_URL", "http://localhost:5001").rstrip("/")
# L'OCR GPU sature Docling si trop d'appels concurrents (vu : 336 timeouts 504
# avec 8 workers). On sérialise les OCR via un sémaphore : le GPU traite de
# toute façon une image à la fois. Les uploads légers, eux, restent parallèles.
_OCR_SLOTS = threading.Semaphore(int(os.environ.get("DOCLING_OCR_CONCURRENCY", "2")))
_OCR_TIMEOUT = int(os.environ.get("DOCLING_OCR_TIMEOUT", "900"))
# Documents que Docling sait extraire/océriser (hors images, gérées par image_extract).
DOC_EXTS = {".pdf", ".docx", ".doc", ".pptx", ".ppt", ".xlsx", ".xls", ".html", ".htm"}


def _multipart(fields, files):
    """Construit un corps multipart/form-data. fields = dict (valeur str, ou liste
    de str pour un champ répété), files = [(name, path)]."""
    boundary = uuid.uuid4().hex
    body = b""
    for k, v in fields.items():
        values = v if isinstance(v, list) else [v]
        for item in values:
            body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{item}\r\n").encode()
    for name, path in files:
        fn = os.path.basename(path)
        ctype = mimetypes.guess_type(fn)[0] or "application/octet-stream"
        with open(path, "rb") as f:
            data = f.read()
        body += (f"--{boundary}\r\n"
                 f"Content-Disposition: form-data; name=\"{name}\"; filename=\"{fn}\"\r\n"
                 f"Content-Type: {ctype}\r\n\r\n").encode() + data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    return body, f"multipart/form-data; boundary={boundary}"


def ocr_document(path, force=True):
    """Renvoie le texte (markdown) extrait par Docling, OCR forcé sur GPU.
    Renvoie '' si Docling ne produit rien."""
    # Moteur OCR = Tesseract (fra) par défaut. Sur les scans d'archives anciens,
    # Tesseract bat nettement EasyOCR (séparation des mots, accents, moins de
    # confusions de lettres), même arbitrage que ocr.sh. Surchargé par les
    # variables d'env DOCLING_PIPELINE_OCR_ENGINE / DOCLING_PIPELINE_OCR_LANG
    # (cf. docker-compose.yml, où le pack langue fra est monté dans l'image).
    # NB : « ocr_engine » est DEPRECATED côté docling-serve (ignoré, retombe sur
    # « auto » → RapidOCR) ; le paramètre effectif est « ocr_preset ». ocr_lang
    # est une liste (un champ répété), pas une simple chaîne.
    fields = {
        "do_ocr": "true",
        "force_ocr": "true" if force else "false",
        "ocr_preset": os.environ.get("DOCLING_PIPELINE_OCR_ENGINE", "tesseract"),
        "ocr_lang": os.environ.get("DOCLING_PIPELINE_OCR_LANG", "fra").split(","),
        "image_export_mode": "placeholder",
        "to_formats": "md",
    }
    body, ctype = _multipart(fields, [("files", path)])
    req = urllib.request.Request(
        f"{DOCLING_URL}/v1/convert/file",
        data=body, headers={"Content-Type": ctype}, method="POST",
    )
    # Sémaphore : limite les OCR GPU simultanés pour ne pas saturer Docling (504).
    with _OCR_SLOTS:
        try:
            with urllib.request.urlopen(req, timeout=_OCR_TIMEOUT) as resp:
                d = json.loads(resp.read())
        except (urllib.error.URLError, urllib.error.HTTPError, ValueError) as e:
            print(f"   ⚠ Docling OCR indisponible : {e}", file=sys.stderr)
            return ""
    doc = d.get("document", {}) or {}
    return (doc.get("md_content") or doc.get("text_content") or "").strip()


def is_document(path):
    return os.path.splitext(path)[1].lower() in DOC_EXTS


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: docling_ocr.py <document>", file=sys.stderr); sys.exit(1)
    txt = ocr_document(sys.argv[1])
    print(f"[{len(txt)} caractères extraits]\n")
    print(txt[:1000])
