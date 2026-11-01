// Flexo League: ИИ-дневник питания и активности.
// Ключ Gemini хранится только здесь, в секрете GEMINI_API_KEY (Edge Functions → Secrets).
// Лимит на человека в день: еда 3 раза, активность 2 раза (таблица ai_usage, update_v24.sql).
// Вызывать может только вошедший пользователь.

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const LIMIT = { food: 3, activity: 2 };
const MODELS = ["gemini-3.6-flash", "gemini-3-flash-preview", "gemini-3.5-flash-lite"];

const num = (v, lo, hi) => { const n = Number(v); return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : lo; };
const str = (v, n) => String(v ?? "").replace(/\s+/g, " ").trim().slice(0, n);

const SCHEMA_FOOD = {
  type: "OBJECT",
  properties: {
    items: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          name: { type: "STRING" }, grams: { type: "NUMBER" },
          kcal100: { type: "NUMBER" }, p100: { type: "NUMBER" }, c100: { type: "NUMBER" }, f100: { type: "NUMBER" },
          meal: { type: "STRING", enum: ["breakfast", "lunch", "dinner", "snack"] },
        },
        required: ["name", "grams", "kcal100", "p100", "c100", "f100", "meal"],
      },
    },
  },
  required: ["items"],
};
const SCHEMA_ACT = {
  type: "OBJECT",
  properties: {
    items: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: { name: { type: "STRING" }, minutes: { type: "NUMBER" }, met: { type: "NUMBER" }, kcal: { type: "NUMBER" } },
        required: ["name", "minutes", "met", "kcal"],
      },
    },
  },
  required: ["items"],
};

function prompt(kind, b) {
  const lang = str(b.lang, 30) || "Русский", text = str(b.text, 600);
  if (kind === "food") {
    return `Ты нутрициолог. Пользователь пишет, что он съел. Разбери текст на отдельные продукты или блюда.
Для каждого: name — короткое название на языке «${lang}»; grams — вес порции в граммах (если указаны штуки, ложки, тарелки или порция не указана — оцени типичный вес); kcal100, p100, c100, f100 — калории, белки, углеводы и жиры на 100 г по справочным таблицам (для готового блюда — для готового вида); meal — приём пищи по тексту (завтрак → breakfast, обед → lunch, ужин → dinner, перекус → snack), а если не сказано — по времени ${str(b.time, 5) || "12:00"}.
Напитки тоже считай (вода и чай/кофе без сахара — 0 ккал, их можно не включать). Не выдумывай продукты, которых нет в тексте. Если еды в тексте нет — верни пустой items.
Текст: """${text}"""`;
  }
  const bw = num(b.bw, 30, 250) || 70;
  return `Ты спортивный физиолог. Пользователь описывает, чем занимался. Оцени сожжённые калории для каждой активности.
Данные: вес ${bw} кг, пол ${b.sex === "f" ? "женский" : "мужской"}, возраст ${num(b.age, 10, 90) || 25}.
Для каждой активности: name — коротко на языке «${lang}»; minutes — длительность (если не указана — типичная); met — MET по Compendium of Physical Activities (силовая тренировка в зале 3.5–6, бег 7–11, ходьба 3–4, велосипед 6–10, плавание 6–9, футбол 7–10); kcal = met × ${bw} × minutes / 60, округли.
Считай только саму активность, без обычного дневного расхода. Если активности в тексте нет — верни пустой items.
Текст: """${text}"""`;
}

function clean(kind, items) {
  if (!Array.isArray(items)) return [];
  if (kind === "food") {
    const meals = ["breakfast", "lunch", "dinner", "snack"];
    return items.slice(0, 15).map((x) => ({
      name: str(x.name, 60) || "Еда", grams: Math.round(num(x.grams, 1, 3000)),
      kcal100: Math.round(num(x.kcal100, 0, 900)), p100: +num(x.p100, 0, 100).toFixed(1), c100: +num(x.c100, 0, 100).toFixed(1), f100: +num(x.f100, 0, 100).toFixed(1),
      meal: meals.includes(x.meal) ? x.meal : "snack",
    })).filter((x) => x.name);
  }
  return items.slice(0, 10).map((x) => ({ name: str(x.name, 60) || "Активность", minutes: Math.round(num(x.minutes, 1, 600)), met: +num(x.met, 1, 20).toFixed(1), kcal: Math.round(num(x.kcal, 0, 3000)) }));
}

async function gemini(key, kind, b) {
  const body = { contents: [{ role: "user", parts: [{ text: prompt(kind, b) }] }], generationConfig: { responseMimeType: "application/json", responseSchema: kind === "food" ? SCHEMA_FOOD : SCHEMA_ACT, temperature: 0.2 } };
  const models = [Deno.env.get("GEMINI_MODEL"), ...MODELS].filter(Boolean);
  let last = "AI не ответил";
  for (const m of models) {
    try {
      const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${m}:generateContent?key=${key}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      const j = await r.json().catch(() => null);
      if (r.status !== 200) { last = j?.error?.message || `AI ${r.status}`; continue; }
      const t = (j?.candidates?.[0]?.content?.parts || []).map((p) => p.text || "").join("");
      const o = JSON.parse(t.match(/\{[\s\S]*\}/)?.[0] || "{}");
      return clean(kind, o.items);
    } catch (e) { last = String(e?.message || e); }
  }
  throw new Error(last);
}

export async function handler(req) {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const reply = (data, status = 200) => new Response(JSON.stringify({ flx: 1, ...data }), { status, headers: { ...cors, "Content-Type": "application/json" } });
  const URL_ = Deno.env.get("SUPABASE_URL"), ANON = Deno.env.get("SUPABASE_ANON_KEY"), SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), KEY = Deno.env.get("GEMINI_API_KEY");
  if (!KEY) return reply({ error: "no_key", message: "На сервере не задан GEMINI_API_KEY" }, 503);
  if (!SERVICE) return reply({ error: "no_service", message: "Нет SUPABASE_SERVICE_ROLE_KEY" }, 503);
  const auth = req.headers.get("Authorization") || "";
  const u = await fetch(`${URL_}/auth/v1/user`, { headers: { Authorization: auth, apikey: ANON || SERVICE } }).then((r) => (r.ok ? r.json() : null)).catch(() => null);
  if (!u || !u.id) return reply({ error: "auth", message: "Войди в аккаунт" }, 401);
  let b; try { b = await req.json(); } catch { return reply({ error: "bad", message: "Пустой запрос" }, 400); }
  const kind = b.kind === "activity" ? "activity" : "food", text = str(b.text, 600), day = new Date().toISOString().slice(0, 10); // v27: лимит по дате сервера, а не телефона
  if (text.length < 2) return reply({ error: "bad", message: "Напиши, что съел или что делал" }, 400);
  const rpc = (fn, args) => fetch(`${URL_}/rest/v1/rpc/${fn}`, { method: "POST", headers: { "Content-Type": "application/json", apikey: SERVICE, Authorization: `Bearer ${SERVICE}` }, body: JSON.stringify(args) });
  const q = await rpc("ai_quota_use", { p_user: u.id, p_kind: kind, p_day: day });
  if (!q.ok) return reply({ error: "server", message: "Сервер не обновлён: запусти update_v24.sql в Supabase" }, 500);
  const left = await q.json();
  if (left < 0) return reply({ error: "limit", left: 0, limit: LIMIT[kind], message: "Лимит на сегодня исчерпан" }, 429);
  try {
    const items = await gemini(KEY, kind, b);
    if (!items.length) await rpc("ai_quota_refund", { p_user: u.id, p_kind: kind, p_day: day }); // ничего не нашёл — попытку не списываем
    return reply({ ok: true, items, left: items.length ? left : left + 1, limit: LIMIT[kind] });
  } catch (e) {
    await rpc("ai_quota_refund", { p_user: u.id, p_kind: kind, p_day: day });
    return reply({ error: "ai", message: "ИИ сейчас не ответил, попробуй ещё раз", detail: String(e?.message || e).slice(0, 200) }, 502);
  }
}

if (typeof Deno !== "undefined" && Deno.serve && !Deno.env.get("FLX_TEST")) Deno.serve(handler);
