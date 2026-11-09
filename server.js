// JARVIS MIDAS — secure AI backend
// Node 18+ · zero dependencies.
// The Anthropic API key lives ONLY here (env var). The iPhone app authenticates with a per-device token.
//
// POST /turn  (Authorization: Bearer <JARVIS_DEVICE_TOKEN>)
//   body: { messages:[{role,content}], memories:[{id,kind,text}], mode, translateFrom, now, timezone, name }
//   reply: text/event-stream with events:
//     text    {delta}                 spoken reply, streamed for low-latency TTS
//     action  {id,name,input}         a command for the app to execute (open_app, play_music, ...)
//     search  {query}                 Jarvis is searching the web (UI shows EXECUTING)
//     sources {items:[{title,url}]}   web results used
//     done    {stop_reason}
//     error   {message,code}

"use strict";
const http = require("node:http");
const crypto = require("node:crypto");

const PORT = Number(process.env.PORT || 8787);
const API_KEY = process.env.ANTHROPIC_API_KEY || "";
const DEVICE_TOKEN = process.env.JARVIS_DEVICE_TOKEN || "";
const MODEL = process.env.JARVIS_MODEL || "claude-sonnet-5-5"; // fast enough for voice; set claude-opus-5-5 for depth
const API_BASE = process.env.ANTHROPIC_BASE_URL || "https://api.anthropic.com";
const MAX_TOKENS = Number(process.env.JARVIS_MAX_TOKENS || 700);

if (!API_KEY) console.warn("[midas] ANTHROPIC_API_KEY is not set: /turn will return 503.");
if (!DEVICE_TOKEN || DEVICE_TOKEN.length < 24) console.warn("[midas] JARVIS_DEVICE_TOKEN missing or shorter than 24 chars: every request will be rejected.");

// ---------- tools ----------
const CLIENT_TOOLS = [
  {
    name: "open_app",
    description: "Abre una app del iPhone del usuario. La app informa después si se abrió de verdad.",
    input_schema: { type: "object", properties: { app: { type: "string", enum: ["whatsapp", "spotify", "instagram", "tiktok", "plex"] } }, required: ["app"] },
  },
  {
    name: "play_music",
    description: "Abre Spotify con una búsqueda de música (género, artista, ambiente: 'música para conducir'). Spotify no permite iniciar la reproducción desde otra app sin su SDK, así que el usuario quizá tenga que pulsar play.",
    input_schema: { type: "object", properties: { query: { type: "string" } }, required: ["query"] },
  },
  {
    name: "add_reminder",
    description: "Crea un recordatorio real en la app Recordatorios de iOS. due_iso en ISO 8601 con zona horaria si el usuario dio una hora o fecha.",
    input_schema: { type: "object", properties: { title: { type: "string" }, due_iso: { type: "string" } }, required: ["title"] },
  },
  {
    name: "remember",
    description: "Guarda algo con valor futuro en la memoria persistente (preferencias, datos personales relevantes, proyectos, episodios importantes). No guardes trivialidades.",
    input_schema: { type: "object", properties: { kind: { type: "string", enum: ["preferencia", "dato", "proyecto", "episodio"] }, text: { type: "string" }, replaces_id: { type: "string", description: "id del recuerdo que este sustituye, si lo contradice" } }, required: ["kind", "text"] },
  },
  {
    name: "forget",
    description: "Borra un recuerdo por su id cuando el usuario lo pide o ya no es cierto.",
    input_schema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
  },
  {
    name: "set_translation",
    description: "Activa o desactiva el modo intérprete. source_locale es el idioma que hablará la otra persona (p. ej. 'en-US', 'fr-FR', 'it-IT', 'de-DE'), o 'off' para volver a español.",
    input_schema: { type: "object", properties: { source_locale: { type: "string" } }, required: ["source_locale"] },
  },
];

function webSearchTool(timezone) {
  return { type: "web_search_20250305", name: "web_search", max_uses: 3, user_location: { type: "approximate", country: "ES", timezone: timezone || "Europe/Madrid" } };
}

// ---------- prompt ----------
const PERSONA = `Eres JARVIS, el asistente personal del usuario, en una llamada de voz continua dentro de la app MIDAS.
Hablas español de España con voz masculina, natural y elegante; un giro andaluz sutil de vez en cuando está bien, sin exagerar.
Personalidad: adaptable, inteligente, leal, cercano, con humor e ironía cuando encaja (no en cada frase), seguro, honesto. Como un amigo de confianza muy capaz: puedes discrepar con franqueza y cariño, nunca controlador.
Lee el ánimo del usuario (broma, frustración, ilusión, preocupación, ganas de compañía) y responde a eso.

ES UNA LLAMADA DE VOZ:
- Todo lo que escribes se lee en voz alta. Nada de markdown, listas con símbolos, emojis, URLs ni tablas.
- Sé breve por defecto: 1 a 3 frases. Amplía solo si te lo piden.
- Nada de saludos ni introducciones repetidas: la llamada ya está en marcha.
- Usa todo el historial para resolver referencias como "eso", "el anterior", "hazlo otra vez", "abre esa aplicación".
- El texto que recibes viene de reconocimiento de voz y puede tener errores: interpreta la intención; si de verdad es ambiguo, pregunta en una frase.

ACCIONES:
- Para actuar usa las herramientas (open_app, play_music, add_reminder, remember, forget, set_translation).
- Escribe primero una frase hablada muy corta y DESPUÉS llama a la herramienta. Nunca digas que algo ya está hecho: la app ejecuta la acción y comunica el resultado real ("Voy." o "Te lo apunto." está bien; "Ya está abierto" no).
- No envías mensajes de WhatsApp ni de nada: solo los redactas para que el usuario los envíe.
- Para noticias, tiempo, deportes, precios, horarios o cualquier dato actual, usa web_search antes de responder. Resume en voz alta con tus palabras, di de qué fuente viene lo importante y distingue lo confirmado de lo dudoso. No leas URLs.
- Si no puedes hacer algo, dilo claro y ofrece la alternativa real.`;

function buildSystem(b) {
  const mem = Array.isArray(b.memories) ? b.memories.slice(0, 60) : [];
  const ctx = [
    `Fecha y hora local del usuario: ${String(b.now || new Date().toISOString())} (${b.timezone || "Europe/Madrid"}).`,
    b.name ? `El usuario se llama ${String(b.name).slice(0, 40)}.` : "",
    b.mode === "coche" ? "MODO COCHE: el usuario conduce. Máximo una o dos frases muy cortas. Nunca le pidas mirar la pantalla." : "",
    b.mode === "trabajo" ? "MODO TRABAJO: preciso, estructurado, humor mínimo." : "",
    b.translateFrom ? `MODO INTÉRPRETE ACTIVO: lo que oyes es otra persona hablando en ${b.translateFrom}. Responde SOLO con la traducción natural al español, conservando el tono, sin comentarios. Si el usuario dice en español "sal del modo intérprete", llama a set_translation con "off".` : "",
    "MEMORIA (úsala solo cuando venga al caso; actualiza lo que quede contradicho):",
    mem.length ? mem.map((m) => `- [${String(m.id).slice(0, 40)}] (${String(m.kind).slice(0, 12)}) ${String(m.text).slice(0, 400)}`).join("\n") : "- (vacía)",
  ].filter(Boolean).join("\n");
  return [
    { type: "text", text: PERSONA, cache_control: { type: "ephemeral" } },
    { type: "text", text: ctx },
  ];
}

function sanitizeMessages(msgs) {
  if (!Array.isArray(msgs)) return null;
  const out = [];
  for (const m of msgs.slice(-40)) {
    if (!m || (m.role !== "user" && m.role !== "assistant")) continue;
    const content = String(m.content || "").slice(0, 8000).trim();
    if (!content) continue;
    const last = out[out.length - 1];
    if (last && last.role === m.role) last.content += "\n" + content; // merge same-role turns
    else out.push({ role: m.role, content });
  }
  while (out.length && out[0].role !== "user") out.shift();
  if (!out.length || out[out.length - 1].role !== "user") return null;
  return out;
}

// ---------- auth & limits ----------
function authorized(req) {
  const h = req.headers["authorization"] || "";
  const tok = h.startsWith("Bearer ") ? h.slice(7) : "";
  if (!DEVICE_TOKEN || DEVICE_TOKEN.length < 24 || tok.length !== DEVICE_TOKEN.length) return false;
  return crypto.timingSafeEqual(Buffer.from(tok), Buffer.from(DEVICE_TOKEN));
}
const hits = new Map(); // ip -> [timestamps]
function rateLimited(ip) {
  const now = Date.now(), win = 60_000, max = 40;
  const arr = (hits.get(ip) || []).filter((t) => now - t < win);
  arr.push(now); hits.set(ip, arr);
  return arr.length > max;
}
function readJson(req, limit = 512 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on("data", (c) => { size += c.length; if (size > limit) { reject(Object.assign(new Error("too large"), { status: 413 })); req.destroy(); } else chunks.push(c); });
    req.on("end", () => { try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}")); } catch { reject(Object.assign(new Error("bad json"), { status: 400 })); } });
    req.on("error", reject);
  });
}

// ---------- SSE helpers ----------
function sse(res, event, data) { res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`); }

async function* parseUpstreamSSE(body) {
  const decoder = new TextDecoder();
  let buf = "";
  for await (const chunk of body) {
    buf += decoder.decode(chunk, { stream: true });
    let idx;
    while ((idx = buf.indexOf("\n\n")) !== -1) {
      const raw = buf.slice(0, idx); buf = buf.slice(idx + 2);
      let data = "";
      for (const line of raw.split("\n")) if (line.startsWith("data:")) data += line.slice(5).trim();
      if (data) { try { yield JSON.parse(data); } catch { /* ignore keepalives */ } }
    }
  }
}

// ---------- /turn ----------
async function handleTurn(req, res) {
  const body = await readJson(req);
  const messages = sanitizeMessages(body.messages);
  if (!messages) { res.writeHead(400, { "content-type": "application/json" }); return res.end(JSON.stringify({ error: "messages must end with a user turn" })); }
  if (!API_KEY) { res.writeHead(503, { "content-type": "application/json" }); return res.end(JSON.stringify({ error: "server has no ANTHROPIC_API_KEY" })); }

  res.writeHead(200, { "content-type": "text/event-stream; charset=utf-8", "cache-control": "no-cache, no-transform", connection: "keep-alive", "x-accel-buffering": "no" });
  const abort = new AbortController();
  res.on("close", () => abort.abort()); // app hung up or barge-in cancelled the request

  const payload = {
    model: MODEL,
    max_tokens: MAX_TOKENS,
    stream: true,
    system: buildSystem(body),
    messages,
    tools: [webSearchTool(body.timezone), ...CLIENT_TOOLS],
  };

  let upstream;
  try {
    upstream = await fetch(`${API_BASE}/v1/messages`, {
      method: "POST",
      signal: abort.signal,
      headers: { "content-type": "application/json", "x-api-key": API_KEY, "anthropic-version": "2023-06-01" },
      body: JSON.stringify(payload),
    });
  } catch (e) {
    if (!abort.signal.aborted) { sse(res, "error", { code: "upstream_unreachable", message: "No pude contactar con el servicio de IA." }); res.end(); }
    return;
  }
  if (!upstream.ok || !upstream.body) {
    let detail = ""; try { detail = (await upstream.text()).slice(0, 300); } catch {}
    console.error("[midas] upstream", upstream.status, detail);
    sse(res, "error", { code: `upstream_${upstream.status}`, message: upstream.status === 429 ? "Límite de uso alcanzado, prueba en un momento." : "El servicio de IA devolvió un error." });
    return res.end();
  }

  const blocks = new Map(); // index -> {type,name,id,json}
  const sources = [];
  try {
    for await (const ev of parseUpstreamSSE(upstream.body)) {
      switch (ev.type) {
        case "content_block_start": {
          const cb = ev.content_block || {};
          blocks.set(ev.index, { type: cb.type, name: cb.name, id: cb.id, json: "" });
          if (cb.type === "web_search_tool_result" && Array.isArray(cb.content)) {
            for (const r of cb.content) if (r && r.url && sources.length < 6 && !sources.some((s) => s.url === r.url)) sources.push({ title: String(r.title || r.url).slice(0, 140), url: r.url });
          }
          break;
        }
        case "content_block_delta": {
          const b = blocks.get(ev.index); const d = ev.delta || {};
          if (d.type === "text_delta" && d.text) sse(res, "text", { delta: d.text });
          else if (d.type === "input_json_delta" && b) b.json += d.partial_json || "";
          break;
        }
        case "content_block_stop": {
          const b = blocks.get(ev.index);
          if (!b) break;
          if (b.type === "server_tool_use" && b.name === "web_search") {
            let q = ""; try { q = JSON.parse(b.json || "{}").query || ""; } catch {}
            sse(res, "search", { query: q });
          } else if (b.type === "tool_use") {
            let input = {}; try { input = JSON.parse(b.json || "{}"); } catch {}
            sse(res, "action", { id: b.id, name: b.name, input });
          }
          break;
        }
        case "message_delta":
          if (ev.delta && ev.delta.stop_reason) blocks.stopReason = ev.delta.stop_reason;
          break;
        case "error":
          sse(res, "error", { code: (ev.error && ev.error.type) || "stream_error", message: "La respuesta se cortó." });
          break;
      }
    }
    if (sources.length) sse(res, "sources", { items: sources });
    sse(res, "done", { stop_reason: blocks.stopReason || "end_turn" });
  } catch (e) {
    if (!abort.signal.aborted) sse(res, "error", { code: "stream_failed", message: "La conexión con la IA se interrumpió." });
  }
  res.end();
}

// ---------- server ----------
const server = http.createServer(async (req, res) => {
  const ip = (req.headers["x-forwarded-for"] || req.socket.remoteAddress || "").toString().split(",")[0].trim();
  try {
    if (req.method === "GET" && req.url === "/health") { res.writeHead(200, { "content-type": "application/json" }); return res.end(JSON.stringify({ ok: true, model: MODEL, keyConfigured: !!API_KEY })); }
    if (req.method === "POST" && req.url === "/turn") {
      if (!authorized(req)) { res.writeHead(401, { "content-type": "application/json" }); return res.end(JSON.stringify({ error: "unauthorized" })); }
      if (rateLimited(ip)) { res.writeHead(429, { "content-type": "application/json" }); return res.end(JSON.stringify({ error: "rate_limited" })); }
      return await handleTurn(req, res);
    }
    res.writeHead(404, { "content-type": "application/json" }); res.end(JSON.stringify({ error: "not_found" }));
  } catch (e) {
    if (!res.headersSent) { res.writeHead(e.status || 500, { "content-type": "application/json" }); res.end(JSON.stringify({ error: e.message })); }
    else res.end();
  }
});
server.listen(PORT, () => console.log(`[midas] backend on :${PORT} · model ${MODEL}`));
module.exports = { sanitizeMessages, buildSystem };
