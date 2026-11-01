// Flexo League: общий прокси к Gemini (гайды по технике, переводы, разбор тренировки).
// Ключ хранится только в секрете GEMINI_API_KEY (Edge Functions → Secrets), в приложении его нет.
// Пускает только вошедших пользователей, не больше 40 запросов в день на человека (update_v27.sql), только модели Flash.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const reply = (status, data) =>
    new Response(JSON.stringify({ apex: 1, status, data }), { headers: { ...cors, "Content-Type": "application/json" } });
  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) return reply(503, { error: { message: "no key" } });
  const URL_ = Deno.env.get("SUPABASE_URL"), ANON = Deno.env.get("SUPABASE_ANON_KEY"), SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const u = await fetch(`${URL_}/auth/v1/user`, { headers: { Authorization: req.headers.get("Authorization") || "", apikey: ANON || SERVICE || "" } }).then((r) => (r.ok ? r.json() : null)).catch(() => null);
  if (!u || !u.id) return reply(401, { error: { message: "Войди в аккаунт" } });
  try {
    const raw = await req.text();
    if (raw.length > 150000) return reply(413, { error: { message: "Слишком длинный запрос" } });
    const { model, body } = JSON.parse(raw);
    // v27: только быстрые дешёвые модели Flash (чужой не сможет гонять дорогие модели за твой счёт)
    if (!/^gemini-[\d.]+-flash(-lite)?(-preview)?(-\d{2}-\d{4})?$/.test(String(model))) return reply(400, { error: { message: "bad model" } });
    if (!body || typeof body !== "object" || !Array.isArray(body.contents)) return reply(400, { error: { message: "bad body" } });
    const gc = (body.generationConfig = body.generationConfig || {});
    gc.maxOutputTokens = Math.min(Number(gc.maxOutputTokens) || 8192, 8192);
    delete body.tools; delete body.cachedContent;
    if (!SERVICE) return reply(503, { error: { message: "Нет SUPABASE_SERVICE_ROLE_KEY" } });
    {
      const q = await fetch(`${URL_}/rest/v1/rpc/ai_quota_use`, { method: "POST", headers: { "Content-Type": "application/json", apikey: SERVICE, Authorization: `Bearer ${SERVICE}` }, body: JSON.stringify({ p_user: u.id, p_kind: "misc", p_day: new Date().toISOString().slice(0, 10) }) });
      if (!q.ok) return reply(500, { error: { message: "Сервер не обновлён: запусти update_v24.sql" } });
      if ((await q.json()) < 0) return reply(429, { error: { message: "Лимит ИИ на сегодня исчерпан" } });
    }
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const text = await r.text();
    let data = null;
    try { data = JSON.parse(text); } catch { data = { error: { message: text.slice(0, 300) } }; }
    return reply(r.status, data);
  } catch (e) {
    return reply(500, { error: { message: String(e) } });
  }
});
