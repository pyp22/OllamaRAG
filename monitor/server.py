#!/usr/bin/env python3
# Serveur de monitoring temps réel des ressources système (GPU + CPU + RAM +
# conteneurs de la stack ollamarag). Zéro dépendance : uniquement la stdlib
# Python 3 + nvidia-smi / free / /proc (mêmes sources que gpu-cpu-bar.sh).
#
# - GET /            → dashboard HTML (histogrammes temps réel, style gpu-cpu-bar)
# - GET /api/metrics → instantané JSON des ressources
#
# Usage : ./server.py [--host H] [--port P]   (défaut : 127.0.0.1:8770)
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-07-01
# Licence : CC BY-NC-SA 4.0, https://creativecommons.org/licenses/by-nc-sa/4.0/
import argparse
import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")

# Conteneurs de la stack surveillés (mêmes noms que docker-compose.yml).
STACK_CONTAINERS = ["ollama", "open-webui", "docling"]


def _run(cmd, timeout=5):
    """Exécute une commande, renvoie stdout (str) ou "" en cas d'échec."""
    try:
        out = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
        return out.stdout if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


# docker ou sudo docker (comme les scripts *.sh de la stack).
_DOCKER = None


def docker_cmd():
    global _DOCKER
    if _DOCKER is not None:
        return _DOCKER
    if not shutil.which("docker"):
        _DOCKER = []
        return _DOCKER
    # Accès sans sudo ?
    probe = subprocess.run(
        ["docker", "info"], capture_output=True, timeout=5, check=False
    )
    _DOCKER = ["docker"] if probe.returncode == 0 else ["sudo", "docker"]
    return _DOCKER


def read_gpu():
    """Utilisation GPU via nvidia-smi. None si absent."""
    if not shutil.which("nvidia-smi"):
        return None
    out = _run([
        "nvidia-smi",
        "--query-gpu=name,utilization.gpu,memory.used,memory.total,"
        "temperature.gpu,power.draw,power.limit",
        "--format=csv,noheader,nounits",
    ])
    if not out.strip():
        return None
    parts = [p.strip() for p in out.strip().splitlines()[0].split(",")]
    try:
        name, util, mem_used, mem_total, temp, pdraw, plimit = parts
        mem_used = float(mem_used)
        mem_total = float(mem_total)
        return {
            "name": name,
            "util": int(float(util)),
            "vram_pct": int(mem_used * 100 / mem_total) if mem_total else 0,
            "mem_used_mb": int(mem_used),
            "mem_total_mb": int(mem_total),
            "temp": int(float(temp)),
            "power": round(float(pdraw)),
            "power_limit": round(float(plimit)),
        }
    except (ValueError, IndexError):
        return None


# Snapshot précédent des compteurs CPU (/proc/stat) pour un delta correct.
_prev_cpu = None


def read_cpu():
    """% d'occupation CPU calculé sur le delta de /proc/stat (non bloquant)."""
    global _prev_cpu
    with open("/proc/stat") as f:
        fields = f.readline().split()
    vals = list(map(int, fields[1:8]))  # user nice system idle iowait irq softirq
    idle = vals[3] + vals[4]
    total = sum(vals)
    pct = 0
    if _prev_cpu is not None:
        d_total = total - _prev_cpu[0]
        d_idle = idle - _prev_cpu[1]
        if d_total > 0:
            pct = round((d_total - d_idle) * 100 / d_total)
    _prev_cpu = (total, idle)
    with open("/proc/loadavg") as f:
        load1 = f.read().split()[0]
    return {"pct": max(0, min(100, pct)), "load1": load1, "cores": os.cpu_count()}


def read_ram():
    """% RAM utilisée via /proc/meminfo (MemTotal - MemAvailable)."""
    info = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, _, v = line.partition(":")
            info[k] = int(v.strip().split()[0])  # kB
    total = info.get("MemTotal", 0)
    avail = info.get("MemAvailable", 0)
    used = total - avail
    return {
        "pct": int(used * 100 / total) if total else 0,
        "used_mb": used // 1024,
        "total_mb": total // 1024,
    }


# Socket de l'API Docker (monté dans le conteneur ; présent aussi sur l'hôte).
DOCKER_SOCK = os.environ.get("DOCKER_SOCKET", "/var/run/docker.sock")


class _UnixHTTPConnection(http.client.HTTPConnection):
    """HTTPConnection sur socket Unix, parle à l'API Docker sans dépendance."""

    def __init__(self, sock_path, timeout=5):
        super().__init__("localhost", timeout=timeout)
        self._sock_path = sock_path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self._sock_path)
        self.sock = s


def _docker_api(path):
    """GET sur l'API Docker via le socket Unix. Renvoie l'objet JSON ou None."""
    try:
        conn = _UnixHTTPConnection(DOCKER_SOCK, timeout=8)
        conn.request("GET", path)
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        if resp.status != 200:
            return None
        return json.loads(data)
    except (OSError, ValueError, http.client.HTTPException):
        return None


def _empty_containers():
    return {c: {"running": False, "cpu": None, "mem": None} for c in STACK_CONTAINERS}


def read_containers():
    """État + conso (CPU/MEM) des conteneurs de la stack.

    Deux backends, essayés dans l'ordre :
      1. API Docker via socket Unix (mode conteneur : /var/run/docker.sock monté,
         pas besoin du binaire docker) ;
      2. CLI `docker`/`sudo docker` (mode lanceur local).
    """
    if os.path.exists(DOCKER_SOCK):
        via_api = _read_containers_api()
        if via_api is not None:
            return via_api
    return _read_containers_cli()


def _read_containers_api():
    """Lit l'état + les stats via l'API Docker (socket). None si indisponible."""
    result = _empty_containers()
    running = set()
    for name in STACK_CONTAINERS:
        # Filtre par nom exact ; inspect léger pour l'état.
        info = _docker_api(f"/containers/{name}/json")
        if not info:
            continue
        if info.get("State", {}).get("Running"):
            running.add(name)
            result[name]["running"] = True
            st = _docker_api(f"/containers/{name}/stats?stream=false")
            if st:
                cpu, mem, usage = _stats_from_api(st)
                result[name].update(cpu=cpu, mem=mem, mem_usage=usage)
    # Aucun conteneur trouvé du tout → l'API ne répond probablement pas : None
    # pour laisser le backend CLI tenter sa chance.
    if not running and all(
        _docker_api(f"/containers/{c}/json") is None for c in STACK_CONTAINERS
    ):
        return None
    return result


def _stats_from_api(st):
    """Calcule (cpu%, mem%, mem_usage lisible) depuis un objet stats Docker."""
    cpu = mem = None
    usage = None
    try:
        cs = st["cpu_stats"]
        ps = st["precpu_stats"]
        cpu_delta = cs["cpu_usage"]["total_usage"] - ps["cpu_usage"]["total_usage"]
        sys_delta = cs.get("system_cpu_usage", 0) - ps.get("system_cpu_usage", 0)
        ncpu = cs.get("online_cpus") or len(
            cs["cpu_usage"].get("percpu_usage") or [1]
        )
        if sys_delta > 0 and cpu_delta > 0:
            cpu = round(cpu_delta / sys_delta * ncpu * 100)
    except (KeyError, TypeError, ZeroDivisionError):
        pass
    try:
        ms = st["memory_stats"]
        used = ms["usage"] - ms.get("stats", {}).get("cache", 0)
        limit = ms["limit"]
        if limit:
            mem = round(used * 100 / limit)
        usage = _human_bytes(used)
    except (KeyError, TypeError, ZeroDivisionError):
        pass
    return cpu, mem, usage


def _human_bytes(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024:
            return f"{n:.1f}{unit}" if unit != "B" else f"{int(n)}B"
        n /= 1024
    return f"{n:.1f}PiB"


def _read_containers_cli():
    """État + conso via le binaire docker/sudo docker (mode local)."""
    dk = docker_cmd()
    result = _empty_containers()
    if not dk:
        return result
    # Liste des conteneurs en cours (parmi ceux qui nous intéressent).
    running = _run(dk + ["ps", "--format", "{{.Names}}"]).split()
    # docker stats --no-stream : un passage, sans bloquer.
    stats = _run(
        dk + ["stats", "--no-stream", "--format",
              "{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}|{{.MemUsage}}"],
        timeout=8,
    )
    parsed = {}
    for line in stats.strip().splitlines():
        f = line.split("|")
        if len(f) >= 4:
            parsed[f[0]] = f
    for name in STACK_CONTAINERS:
        info = result[name]
        info["running"] = name in running
        row = parsed.get(name)
        if row:
            info["cpu"] = _pct(row[1])
            info["mem"] = _pct(row[2])
            info["mem_usage"] = row[3].split("/")[0].strip()
    return result


def _pct(s):
    """Convertit "12.3%" → 12 (int), None si non parsable."""
    m = re.search(r"([\d.]+)", s)
    return round(float(m.group(1))) if m else None


def collect():
    return {
        "ts": time.time(),
        "time": time.strftime("%H:%M:%S"),
        "gpu": read_gpu(),
        "cpu": read_cpu(),
        "ram": read_ram(),
        "containers": read_containers(),
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # silencieux

    def _send(self, code, body, ctype):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _file(self, path, ctype):
        try:
            with open(path, "rb") as f:
                self._send(200, f.read(), ctype)
        except OSError:
            self._send(404, "not found", "text/plain")

    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            self._file(os.path.join(STATIC, "index.html"), "text/html; charset=utf-8")
        elif self.path == "/app.js":
            self._file(os.path.join(STATIC, "app.js"), "application/javascript")
        elif self.path == "/api/metrics":
            try:
                self._send(200, json.dumps(collect()), "application/json")
            except Exception as e:  # noqa: BLE001 - on renvoie l'erreur au client
                self._send(500, json.dumps({"error": str(e)}), "application/json")
        else:
            self._send(404, "not found", "text/plain")


def main():
    ap = argparse.ArgumentParser(description="Monitoring temps réel ollamarag")
    ap.add_argument("--host", default=os.environ.get("MONITOR_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("MONITOR_PORT", "8770")))
    args = ap.parse_args()

    read_cpu()  # amorce le delta CPU pour que la 1re requête soit correcte

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Monitoring ollamarag : http://{args.host}:{args.port}")
    print("Ctrl-C pour arrêter.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nArrêt.")
        srv.shutdown()


if __name__ == "__main__":
    main()
