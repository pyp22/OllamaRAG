# Image du dashboard de monitoring (service compose « monitor »).
# Zéro dépendance applicative : Python 3 stdlib seule. On part d'une base CUDA
# runtime pour disposer de nvidia-smi dans le conteneur (métriques GPU), comme
# les autres services de la stack qui exploitent la RTX 3080.
FROM nvidia/cuda:12.6.0-base-ubuntu22.04

# Python 3 (stdlib) : rien d'autre à installer. nvidia-smi vient de la base CUDA
# + du runtime NVIDIA fourni par l'hôte au lancement.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY server.py ./
COPY static ./static

# Écoute sur toutes les interfaces DANS le conteneur ; l'exposition réelle est
# contrôlée par le mapping de ports du compose (127.0.0.1:8770 par défaut).
ENV MONITOR_HOST=0.0.0.0 \
    MONITOR_PORT=8770 \
    DOCKER_SOCKET=/var/run/docker.sock

EXPOSE 8770
CMD ["python3", "server.py"]
