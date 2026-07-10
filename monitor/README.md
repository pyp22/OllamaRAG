# monitor · dashboard temps réel des ressources

Sous-projet web **local** et **sans dépendance** (Python 3 stdlib uniquement)
qui affiche en temps réel l'utilisation des ressources de la machine hôte et
des conteneurs de la stack `ollamarag`.

Inspiré de `../gpu-cpu-bar.sh` (mêmes sources : `nvidia-smi`, `/proc`, `free`),
mais en version web rafraîchie automatiquement.

## Affichage

- **Histogrammes** GPU (calcul), VRAM, CPU (calcul), RAM, couleurs
  vert / jaune / rouge (< 70 / < 90 / ≥ 90 %), comme `gpu-cpu-bar.sh`.
- **Conteneurs** `ollama`, `open-webui`, `docling` : état (actif/arrêté) +
  conso CPU/MEM (`docker stats`).
- **En-tête** : nom du GPU, température, puissance, nombre de threads CPU.

Le tout se rafraîchit toutes les 2 s côté navigateur (`fetch /api/metrics`).

Deux façons de le lancer : **le même `server.py`** tourne dans les deux cas.

### 1. Lanceur local (hors Docker)

```bash
./monitor.sh                   # http://<ip-hote>:8770, OUVERT AU LAN (0.0.0.0)
./monitor.sh --port 9000       # autre port
./monitor.sh --host 127.0.0.1  # restreindre à la machine locale
./monitor.sh status            # état du serveur
./monitor.sh stop              # arrêt
```

Ou directement, au premier plan (Ctrl-C pour quitter) :

```bash
python3 server.py --host 0.0.0.0 --port 8770
```

Dans ce mode, l'état des conteneurs est lu via le binaire `docker`
(ou `sudo docker`) ; les métriques GPU via `nvidia-smi`.

### 2. Service Docker (avec la stack)

Le service `monitor` est dans le `docker-compose.yml`, mais sous le **profil
`monitoring`** : il ne démarre donc PAS avec un simple `docker compose up -d`
(réservé à `ollama`/`open-webui`/`docling`). Pour l'inclure :

```bash
docker compose --profile monitoring up -d          # toute la stack + monitor
docker compose --profile monitoring up -d monitor  # le seul monitor
docker compose --profile monitoring build monitor  # (re)construire l'image
docker compose stop monitor                         # arrêter
```

En conteneur, l'état des conteneurs est lu via l'**API Docker** (socket
`/var/run/docker.sock` monté en lecture seule), pas besoin du binaire `docker`
dans l'image. Le GPU reste lu via `nvidia-smi` (base CUDA + runtime NVIDIA).
Exposé sur `0.0.0.0:8770` (LAN) par défaut, comme Ollama et Open WebUI (cf. le
mapping de ports du compose).

## Prérequis

- `python3` (≥ 3.7, stdlib seule, aucun `pip install`).
- `nvidia-smi` pour les métriques GPU (sinon GPU/VRAM affichés « n/a »).
- `docker` (ou `sudo docker`) pour l'état des conteneurs (optionnel).

## Endpoints

| Route           | Contenu                                        |
|-----------------|------------------------------------------------|
| `GET /`         | Dashboard HTML                                 |
| `GET /api/metrics` | Instantané JSON (GPU, CPU, RAM, conteneurs) |

## Sécurité

⚠ Par défaut, le dashboard est **ouvert au réseau local** (`0.0.0.0`), pour
rester cohérent avec Ollama (11434) et Open WebUI (3001). L'endpoint n'a **ni
authentification ni HTTPS** : à réserver à un LAN de confiance. Il expose des
métriques système et l'état des conteneurs, rien de sensible en écriture.

Pour restreindre à la machine locale :

- lanceur : `./monitor.sh --host 127.0.0.1` (ou `MONITOR_HOST=127.0.0.1`) ;
- compose : préfixer le mapping par `127.0.0.1:` → `"127.0.0.1:8770:8770"`.
