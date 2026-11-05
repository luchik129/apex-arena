// Flexo League: перевод без ИИ — постов, строк интерфейса и своих упражнений.
// Бесплатный Google Translate (тот же адрес, что у переводчика в браузере, ключ не нужен), запасной — MyMemory.
// ИИ-лимит не тратит, вход в аккаунт не нужен (переводится и экран входа).
// Развернуть: supabase functions deploy translate --no-verify-jwt
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const LANGS = new Set(["ru", "en", "uk", "kk", "de", "es", "fr", "tr"]);

const guess = (t: string) =>
  /[әғқңөұүһ]/i.test(t) ? "kk" : /[іїєґ]/i.test(t) ? "uk" : /[а-яё]/i.test(t) ? "ru" : /[äöüß]/i.test(t) ? "de"
  : /[ñ¿¡]/i.test(t) ? "es" : /[çàâèêëîïôœùû]/i.test(t) ? "fr" : /[ğışİ]/.test(t) ? "tr" : "en";

async function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let t: number | undefined;
  try { return await Promise.race([p, new Promise<T>((_, rej) => { t = setTimeout(() => rej(new Error("timeout")), ms); })]); }
  finally { clearTimeout(t); }
}

async function google(text: string, tl: string): Promise<string> {
  const url = `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=${tl}&dt=t&q=${encodeURIComponent(text)}`;
  const r = await withTimeout(fetch(url), 9000);
  if (!r.ok) throw new Error("google " + r.status);
  const j = await r.json();
  const out = ((j && j[0]) || []).map((x: unknown[]) => (x && x[0]) || "").join("");
  if (!out) throw new Error("google empty");
  return out;
}

async function mymemory(text: string, tl: string): Promise<string> {
  const sl = guess(text);
  if (sl === tl) return text;
  const r = await withTimeout(fetch(`https://api.mymemory.translated.net/get?q=${encodeURIComponent(text.slice(0, 480))}&langpair=${sl}|${tl}`), 10000);
  const j = await r.json();
  const t = j?.responseData?.translatedText;
  if (!t || Number(j.responseStatus) !== 200 || /MYMEMORY WARNING|QUERY LENGTH LIMIT/i.test(t)) throw new Error("mymemory");
  return t;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const reply = (status: number, data: Record<string, unknown>) =>
    new Response(JSON.stringify({ apex: 1, ...data }), { status, headers: { ...cors, "Content-Type": "application/json" } });
  try {
    const raw = await req.text();
    if (raw.length > 30000) return reply(413, { error: "Слишком длинный запрос" });
    const { q, tl } = JSON.parse(raw);
    if (!LANGS.has(String(tl)) || !Array.isArray(q) || !q.length) return reply(400, { error: "bad args" });
    const list = q.slice(0, 40).map((s: unknown) => String(s ?? "").slice(0, 2000));
    if (list.reduce((a: number, s: string) => a + s.length, 0) > 12000) return reply(413, { error: "Слишком много текста" });
    const items: (string | null)[] = list.map(() => null);
    let i = 0;
    await Promise.all(Array.from({ length: Math.min(5, list.length) }, async () => {
      while (i < list.length) {
        const k = i++, s = list[k];
        if (!s.trim()) { items[k] = s; continue; }
        try { items[k] = await google(s, tl); } catch { try { items[k] = await mymemory(s, tl); } catch { items[k] = null; } }
      }
    }));
    return reply(200, { items });
  } catch (e) {
    return reply(500, { error: String(e) });
  }
});
