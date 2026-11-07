// Flexo League: видео ленты хранятся в Cloudflare R2 (скачивание бесплатно, в отличие от трафика Supabase).
// Ключи R2 только в секретах Edge Functions, в приложении их нет:
//   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET (flexo-videos), R2_PUBLIC_URL (https://pub-….r2.dev)
// Действия (только для вошедших, и только со своей папкой <uid>/):
//   sign  {size, type}  → ссылка на загрузку на 10 минут (размер зашит в подпись, больше не загрузить)
//   delete {url}        → удалить своё видео (когда удаляют пост)
//   purge               → удалить все свои видео (когда удаляют аккаунт)
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const MAX_MB = 30;
const TYPES = { "video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm", "video/x-m4v": "m4v" };

const enc = new TextEncoder();
const hex = (b) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const sha = async (s) => hex(await crypto.subtle.digest("SHA-256", enc.encode(s)));
const hmac = async (key, s) => new Uint8Array(await crypto.subtle.sign("HMAC", await crypto.subtle.importKey("raw", typeof key === "string" ? enc.encode(key) : key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]), enc.encode(s)));
const rfc3986 = (s) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
const encPath = (p) => p.split("/").map(rfc3986).join("/");

// AWS Signature V4 (R2 понимает S3 API). headers: {name: value} в нижнем регистре, обязательно с host.
async function sigv4({ method, host, path, query = {}, headers, secret, akid, now = new Date(), presign = 0 }) {
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, ""), day = amzDate.slice(0, 8), scope = `${day}/auto/s3/aws4_request`;
  const names = Object.keys(headers).map((h) => h.toLowerCase()).sort(), signed = names.join(";");
  const q = { ...query };
  if (presign) Object.assign(q, { "X-Amz-Algorithm": "AWS4-HMAC-SHA256", "X-Amz-Credential": `${akid}/${scope}`, "X-Amz-Date": amzDate, "X-Amz-Expires": String(presign), "X-Amz-SignedHeaders": signed });
  const qs = Object.keys(q).sort().map((k) => `${rfc3986(k)}=${rfc3986(q[k])}`).join("&");
  const payload = presign ? "UNSIGNED-PAYLOAD" : await sha("");
  const hdrs = presign ? headers : { ...headers, "x-amz-date": amzDate, "x-amz-content-sha256": payload };
  const hn = Object.keys(hdrs).map((h) => h.toLowerCase()).sort();
  const canon = [method, encPath(path), qs, hn.map((h) => `${h}:${String(hdrs[h]).trim()}\n`).join(""), hn.join(";"), payload].join("\n");
  const sts = ["AWS4-HMAC-SHA256", amzDate, scope, await sha(canon)].join("\n");
  let k = await hmac("AWS4" + secret, day); for (const p of ["auto", "s3", "aws4_request"]) k = await hmac(k, p);
  const sig = hex(await hmac(k, sts));
  if (presign) return { url: `https://${host}${encPath(path)}?${qs}&X-Amz-Signature=${sig}` };
  return { url: `https://${host}${encPath(path)}${qs ? "?" + qs : ""}`, headers: { ...hdrs, authorization: `AWS4-HMAC-SHA256 Credential=${akid}/${scope}, SignedHeaders=${hn.join(";")}, Signature=${sig}` } };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const reply = (status, data) => new Response(JSON.stringify(data), { status, headers: { ...cors, "Content-Type": "application/json" } });
  const E = (k) => Deno.env.get(k) || "";
  const acc = E("R2_ACCOUNT_ID"), akid = E("R2_ACCESS_KEY_ID"), secret = E("R2_SECRET_ACCESS_KEY"), bucket = E("R2_BUCKET") || "flexo-videos", pub = E("R2_PUBLIC_URL").replace(/\/+$/, "");
  if (!acc || !akid || !secret || !pub) return reply(503, { error: "no r2" });
  const URL_ = E("SUPABASE_URL"), ANON = E("SUPABASE_ANON_KEY") || E("SUPABASE_SERVICE_ROLE_KEY");
  const u = await fetch(`${URL_}/auth/v1/user`, { headers: { Authorization: req.headers.get("Authorization") || "", apikey: ANON } }).then((r) => (r.ok ? r.json() : null)).catch(() => null);
  if (!u || !u.id) return reply(401, { error: "Войди в аккаунт" });
  const host = `${acc}.r2.cloudflarestorage.com`, base = `/${bucket}/`;
  let body = {}; try { body = await req.json(); } catch (_) { /* пусто */ }
  const noHost = (h) => { const o = { ...h }; delete o.host; return o; }; // host Deno подставит сам
  const del = async (key) => { const s = await sigv4({ method: "DELETE", host, path: base + key, headers: { host }, secret, akid }); const r = await fetch(s.url, { method: "DELETE", headers: noHost(s.headers) }); return r.ok || r.status === 404; };
  try {
    if (body.action === "sign") {
      const size = Math.floor(Number(body.size)), type = String(body.type || "video/mp4").toLowerCase(), ext = TYPES[type];
      if (!ext) return reply(400, { error: "Этот формат видео не поддерживается. Попробуй MP4." });
      if (!(size > 0) || size > MAX_MB * 1048576) return reply(413, { error: `Видео больше ${MAX_MB} МБ` });
      const key = `${u.id}/${Date.now()}_${crypto.randomUUID().slice(0, 12)}.${ext}`, cache = "public, max-age=31536000, immutable";
      const s = await sigv4({ method: "PUT", host, path: base + key, headers: { host, "content-length": String(size), "content-type": type, "cache-control": cache }, secret, akid, presign: 600 });
      return reply(200, { upload: s.url, headers: { "Content-Type": type, "Cache-Control": cache }, url: `${pub}/${key}` });
    }
    if (body.action === "delete") {
      const url = String(body.url || ""); if (!url.startsWith(pub + "/")) return reply(400, { error: "bad url" });
      const key = decodeURIComponent(url.slice(pub.length + 1)); if (!key.startsWith(u.id + "/") || key.includes("..")) return reply(403, { error: "not yours" });
      return reply(200, { ok: await del(key) });
    }
    if (body.action === "purge") {
      const s = await sigv4({ method: "GET", host, path: `/${bucket}`, query: { "list-type": "2", prefix: u.id + "/", "max-keys": "1000" }, headers: { host }, secret, akid });
      const xml = await (await fetch(s.url, { headers: noHost(s.headers) })).text();
      const keys = [...xml.matchAll(/<Key>([^<]+)<\/Key>/g)].map((m) => m[1].replace(/&amp;/g, "&")).filter((k) => k.startsWith(u.id + "/"));
      let n = 0; for (const k of keys) if (await del(k)) n++;
      return reply(200, { ok: true, deleted: n });
    }
    return reply(400, { error: "bad action" });
  } catch (e) {
    return reply(500, { error: String(e && e.message || e) });
  }
});
