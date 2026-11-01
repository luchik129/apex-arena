// Flexo League: общий прокси к Gemini (гайды по технике, переводы, разбор тренировки).
// Ключ хранится только в секрете GEMINI_API_KEY (Edge Functions → Secrets), в приложении его нет.
// Пускает только вошедших пользователей, не больше 60 запросов в день на человека (update_v24.sql).
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
    const { model, body } = await req.json();
    if (!/^[\w.\-]+$/.test(String(model))) return reply(400, { error: { message: "bad model" } });
    if (SERVICE) {
      const q = await fetch(`${URL_}/rest/v1/rpc/ai_quota_use`, { method: "POST", headers: { "Content-Type": "application/json", apikey: SERVICE, Authorization: `Bearer ${SERVICE}` }, body: JSON.stringify({ p_user: u.id, p_kind: "misc", p_day: new Date().toISOString().slice(0, 10) }) });
      if (q.ok && (await q.json()) < 0) return reply(429, { error: { message: "Лимит ИИ на сегодня исчерпан" } });
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
