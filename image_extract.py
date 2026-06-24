#!/usr/bin/env python3
# Extraction du CONTENU des images, tous formats confondus, pour le RAG.
# Deux niveaux de « reconnaissance », concaténés en un texte indexable :
#   1. OCR  — le texte présent dans l'image (Docling / Tesseract).
#   2. VISION — une description de la scène par un modèle multimodal (llava).
#
# Tout format est d'abord NORMALISÉ en PNG (ImageMagick ; dcraw en repli pour le
# RAW), ce qui couvre JPG/PNG/TIFF/BMP/WEBP/GIF/HEIC/SVG/RAW selon les delegates
# installés. Les formats non convertibles sont signalés, jamais ignorés en silence.
#
# Utilisé par import-corpus.py, mais exécutable seul pour tester une image :
#   ./image_extract.py photo.heic
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-06-18
# Licence : CC BY-NC-SA 4.0 — https://creativecommons.org/licenses/by-nc-sa/4.0/
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

# Formats traités comme « images » (le reste = documents, géré par Docling seul).
IMAGE_EXTS = {
    # courants
    ".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".webp", ".gif",
    # modernes / vectoriel
    ".heic", ".heif", ".avif", ".svg",
    # RAW photo (boîtiers courants)
    ".cr2", ".cr3", ".nef", ".arw", ".dng", ".raf", ".rw2", ".orf", ".pef", ".srw",
}
RAW_EXTS = {".cr2", ".cr3", ".nef", ".arw", ".dng", ".raf", ".rw2", ".orf", ".pef", ".srw"}

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434").rstrip("/")
VISION_MODEL = os.environ.get("VISION_MODEL", "llava:7b")
# Invite de description, en français pour rester cohérent avec le corpus.
VISION_PROMPT = os.environ.get(
    "VISION_PROMPT",
    "Décris précisément et en français le contenu de cette image : objets, "
    "personnes, texte visible, schémas ou graphiques. Sois factuel et concis.",
)


def _have(cmd):
    return shutil.which(cmd) is not None


def is_image(path):
    return os.path.splitext(path)[1].lower() in IMAGE_EXTS


def to_png(src, dst):
    """Normalise n'importe quelle image en PNG. Renvoie True si réussi.

    Cascade : dcraw pour le RAW, sinon ImageMagick (convert) qui couvre le reste
    (y compris HEIC/SVG si les delegates sont installés)."""
    ext = os.path.splitext(src)[1].lower()

    if ext in RAW_EXTS and _have("dcraw"):
        # dcraw → PPM sur stdout, puis convert PPM→PNG.
        try:
            ppm = subprocess.run(["dcraw", "-c", "-w", src], capture_output=True, check=True).stdout
            if _have("convert"):
                subprocess.run(["convert", "ppm:-", dst], input=ppm, check=True)
                return True
        except subprocess.CalledProcessError:
            pass  # on retente via ImageMagick ci-dessous

    # Pillow en priorité pour les rasters : robuste sur les numérisations
    # GÉANTES (vu : 23101×24495 = 566 Mpx) qui font planter ImageMagick en
    # « cache resources exhausted ». On désactive le garde-fou décompression et
    # on réduit à ~2000 px (largement assez pour OCR + vision).
    if ext not in {".svg", ".svgz"}:
        try:
            from PIL import Image
            Image.MAX_IMAGE_PIXELS = None
            im = Image.open(src)
            im.thumbnail((2000, 2000))
            im.convert("RGB").save(dst, "PNG")
            return os.path.isfile(dst) and os.path.getsize(dst) > 0
        except Exception:
            pass  # repli ImageMagick (HEIC/AVIF/formats que Pillow ne lit pas)

    if _have("convert"):
        try:
            # [0] = 1re page/frame (PDF multipage, GIF animé, SVG) ; limites
            # relevées + plafond ~4 Mpx par sécurité.
            subprocess.run(
                ["convert", "-limit", "memory", "2GiB", "-limit", "disk", "8GiB",
                 f"{src}[0]", "-resize", "4000000@>", dst],
                capture_output=True, check=True)
            return os.path.isfile(dst) and os.path.getsize(dst) > 0
        except subprocess.CalledProcessError:
            return False
    return False


def vision_describe(png_path):
    """Description de la scène par le modèle multimodal (llava) via Ollama.
    Renvoie '' si le modèle est indisponible (échec non bloquant)."""
    try:
        with open(png_path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        payload = {
            "model": VISION_MODEL,
            "prompt": VISION_PROMPT,
            "images": [b64],
            "stream": False,
        }
        req = urllib.request.Request(
            f"{OLLAMA_URL}/api/generate",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=300) as resp:
            return json.loads(resp.read()).get("response", "").strip()
    except (urllib.error.URLError, urllib.error.HTTPError, ValueError, OSError) as e:
        print(f"   ⚠ vision indisponible ({VISION_MODEL}) : {e}", file=sys.stderr)
        return ""


def ocr_text(png_path):
    """OCR du texte présent dans l'image, via Tesseract si dispo.
    (Pour les documents non-image, c'est Docling, côté Open WebUI, qui s'en charge.)
    Renvoie '' si Tesseract absent."""
    if not _have("tesseract"):
        return ""
    try:
        out = subprocess.run(
            ["tesseract", png_path, "stdout", "-l", "fra+eng"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        return out
    except subprocess.CalledProcessError:
        return ""


def extract(path):
    """Renvoie (texte_indexable, png_temporaire_ou_None).
    Le PNG temporaire est à supprimer par l'appelant après usage."""
    base = os.path.basename(path)
    tmp_png = os.path.join(tempfile.gettempdir(), f"rag-img-{os.getpid()}-{base}.png")

    if not to_png(path, tmp_png):
        raise RuntimeError(
            f"conversion impossible (format non géré ou delegate manquant) : {base}\n"
            f"      HEIC → 'sudo apt install libheif-examples imagemagick-heic' ; "
            f"SVG → 'sudo apt install librsvg2-bin' ; RAW → dcraw (présent)."
        )

    ocr = ocr_text(tmp_png)
    desc = vision_describe(tmp_png)

    parts = [f"# Image : {base}"]
    if desc:
        parts.append(f"## Description visuelle\n{desc}")
    if ocr:
        parts.append(f"## Texte reconnu (OCR)\n{ocr}")
    if not desc and not ocr:
        parts.append("(aucun contenu reconnu : ni description vision, ni texte OCR)")
    return "\n\n".join(parts), tmp_png


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: image_extract.py <image>", file=sys.stderr)
        sys.exit(1)
    text, tmp = extract(sys.argv[1])
    if tmp and os.path.isfile(tmp):
        os.remove(tmp)
    print(text)
