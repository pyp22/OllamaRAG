// Monitoring temps réel ollamarag, logique client.
// Interroge /api/metrics à intervalle régulier et met à jour les histogrammes.
// Palette de couleurs alignée sur gpu-cpu-bar.sh (vert <70, jaune <90, rouge).

const INTERVAL_MS = 2000; // fréquence de rafraîchissement
let failures = 0;

const $ = (id) => document.getElementById(id);

function colorFor(p) {
  if (p >= 90) return "var(--red)";
  if (p >= 70) return "var(--yel)";
  return "var(--grn)";
}

// Crée (une fois) la structure d'une barre, puis la réutilise ensuite.
function ensureBar(key, label) {
  let el = $("bar-" + key);
  if (el) return el;
  el = document.createElement("div");
  el.className = "bar";
  el.id = "bar-" + key;
  el.innerHTML = `
    <div class="label">${label}</div>
    <div class="pct" id="pct-${key}">–</div>
    <div class="track"><div class="fill" id="fill-${key}" style="height:0%"></div></div>
    <div class="det" id="det-${key}"></div>`;
  $("bars").appendChild(el);
  return el;
}

function setBar(key, label, pct, det) {
  ensureBar(key, label);
  const p = Math.max(0, Math.min(100, pct | 0));
  const col = colorFor(p);
  const fill = $("fill-" + key);
  fill.style.height = p + "%";
  fill.style.background = col;
  const pctEl = $("pct-" + key);
  pctEl.textContent = p + "%";
  pctEl.style.color = col;
  $("det-" + key).textContent = det || "";
}

function renderContainers(containers) {
  const box = $("containers");
  box.innerHTML = "";
  for (const [name, c] of Object.entries(containers)) {
    const card = document.createElement("div");
    card.className = "card";
    const dot = c.running ? '<span class="dot ok"></span>' : '<span class="dot off"></span>';
    const state = c.running ? "actif" : "arrêté";
    let metrics = `<span>état&nbsp;: <b>${state}</b></span>`;
    if (c.running && c.cpu != null) {
      metrics += `<span>CPU&nbsp;: <b>${c.cpu}%</b></span>`;
      metrics += `<span>MEM&nbsp;: <b>${c.mem ?? "?"}%</b>${c.mem_usage ? " (" + c.mem_usage + ")" : ""}</span>`;
    }
    card.innerHTML = `<div class="name">${dot}${name}</div><div class="metrics">${metrics}</div>`;
    box.appendChild(card);
  }
}

function render(m) {
  // GPU / VRAM (si présent)
  if (m.gpu) {
    setBar("gpu", "GPU", m.gpu.util, m.gpu.util + "%");
    setBar("vram", "VRAM", m.gpu.vram_pct,
           `${m.gpu.mem_used_mb} / ${m.gpu.mem_total_mb} Mo`);
  } else {
    setBar("gpu", "GPU", 0, "n/a");
    setBar("vram", "VRAM", 0, "n/a");
  }
  // CPU / RAM
  setBar("cpu", "CPU", m.cpu.pct, `charge ${m.cpu.load1} · ${m.cpu.cores} c`);
  setBar("ram", "RAM", m.ram.pct, `${m.ram.used_mb} / ${m.ram.total_mb} Mo`);

  renderContainers(m.containers);

  // En-tête
  $("clock").textContent = m.time;
  $("live-dot").className = "dot ok";
  const g = m.gpu;
  $("host").textContent = g
    ? `${g.name} · ${g.temp}°C · ${g.power}/${g.power_limit} W · ${m.cpu.cores} threads CPU`
    : `GPU non détecté · ${m.cpu.cores} threads CPU`;
  $("footer").innerHTML = `Rafraîchi toutes les ${INTERVAL_MS / 1000}s · dernière mise à jour ${m.time}`;
}

async function tick() {
  try {
    const r = await fetch("/api/metrics", { cache: "no-store" });
    if (!r.ok) throw new Error("HTTP " + r.status);
    const m = await r.json();
    if (m.error) throw new Error(m.error);
    failures = 0;
    render(m);
  } catch (e) {
    failures++;
    $("live-dot").className = failures > 1 ? "dot off" : "dot stale";
    $("footer").innerHTML =
      `<span class="err">Erreur de connexion (${failures}) : ${e.message}. Nouvelle tentative…</span>`;
  }
}

tick();
setInterval(tick, INTERVAL_MS);
