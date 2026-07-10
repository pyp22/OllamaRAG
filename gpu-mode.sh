#!/usr/bin/env bash
# Bascule du profil VRAM de la RTX 3080 (10 Go) entre les deux phases du RAG.
#
# Budget VRAM de la 3080 (10 Go), répartition observée :
#   - bureau graphique (Xorg + gnome + navigateur)  : ~1,9 Go (conservé)
#   - Open WebUI / reranker bge-reranker-v2-m3       : ~2,4 Go (utile au RAG)
#   - Docling / EasyOCR                              : ~2,4 Go (import seulement)
#   - qwen2.5:7b-rag (génération)                    : ~5,0 Go
# Tout ensemble dépasse 10 Go → OOM ou offload CPU. Mais Docling ne sert QU'À
# L'IMPORT, jamais pendant une requête RAG, et la génération n'a pas lieu pendant
# l'import. On bascule donc Docling selon la phase pour rendre ses ~2,4 Go à la
# génération, qui tourne alors full-GPU (offload 29/29, ~120 tok/s, GPU à 90 %+).
#
#   rag     : Docling arrêté → VRAM libérée pour la génération (mode par défaut,
#             requêtes en langage naturel).
#   import  : Docling démarré (OCR GPU rapide) → on indexe le corpus, on
#             n'interroge pas en parallèle.
#   status  : état GPU + conteneurs.
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-06-24
# Licence : CC BY-NC-SA 4.0, https://creativecommons.org/licenses/by-nc-sa/4.0/
set -euo pipefail

cd "$(dirname "$0")"

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then DOCKER="sudo docker"; fi

vram() {
  nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader 2>/dev/null \
    | sed 's/^/   VRAM (utilisée, libre) : /'
}

case "${1:-status}" in
  rag)
    echo "==> Mode RAG : libération de la VRAM pour la génération"
    $DOCKER stop docling >/dev/null 2>&1 || true
    # Décharge tout modèle resté chaud pour repartir sur une VRAM propre.
    curl -s http://localhost:11434/api/generate -d '{"model":"qwen2.5:7b","keep_alive":0}' >/dev/null 2>&1 || true
    sleep 2
    echo "   Docling arrêté. La RTX 3080 est dédiée à qwen2.5:7b."
    vram
    ;;
  import)
    echo "==> Mode IMPORT : Docling sur GPU pour l'OCR des scans"
    $DOCKER start docling >/dev/null 2>&1 || $DOCKER compose up -d docling >/dev/null
    sleep 3
    echo "   Docling démarré (OCR EasyOCR GPU). Ne pas interroger le RAG pendant l'import."
    vram
    ;;
  status)
    echo "==> État de la stack"
    $DOCKER ps --filter name=ollama --filter name=open-webui --filter name=docling \
      --format '   {{.Names}}\t{{.Status}}' 2>/dev/null
    vram
    echo "   Processus GPU :"
    nvidia-smi --query-compute-apps=pid,used_memory,process_name --format=csv,noheader 2>/dev/null \
      | sed 's/^/     /'
    ;;
  *)
    echo "Usage : $0 [rag|import|status]" >&2
    exit 1
    ;;
esac
