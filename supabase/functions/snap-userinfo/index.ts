// APEX Arena: «переводчик» профиля Snapchat для входа через Supabase (custom:snapchat).
// Supabase ждёт плоский ответ { sub, name, picture }, а Snapchat отдаёт { data: { me: { externalId, displayName, bitmoji } } }.
// Развернуть с выключенной проверкой JWT (Supabase Auth зовёт функцию с токеном Snapchat, а не Supabase).
Deno.serve(async (req) => {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return new Response(JSON.stringify({ error: "no token" }), { status: 401, headers: { "Content-Type": "application/json" } });
  const query = "{me{externalId displayName bitmoji{avatar}}}";
  const r = await fetch("https://kit.snapchat.com/v1/me?query=" + encodeURIComponent(query), { headers: { Authorization: auth } });
  const text = await r.text();
  if (!r.ok) return new Response(text, { status: r.status, headers: { "Content-Type": "application/json" } });
  const me = (JSON.parse(text)?.data?.me) ?? {};
  if (!me.externalId) return new Response(JSON.stringify({ error: "no externalId", raw: text.slice(0, 300) }), { status: 502, headers: { "Content-Type": "application/json" } });
  return Response.json({
    sub: me.externalId,
    name: me.displayName ?? null,
    preferred_username: me.displayName ?? null,
    picture: me.bitmoji?.avatar ?? null,
    email_verified: false,
  });
});
