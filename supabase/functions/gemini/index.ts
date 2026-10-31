// APEX Arena: прокси к Gemini. Ключ хранится в секрете GEMINI_API_KEY (Edge Functions → Secrets),
// в приложении его нет. Вызывать может только вошедший пользователь (Verify JWT включён по умолчанию).
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const reply = (status: number, data: unknown) =>
    new Response(JSON.stringify({ apex: 1, status, data }), { headers: { ...cors, "Content-Type": "application/json" } });
  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) return reply(503, { error: { message: "no key" } });
  try {
    const { model, body } = await req.json();
    if (!/^[\w.\-]+$/.test(String(model))) return reply(400, { error: { message: "bad model" } });
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const text = await r.text();
    let data: unknown = null;
    try { data = JSON.parse(text); } catch { data = { error: { message: text.slice(0, 300) } }; }
    return reply(r.status, data);
  } catch (e) {
    return reply(500, { error: { message: String(e) } });
  }
});
