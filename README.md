# OllamaRAG, RAG local avec Ollama + Open WebUI

Indexer ses documents et les interroger en langage naturel, **100 % en local**,
sur une machine RTX 3080 (10 Go VRAM).

L'installation est **dissociée en briques**. Ollama est la brique de base
(moteur LLM autonome), Open WebUI est l'**interface unique** d'administration du
corpus et d'interrogation du RAG.

| Brique | Dossier | Rôle | Statut |
|--------|---------|------|--------|
| **Ollama** | racine (ici) | moteur LLM (génération + embeddings) sur GPU. Brique de base, autonome. | code en place |
| **Stack RAG** | racine (ici) | Open WebUI + Docling. Administration du corpus et interrogation en langage naturel. S'appuie sur l'Ollama de la racine. | code en place |

On installe d'abord Ollama, puis la stack RAG (Open WebUI + Docling) par-dessus.

## Stack

| Composant     | Rôle                                                       | Port  |
|---------------|------------------------------------------------------------|-------|
| Ollama        | LLM génération (`qwen2.5:7b-rag`) + embeddings (`bge-m3`)   | 11434 |
| Open WebUI    | **Interface unique** : admin corpus + interrogation RAG en langage naturel | 3001  |
| Docling       | Extraction de texte + OCR (PDF scannés), Tesseract, GPU/CPU selon `hw-balance.sh` | 5001  |
| Monitor *(optionnel)* | Dashboard web temps réel GPU/CPU/RAM + état conteneurs (profil `monitoring`) | 8770  |

**Open WebUI et Docling tournent en conteneurs Docker.** Ollama accède à la
RTX 3080 via le NVIDIA Container Toolkit (installé par `install-ollama.sh`). Les
conteneurs atteignent Ollama via `host.docker.internal:11434` (port de l'hôte).

### Architecture

```
Navigateur → Open WebUI (:3001) ── moteur RAG (corpus + retrieval + chat)
                                          │
                Ollama (:11434, racine) ◀─┤
                Docling (:5001) ◀─────────┘
```

L'utilisateur parle directement à **Open WebUI** : il y administre son corpus et
y pose ses questions en langage naturel. Open WebUI s'appuie sur l'Ollama de la
racine pour la génération et les embeddings, et sur Docling pour l'extraction et
l'OCR des documents.

## Installation

### 1. Ollama (brique de base)

```bash
./install-ollama.sh
```

Installe Docker si besoin, le NVIDIA Container Toolkit, démarre Ollama et
télécharge les modèles (`qwen2.5:7b`, `bge-m3`) et crée la variante plein-GPU
`qwen2.5:7b-rag`. Après la 1re install de
Docker, se reconnecter (ou `newgrp docker`) pour utiliser `docker` sans `sudo`.

Gérer ensuite Ollama :

```bash
./start-ollama.sh start      # démarrer (nettoie aussi les conteneurs orphelins)
./start-ollama.sh stop       # arrêter (modèles conservés)
./start-ollama.sh restart    # relancer (reprend une modif de docker-compose.yml)
./start-ollama.sh logs       # suivre les logs
./start-ollama.sh status     # état du conteneur
```

`start-ollama.sh start` déclenche aussi `hw-balance.sh query` (répartition VRAM,
voir plus bas) une fois la stack levée.

Pour piloter un seul service de la stack RAG (plutôt que tout `docker compose`),
trois scripts équivalents existent : [`ollama.sh`](ollama.sh),
[`docling.sh`](docling.sh), [`open-webui.sh`](open-webui.sh) : même interface
(`start|stop|restart|logs|status`), un seul service ciblé chacun.

### 2. Stack RAG : Open WebUI + Docling (par-dessus Ollama)

Ollama doit tourner. Les conteneurs Open WebUI et Docling sont définis dans
[`docker-compose.yml`](docker-compose.yml) (nom de projet fixe : `ollamarag-wiki`).
Depuis la racine `/mnt/DEV/OllamaRAG/` :

```bash
docker compose up -d        # démarrer Open WebUI + Docling
docker compose down         # arrêter (volumes conservés, Ollama reste actif)
docker compose logs -f      # suivre les logs (ex. : docker compose logs -f open-webui)
docker compose ps           # état des conteneurs
```

## Configuration (une fois)

Tout se configure dans Open WebUI (<http://localhost:3001>) :

1. **Créer le 1er compte** (= admin). Les comptes suivants arrivent en *pending*
   (à valider dans *Panneau admin → Utilisateurs*).
2. Vérifier *Paramètres → Documents* : embedding = **Ollama / bge-m3**,
   extraction = **Docling**.
3. **Indexer le corpus** dans *Espace de travail → Connaissances* (corpus
   partagé et persistant).
4. *Paramètres → Compte → Clés API* → **créer une clé**, puis la coller dans
   [`.env`](.env) (racine) sous `OPENWEBUI_API_KEY=` pour l'import par script.

## Alimenter le corpus (Word, Excel, PDF, TXT…)

> **On n'« entraîne » pas le modèle.** En RAG, `qwen2.5:7b-rag` reste inchangé. Les
> documents sont *extraits* (Docling, OCR des PDF scannés), *découpés*,
> *vectorisés* (`bge-m3`) et *stockés* dans une base. Au moment d'une question,
> les passages pertinents sont récupérés et injectés dans le prompt. Ajouter ou
> retirer un document est pris en compte immédiatement, sans ré-entraînement.

Les documents vivent dans Open WebUI (volume Docker `open-webui`), pas dans un
dossier sur le disque. Deux façons de les y mettre :

### A. Glisser-déposer dans l'UI (simple)

1. Open WebUI (<http://localhost:3001>) → *Espace de travail → Connaissances*
2. Créer/ouvrir une base (ex. **Connaissances**)
3. **Téléverser** les fichiers (`.pdf`, `.docx`, `.xlsx`, `.txt`, `.md`, …).
   L'extraction (Docling) et la vectorisation (`bge-m3`) sont automatiques.

### B. Dossier hôte + import par script (gros volumes)

Déposer les fichiers dans [`corpus/`](corpus/) (à la racine du projet, ignoré par
git), puis :

```bash
export OPENWEBUI_API_KEY=sk-...        # clé créée dans Open WebUI
./import-corpus.py                     # corpus/ → base « Connaissances »
```

(Le script est à la racine du projet. La clé peut aussi rester dans `.env` à la
racine, lu automatiquement.)

[`import-corpus.py`](import-corpus.py) crée la base au besoin, téléverse via
l'API et rattache chaque fichier à la collection. Il est **idempotent** (suit les
fichiers déjà importés via leur empreinte, `--force` pour tout réimporter).
Options : `--dir`, `--collection`, `--url`, `--force`.

Formats gérés : PDF (texte et scannés), Word `.doc/.docx`, Excel `.xls/.xlsx`,
PowerPoint `.ppt/.pptx`, TXT, Markdown, CSV, HTML, JSON, XML.

### Reconnaissance du contenu des images (tous formats)

`import-corpus.py` reconnaît aussi le **contenu des images**, à deux niveaux,
concaténés en un texte indexable :

1. **OCR** : le texte présent dans l'image (Tesseract FR+EN, sur CPU, module hôte
   indépendant de Docling).
2. **Vision** : une description de la scène par un modèle multimodal
   (`llava:7b` dans Ollama, var `VISION_MODEL`).

Tout format est d'abord normalisé en PNG, donc pris en charge largement :
JPG, PNG, TIFF, BMP, WEBP, GIF, **HEIC/HEIF/AVIF**, **SVG**, et **RAW** photo
(CR2, CR3, NEF, ARW, DNG, RAF, RW2, ORF, PEF, SRW). L'image n'est pas indexée
telle quelle : c'est son contenu reconnu (description + OCR) qui rejoint la base,
sous le nom `<image>.txt`.

Dépendances hôte (le module `image_extract.py` tourne sur l'hôte) :

```bash
sudo apt install imagemagick dcraw libheif-examples librsvg2-bin \
                 tesseract-ocr tesseract-ocr-fra tesseract-ocr-eng
docker exec ollama ollama pull llava:7b      # modèle vision (~5 Go VRAM)
```

Tester la reconnaissance d'une image seule :

```bash
./image_extract.py photo.heic
```

Un format non convertible (delegate manquant) est **signalé**, jamais ignoré en
silence. Si `llava` est absent, l'OCR fonctionne quand même (la description vision
est simplement omise).

### PDF scannés : OCR forcé via Docling (Tesseract)

Beaucoup de documents anciens sont des **scans sans couche texte** : Open WebUI
les reçoit vides (« content is empty ») car il n'OCR pas par défaut. Le pipeline
gère ce cas automatiquement :

1. `import-corpus.py` téléverse le PDF normalement (rapide s'il a déjà du texte),
2. si le contenu revient **vide**, repli automatique vers
   [`docling_ocr.py`](docling_ocr.py) : **OCR forcé** (`do_ocr+force_ocr`)
   via Docling,
3. le texte océrisé est alors indexé sous `<doc>.ocr.txt`.

Moteur OCR = **Tesseract** (`ocr_preset=tesseract`, langue `fra`) : sur les scans
d'archives anciens du corpus, Tesseract bat nettement EasyOCR (sépare mieux les
mots, gère les accents, confond moins les lettres). Le pack langue français n'est
pas dans l'image Docling (`eng`+`osd` seuls) → monté en lecture seule depuis
[`docling/tessdata/fra.traineddata`](docling/tessdata/) dans `docker-compose.yml`.

⚠️ Côté API Docling, le paramètre historique `ocr_engine` est **déprécié** (il
retombe silencieusement sur `auto` → RapidOCR) : c'est **`ocr_preset`** qu'il
faut envoyer, avec `ocr_lang` comme **liste** (pas une simple chaîne). Piloté par
`DOCLING_PIPELINE_OCR_ENGINE` / `DOCLING_PIPELINE_OCR_LANG` dans `.env` /
`docker-compose.yml`, lu par `docling_ocr.py`.

Docling utilise le GPU ou le CPU selon `DOCLING_DEVICE`, piloté dynamiquement par
[`hw-balance.sh`](hw-balance.sh) (voir « Exploiter le maximum du GPU » plus bas) :
CPU pendant l'interrogation (VRAM rendue à Ollama), GPU pendant l'import si la
VRAM le permet.

⚠️ **Concurrence des OCR** : au-delà d'un certain nombre d'appels simultanés,
Docling sature (timeouts HTTP 504). D'où `DOCLING_OCR_CONCURRENCY=2`
et `DOCLING_OCR_TIMEOUT` (s) dans `.env`. Les uploads légers, eux, restent
parallèles (`--jobs`). Pour un corpus avec de **gros scans lourds** (plans
50+ Mo), traiter en série : `./import-corpus.py --jobs 1`.

Pour de l'OCR **autonome, hors import** (fichiers ou répertoires, sans passer par
Open WebUI), voir [`ocr.sh`](ocr.sh) : moteur Tesseract CPU par défaut (mêmes
raisons qu'au-dessus), avec la file GPU/Docling disponible en option
(`--gpu-jobs N` / `--only gpu`) pour paralléliser CPU et GPU en même temps.

Certains fichiers restent légitimement non indexés : **plans techniques** (traits,
cotes, aucun texte), l'OCR n'a rien à en extraire. Pour les décrire malgré tout,
on pourrait les passer au pipeline vision (`llava`), à activer si besoin.

### Où vivent les données indexées (confidentialité)

Tout reste **100 % local**, dans des **volumes Docker** (jamais dans le dépôt git,
jamais sur GitHub). Les volumes ont un **nom fixe** (`ollamarag_*`), indépendant
du dossier d'exécution :

| Volume | Chemin hôte (`/var/lib/docker/volumes/…/_data`) | Contenu |
|--------|--------------------------------------------------|---------|
| `ollamarag_open-webui` | `uploads/` | fichiers d'origine téléversés |
| | `vector_db/chroma.sqlite3` | base vectorielle (embeddings + passages) |
| | `webui.db` | métadonnées : bases « Connaissances », comptes, clés |
| `ollamarag_ollama` | - | modèle LLM + embeddings |

> **Hors-git par nature** : ces volumes sont sous `/var/lib/docker/`, en dehors de
> `/mnt/DEV/OllamaRAG`, donc git ne les voit pas. Le `.gitignore` bloque **en plus**
> tout export/sauvegarde de volume, base vectorielle ou `uploads/` qui serait
> déposé par erreur dans le dépôt. Les données indexées ne partent jamais sur GitHub.

### Sauvegarde / restauration du corpus indexé

Comme le corpus indexé n'est PAS dans le dossier projet, sauvegarder le dossier ne
suffit pas : il faut sauvegarder le volume Docker (le `.tgz` produit est ignoré par
git).

```bash
# Sauvegarde (corpus indexé + métadonnées)
docker run --rm -v ollamarag_open-webui:/data -v "$PWD":/backup alpine \
  tar czf /backup/open-webui-backup.tgz -C /data .

# Restauration
docker run --rm -v ollamarag_open-webui:/data -v "$PWD":/backup alpine \
  tar xzf /backup/open-webui-backup.tgz -C /data
```

## Utilisation

Tout se passe dans Open WebUI (<http://localhost:3001>). On y administre le corpus
dans *Espace de travail → Connaissances* (téléversement, mise à jour, suppression
des documents), puis on interroge en langage naturel directement dans l'interface
de chat, en sélectionnant la base de connaissances comme source. Les réponses
citent leurs sources.

Pour de bonnes réponses, poser des questions **précises** (un nom propre, un
document, un sujet pointu). Une question trop vague ne récupère que quelques
passages et donne une réponse floue.

## Corriger les réponses (erreurs d'OCR)

Beaucoup de documents sont des scans anciens. Quand l'OCR a mal lu un passage, le
RAG peut répondre faux. On corrige **au fil de l'eau, au cas par cas**, sans
toucher au scan d'origine. La correction ajoute le bon fait dans la base
**« Connaissances »** elle-même, du texte propre et ciblé qui prime sur l'OCR
bruité au moment du retrieval. Une seule base à interroger.

**Seuls des modérateurs identifiés peuvent corriger.** Le contrôle d'accès repose
sur les rôles et groupes natifs d'Open WebUI (groupe **« Modérateurs »**), la
gouvernance sur le groupe Admins. Procédure complète dans
[`MODERATION.md`](MODERATION.md).

La voie normale pour un modérateur est l'**interface Open WebUI**, avec son propre
compte : *Espace de travail → Connaissances*, ajout d'un document.

Pour des ajouts en lot, l'admin dispose de [`corriger.py`](corriger.py) (il
emploie la clé admin, donc réservé aux admins, et exige d'identifier l'opérateur) :

```bash
export MODERATEUR="Prénom Nom"          # obligatoire : trace l'auteur
./corriger.py "date de l'évènement" \
  --texte "L'évènement a eu lieu le 12 mars 1963." \
  --source "rapport 1963.pdf"          # source concernée, optionnel

./corriger.py "nom du responsable"      # sans --texte : saisie au clavier
./corriger.py --liste                   # voir les corrections (lecture seule)
```

La correction est indexée immédiatement et estampillée au nom du modérateur. Elle
est prise en compte dès la question suivante, dans la base « Connaissances ».

## Renommer les collections (admin)

Renommer une base de connaissances est une opération réservée aux **admins**.
Deux voies :

- **Interface Open WebUI** : *Espace de travail → Connaissances*, éditer le nom de
  la base.
- **Ligne de commande** avec [`gerer-collections.py`](gerer-collections.py) (clé
  admin, exige d'identifier l'opérateur) :

```bash
./gerer-collections.py --liste                        # id + nom des collections

export ADMIN="Prénom Nom"                              # obligatoire pour renommer
./gerer-collections.py --renommer <id> "Nouveau nom"
```

Par défaut, `import-corpus.py` et `corriger.py` ciblent la base par son **nom**
(`RAG_COLLECTION_NAME` dans `.env`, ou l'option `--collection`). Ce ciblage
**survit à une recréation** de la base côté Open WebUI (l'id change alors, mais
pas le nom). En contrepartie, **en cas de renommage de la base, `RAG_COLLECTION_NAME`
doit être mis à jour** en conséquence (sinon les scripts créeraient une base
vide au nom attendu).

Pour figer le ciblage sur un **id** (insensible au renommage, mais qui casse à la
recréation), renseigner `RAG_COLLECTION_ID` dans `.env` : il est alors prioritaire
sur le nom. L'id se retrouve avec `./gerer-collections.py --liste`.

## Choix techniques

- **Génératif `qwen2.5:7b-rag`** : variante de `qwen2.5:7b` (~5 Go VRAM, Q4_K_M)
  avec `num_gpu=99` et `num_ctx=8192` figés (Modelfile, voir plus bas). Tient
  ENTIÈREMENT sur la RTX 3080 (offload 29/29 couches), GPU à 90 %+, **~111 tok/s**.
  Le modèle est fixé par `RAG_MODEL` dans `.env` (racine).
  - **Pourquoi pas le 14b ?** `qwen2.5:14b` (~9 Go) ne tient pas : le bureau
    graphique (~1,9 Go) et le reranker d'Open WebUI (~0,8 Go) occupent déjà la
    carte. Ollama débordait alors sur le CPU (17/49 couches GPU) et tombait à
    **~7 tok/s**, soit ~16x plus lent. Le 7B full-GPU est le bon compromis sur
    10 Go. Le 14b reste téléchargé pour comparaison ponctuelle.
- **Embedding `bge-m3`** : multilingue, excellent en français (~1,2 Go VRAM).
  Le choix de l'embedding pèse plus sur la qualité que le LLM lui-même.
- **OCR via Docling** : nécessaire pour les PDF scannés / images.

### Exploiter le maximum du GPU (RTX 3080, 10 Go)

L'objectif du projet est de tirer le meilleur de la machine, pas seulement de
« faire marcher ». Trois leviers, tous en place :

1. **Réglages Ollama** (dans `docker-compose.yml`, service `ollama`) :
   `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0` (cache contexte
   quantifié, ~2x moins de VRAM), `OLLAMA_NUM_PARALLEL` (piloté par
   `hw-balance.sh`, défaut 2), `OLLAMA_MAX_LOADED_MODELS=2`,
   `OLLAMA_KEEP_ALIVE=30m`.
2. **Modèle `qwen2.5:7b-rag`** : paramètres plein-GPU figés. Le recréer :
   ```
   docker exec -i ollama ollama create qwen2.5:7b-rag -f - <<'EOF'
   FROM qwen2.5:7b
   PARAMETER num_gpu 99
   PARAMETER num_ctx 8192
   EOF
   ```
3. **Répartition GPU/CPU [`hw-balance.sh`](hw-balance.sh)** : la RTX 3080
   (10 Go) est la ressource rare, le CPU (24 threads) et la RAM (62 Go) sont
   abondants. Docling réserverait sinon ~3,3 Go de VRAM en permanence
   (`DOCLING_DEVICE=cuda`) même sans OCR en cours, au détriment du KV cache
   d'Ollama. `hw-balance.sh` arbitre le GPU selon la charge réelle :
   - `./hw-balance.sh query` : GPU entièrement à Ollama (interrogation), Docling
     bascule sur CPU. `NUM_PARALLEL` calé sur la VRAM libre.
   - `./hw-balance.sh import` : Docling reprend le GPU si Ollama laisse assez de
     VRAM libre (seuil `DOCLING_GPU_MIN_FREE_MB`, 6 Go par défaut), sinon reste
     sur CPU.
   - `./hw-balance.sh auto` (défaut) : décide query/import selon ce qui tourne.
   - `./hw-balance.sh status` : répartition VRAM/CPU/RAM du moment.
   - Reranking Open WebUI (`bge-reranker-v2-m3`) : sur **CPU**
     (`USE_CUDA_DOCKER=false`), pour rendre sa VRAM à Ollama.

Mesurer la charge : `./gpu-cpu-bar.sh`, `./hw-stats.sh`, ou le dashboard web
[`monitor/`](monitor/) (`./monitor/monitor.sh`, <http://localhost:8770>).

## Réglages de qualité RAG (à itérer)

Dans *Paramètres → Documents* d'Open WebUI :
- **Taille de chunk / overlap** : départ 1000 / 200, à ajuster selon les docs.
- **Top K** : nombre de passages récupérés (départ 4–6).
- **Reranking** : activer un modèle de reranking améliore nettement la pertinence.

## Voir aussi

- [`discussion-rag.md`](discussion-rag.md) : cadrage initial et notes sur le RAG.

## Dépendances tierces et licences

Ce dépôt contient le **code d'assemblage** (scripts, `docker-compose.yml`,
configuration, documentation) qui orchestre plusieurs briques tierces. Ces
briques ne sont pas redistribuées dans ce dépôt : elles sont téléchargées à
l'exécution (images Docker, `ollama pull`, HuggingFace) et restent sous leur
propre licence, indépendante de celle de ce dépôt.

| Brique | Rôle | Licence |
|---|---|---|
| [Ollama](https://github.com/ollama/ollama) | Moteur LLM | MIT |
| [Open WebUI](https://github.com/open-webui/open-webui) | Interface RAG | BSD 3-Clause (+ clause anti-branding sur le nom « Open WebUI ») |
| [Docling / docling-serve](https://github.com/docling-project/docling-serve) | Extraction + OCR | MIT |
| [Qwen2.5](https://huggingface.co/Qwen/Qwen2.5-7B) (7b, 7b-rag, 14b) | LLM génératif | Apache 2.0 |
| [bge-m3](https://huggingface.co/BAAI/bge-m3) | Embedding | MIT |
| [bge-reranker-v2-m3](https://huggingface.co/BAAI/bge-reranker-v2-m3) | Reranking | Apache 2.0 |
| [llava](https://huggingface.co/liuhaotian) | Vision (description d'image) | Apache 2.0 (v1.6+) ou Llama 2 Community License (v1.5, selon le socle) |
| [Tesseract OCR](https://github.com/tesseract-ocr/tesseract) | Moteur OCR | Apache 2.0 |

**Exception** : le fichier [`docling/tessdata/fra.traineddata`](docling/tessdata/)
(pack langue français pour Tesseract) est redistribué tel quel dans ce dépôt.
Il provient du projet [tesseract-ocr/tessdata](https://github.com/tesseract-ocr/tessdata)
(licence Apache 2.0), voir [`docling/tessdata/NOTICE`](docling/tessdata/NOTICE).

## Licence

Le code de ce dépôt (scripts, configuration, documentation, hors
dépendances tierces listées ci-dessus) est distribué sous licence
**CC BY-NC-SA 4.0** (Creative Commons Attribution - Pas d'Utilisation
Commerciale - Partage dans les Mêmes Conditions). Voir le fichier
[`LICENSE`](LICENSE).
https://creativecommons.org/licenses/by-nc-sa/4.0/
