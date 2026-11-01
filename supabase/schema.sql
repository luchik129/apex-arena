-- APEX Arena: схема Supabase. Вставь целиком в SQL Editor проекта и нажми Run.
-- Повторный запуск безопасен (все create ... if not exists / or replace).

create extension if not exists citext;
create extension if not exists pgcrypto;

-- ---------- кланы ----------
create table if not exists public.clans (
  id uuid primary key default gen_random_uuid(),
  name citext unique not null,
  emblem text not null default '🛡️',
  code text unique not null,
  leader_id uuid not null references auth.users(id) on delete cascade,
  battle jsonb,                        -- {"week_key":"2026-10-26","opponent_id":"...","challenged":true}
  created_at timestamptz not null default now()
);

-- ---------- публичные профили (только то, что видно в рейтингах) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nickname citext unique not null,
  friend_code text unique not null,
  sex text not null default 'm',
  arena_idx int not null default 0,
  trophies int not null default 0,
  level int not null default 1,
  power_score numeric not null default 0,
  bests jsonb not null default '{}'::jsonb,       -- {"Bench Press": 100, ...} лучший e1RM по упражнениям
  boss jsonb not null default '{}'::jsonb,        -- {"bench":100,"squat":140,"deadlift":160}
  week_key text,                                  -- понедельник текущей недели (YYYY-MM-DD)
  week jsonb not null default '{"workouts":0,"prs":0,"streak":0}'::jsonb,
  prev_week_key text,
  prev_week jsonb,
  clan_id uuid references public.clans(id) on delete set null,
  clan_role text not null default 'member',       -- leader | deputy | member
  title text,
  updated_at timestamptz not null default now()
);
create index if not exists profiles_clan_idx on public.profiles(clan_id);
create index if not exists profiles_trophies_idx on public.profiles(trophies desc);

-- ---------- приватное состояние приложения (резервная копия и синхронизация между устройствами) ----------
create table if not exists public.app_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

-- ---------- друзья (односторонняя подписка) ----------
create table if not exists public.friendships (
  user_id uuid not null references auth.users(id) on delete cascade,
  friend_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id)
);

-- ---------- дуэли 1 на 1 ----------
create table if not exists public.duels (
  id uuid primary key default gen_random_uuid(),
  week_key text not null,
  a_id uuid not null references auth.users(id) on delete cascade,  -- кто вызвал
  b_id uuid not null references auth.users(id) on delete cascade,  -- кого вызвали
  status text not null default 'active',                           -- active | cancelled
  created_at timestamptz not null default now()
);
create index if not exists duels_a_idx on public.duels(a_id, week_key);
create index if not exists duels_b_idx on public.duels(b_id, week_key);

-- ---------- RLS ----------
alter table public.clans enable row level security;
alter table public.profiles enable row level security;
alter table public.app_state enable row level security;
alter table public.friendships enable row level security;
alter table public.duels enable row level security;

drop policy if exists "profiles read" on public.profiles;
create policy "profiles read" on public.profiles for select to authenticated using (true);
drop policy if exists "profiles insert own" on public.profiles;
create policy "profiles insert own" on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists "profiles update own" on public.profiles;
create policy "profiles update own" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "clans read" on public.clans;
create policy "clans read" on public.clans for select to authenticated using (true);
drop policy if exists "clans update officers" on public.clans;
create policy "clans update officers" on public.clans for update to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.clan_id = clans.id and p.clan_role in ('leader','deputy')));

drop policy if exists "state own" on public.app_state;
create policy "state own" on public.app_state for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "friends own" on public.friendships;
create policy "friends own" on public.friendships for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "duels mine" on public.duels;
create policy "duels mine" on public.duels for select to authenticated using (a_id = auth.uid() or b_id = auth.uid());
drop policy if exists "duels create" on public.duels;
create policy "duels create" on public.duels for insert to authenticated with check (a_id = auth.uid() and a_id <> b_id);
drop policy if exists "duels update mine" on public.duels;
create policy "duels update mine" on public.duels for update to authenticated using (a_id = auth.uid() or b_id = auth.uid());

-- ---------- функции ----------
-- свободен ли ник (доступно и до регистрации)
create or replace function public.nick_available(p_nick text) returns boolean
language sql security definer set search_path = public as $$
  select not exists (select 1 from public.profiles where nickname = p_nick::citext);
$$;
grant execute on function public.nick_available(text) to anon, authenticated;

create or replace function public.clan_join(p_code text) returns public.clans
language plpgsql security definer set search_path = public as $$
declare c public.clans; n int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if exists (select 1 from profiles where id = auth.uid() and clan_id is not null) then raise exception 'Сначала выйди из текущего клана'; end if;
  select * into c from clans where upper(clans.code) = upper(trim(p_code));
  if c.id is null then raise exception 'Клан с таким кодом не найден'; end if;
  select count(*) into n from profiles where clan_id = c.id;
  if n >= 30 then raise exception 'Клан заполнен (30/30)'; end if;
  update profiles set clan_id = c.id, clan_role = 'member', updated_at = now() where id = auth.uid();
  return c;
end $$;

create or replace function public.clan_leave() returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; heir uuid;
begin
  select * into me from profiles where id = auth.uid();
  if me.clan_id is null then return; end if;
  update profiles set clan_id = null, clan_role = 'member', updated_at = now() where id = auth.uid();
  if me.clan_role = 'leader' then
    select id into heir from profiles where clan_id = me.clan_id order by (clan_role = 'deputy') desc, trophies desc limit 1;
    if heir is null then delete from clans where id = me.clan_id;
    else update profiles set clan_role = 'leader' where id = heir; update clans set leader_id = heir where id = me.clan_id; end if;
  end if;
end $$;

create or replace function public.clan_set_role(p_member uuid, p_role text) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  select * into me from profiles where id = auth.uid();
  if me.clan_id is null or me.clan_role <> 'leader' then raise exception 'Только лидер меняет роли'; end if;
  if p_role not in ('deputy','member') then raise exception 'bad role'; end if;
  update profiles set clan_role = p_role where id = p_member and clan_id = me.clan_id and id <> auth.uid();
end $$;

create or replace function public.clan_kick(p_member uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  select * into me from profiles where id = auth.uid();
  if me.clan_id is null or me.clan_role not in ('leader','deputy') then raise exception 'Нет прав'; end if;
  update profiles set clan_id = null, clan_role = 'member' where id = p_member and clan_id = me.clan_id and clan_role <> 'leader' and id <> auth.uid();
end $$;

-- случайный соперник для дуэли: близкая арена, не я, не из тех, с кем уже есть дуэль на этой неделе
create or replace function public.random_opponent(p_arena int, p_week text) returns setof public.profiles
language sql security definer set search_path = public as $$
  select * from profiles p
  where p.id <> auth.uid()
    and abs(p.arena_idx - p_arena) <= 1
    and not exists (select 1 from duels d where d.week_key = p_week and d.status = 'active' and ((d.a_id = auth.uid() and d.b_id = p.id) or (d.b_id = auth.uid() and d.a_id = p.id)))
  order by random() limit 1;
$$;

grant execute on function public.clan_join(text), public.clan_leave(), public.clan_set_role(uuid, text), public.clan_kick(uuid), public.random_opponent(int, text) to authenticated;

-- обновление updated_at
create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();
drop trigger if exists state_touch on public.app_state;
create trigger state_touch before update on public.app_state for each row execute function public.touch_updated_at();

-- общие настройки приложения (ключ Gemini и т.п.): читают все вошедшие, менять можно только в SQL Editor / Table Editor
create table if not exists public.app_config (
  key text primary key,
  value text not null
);
alter table public.app_config enable row level security;
drop policy if exists "config read" on public.app_config;
create policy "config read" on public.app_config for select to authenticated using (true);

-- APEX Arena v14: обновление базы. Вставь целиком в SQL Editor и нажми Run.
-- Можно запускать сколько угодно раз. Данные не удаляются.

-- ---------- кланы: создание заново ----------
-- старую функцию удаляем полностью и создаём новую clan_new (приложение вызывает её первой)
drop function if exists public.clan_create(text, text);

create or replace function public.clan_new(p_name text, p_emblem text) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_code text;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if exists (select 1 from public.profiles pr where pr.id = v_uid and pr.clan_id is not null) then raise exception 'Ты уже в клане'; end if;
  if length(trim(p_name)) < 3 then raise exception 'Название от 3 символов'; end if;
  if exists (select 1 from public.clans cl where cl.name = trim(p_name)::citext) then raise exception 'Клан с таким названием уже есть'; end if;
  loop
    v_code := 'APEX' || (floor(random() * 9000) + 1000)::int::text;
    exit when not exists (select 1 from public.clans cl where cl.code = v_code);
  end loop;
  insert into public.clans as cl (name, emblem, code, leader_id)
    values (left(trim(p_name), 24), coalesce(nullif(p_emblem, ''), 'fa-shield-halved|#8B5CF6'), v_code, v_uid)
    returning cl.id into v_id;
  update public.profiles pr set clan_id = v_id, clan_role = 'leader' where pr.id = v_uid;
  return json_build_object('id', v_id, 'code', v_code);
end $$;

-- старое имя оставляем как обёртку (для старых версий приложения)
create or replace function public.clan_create(p_name text, p_emblem text) returns json
language sql security definer set search_path = public as $$ select public.clan_new(p_name, p_emblem); $$;

grant execute on function public.clan_new(text, text), public.clan_create(text, text) to authenticated;

-- ---------- профили: аватар, активность по дням, защита кубков ----------
alter table public.profiles add column if not exists avatar text;               -- маленькое фото (data:image/jpeg;base64,...)
alter table public.profiles add column if not exists days jsonb not null default '{}'::jsonb;  -- {"2026-10-31":{"w":1,"p":2}}
alter table public.profiles add column if not exists trophy_day date;
alter table public.profiles add column if not exists trophy_gain int not null default 0;

-- античит: реальные пределы весов и не больше 250 кубков в день
create or replace function public.profiles_guard() returns trigger
language plpgsql as $$
declare
  v_caps jsonb := '{"bench":355,"squat":490,"deadlift":505}';
  v_gain int;
  v_arena int;
begin
  if auth.uid() is null then return new; end if; -- правки из SQL Editor не трогаем
  new.bests := coalesce((select jsonb_object_agg(b.key, least(b.value::numeric, 600)) from jsonb_each_text(coalesce(new.bests, '{}'::jsonb)) b where b.value ~ '^[0-9]+(\.[0-9]+)?$'), '{}'::jsonb);
  new.boss := coalesce((select jsonb_object_agg(b.key, least(b.value::numeric, coalesce((v_caps ->> b.key)::numeric, 600))) from jsonb_each_text(coalesce(new.boss, '{}'::jsonb)) b where b.value ~ '^[0-9]+(\.[0-9]+)?$'), '{}'::jsonb);
  if new.avatar is not null and length(new.avatar) > 40000 then new.avatar := null; end if;
  if tg_op = 'INSERT' then
    new.trophies := least(greatest(coalesce(new.trophies, 0), 0), 100);
    new.trophy_day := current_date;
    new.trophy_gain := new.trophies;
  elsif new.trophies > old.trophies then
    v_gain := case when old.trophy_day = current_date then coalesce(old.trophy_gain, 0) else 0 end;
    new.trophies := least(new.trophies, old.trophies + greatest(0, 250 - v_gain));
    new.trophy_gain := v_gain + (new.trophies - old.trophies);
    new.trophy_day := current_date;
  else
    new.trophy_day := old.trophy_day;
    new.trophy_gain := old.trophy_gain;
  end if;
  select count(*) - 1 into v_arena from unnest(array[0, 300, 800, 1500, 2500, 4000, 6000, 9000, 12000]) m where m <= new.trophies;
  new.arena_idx := least(coalesce(new.arena_idx, 0), v_arena);
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before insert or update on public.profiles for each row execute function public.profiles_guard();

-- ---------- заявки в друзья ----------
create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  from_id uuid not null references auth.users(id) on delete cascade,
  to_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending',       -- pending | accepted | declined
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (from_id, to_id),
  check (from_id <> to_id)
);
alter table public.friend_requests enable row level security;
drop policy if exists "requests mine" on public.friend_requests;
create policy "requests mine" on public.friend_requests for select to authenticated using (from_id = auth.uid() or to_id = auth.uid());

create or replace function public.friend_request(p_to uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_req uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if p_to = v_uid then raise exception 'Это ты'; end if;
  if exists (select 1 from public.friendships f where f.user_id = v_uid and f.friend_id = p_to)
     and exists (select 1 from public.friendships f where f.user_id = p_to and f.friend_id = v_uid) then return 'friends'; end if;
  select fr.id into v_req from public.friend_requests fr where fr.from_id = p_to and fr.to_id = v_uid and fr.status = 'pending';
  if v_req is not null then perform public.friend_respond(v_req, true); return 'accepted'; end if;
  insert into public.friend_requests as fr (from_id, to_id) values (v_uid, p_to)
    on conflict (from_id, to_id) do update set status = 'pending', created_at = now(), updated_at = now();
  return 'sent';
end $$;

create or replace function public.friend_respond(p_id uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_from uuid; v_to uuid;
begin
  select fr.from_id, fr.to_id into v_from, v_to from public.friend_requests fr where fr.id = p_id and fr.to_id = auth.uid() and fr.status = 'pending';
  if v_from is null then raise exception 'Заявка не найдена'; end if;
  update public.friend_requests fr set status = case when p_accept then 'accepted' else 'declined' end, updated_at = now() where fr.id = p_id;
  if p_accept then
    insert into public.friendships (user_id, friend_id) values (v_from, v_to), (v_to, v_from) on conflict do nothing;
  end if;
end $$;

create or replace function public.friend_remove(p_friend uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.friendships f where (f.user_id = auth.uid() and f.friend_id = p_friend) or (f.user_id = p_friend and f.friend_id = auth.uid());
  delete from public.friend_requests fr where (fr.from_id = auth.uid() and fr.to_id = p_friend) or (fr.from_id = p_friend and fr.to_id = auth.uid());
end $$;

grant execute on function public.friend_request(uuid), public.friend_respond(uuid, boolean), public.friend_remove(uuid) to authenticated;

-- ---------- лента рекордов ----------
create table if not exists public.feed (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null default 'pr',
  ex text not null,
  weight numeric not null,                       -- кг
  reps int not null default 1,
  created_at timestamptz not null default now()
);
create index if not exists feed_created_idx on public.feed(created_at desc);
alter table public.feed enable row level security;
drop policy if exists "feed read" on public.feed;
create policy "feed read" on public.feed for select to authenticated using (true);
drop policy if exists "feed insert own" on public.feed;
create policy "feed insert own" on public.feed for insert to authenticated
  with check (user_id = auth.uid() and weight > 0 and weight <= 600 and reps between 1 and 50 and length(ex) <= 60);
drop policy if exists "feed delete own" on public.feed;
create policy "feed delete own" on public.feed for delete to authenticated using (user_id = auth.uid());

-- ---------- общие настройки (если таблицы ещё нет) ----------
create table if not exists public.app_config (key text primary key, value text not null);
alter table public.app_config enable row level security;
drop policy if exists "config read" on public.app_config;
create policy "config read" on public.app_config for select to authenticated using (true);
-- Flexo League v23: просмотры видео, реферальные приглашения, весовые категории.
-- Запускать после update_v19.sql … update_v22.sql. Повторный запуск безопасен.

-- 1) Просмотры видео: один человек = один просмотр
alter table public.posts add column if not exists view_count int not null default 0;
create table if not exists public.post_views (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
alter table public.post_views enable row level security;
drop policy if exists post_views_own on public.post_views;
create policy post_views_own on public.post_views for select using (user_id = auth.uid());

create or replace function public.post_view(p_post uuid) returns int
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_n int;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  insert into post_views(post_id, user_id) values (p_post, v_uid) on conflict do nothing;
  if found then update posts set view_count = view_count + 1 where id = p_post returning view_count into v_n;
  else select view_count into v_n from posts where id = p_post; end if;
  return coalesce(v_n, 0);
end $$;
revoke all on function public.post_view(uuid) from public, anon;
grant execute on function public.post_view(uuid) to authenticated;

-- 2) Весовая категория (только категория, точный вес другим не виден)
alter table public.profiles add column if not exists weight_class text;

-- 3) Реферальные приглашения
create table if not exists public.referrals (
  referee uuid primary key references auth.users(id) on delete cascade,   -- кого пригласили (один раз)
  referrer uuid not null references auth.users(id) on delete cascade,     -- кто пригласил
  qualified boolean not null default false,                              -- приглашённый сделал 3 тренировки
  paid boolean not null default false,                                   -- пригласивший забрал бонус
  created_at timestamptz not null default now()
);
create index if not exists referrals_referrer_idx on public.referrals(referrer);
alter table public.referrals enable row level security;
drop policy if exists referrals_read on public.referrals;
create policy referrals_read on public.referrals for select using (referrer = auth.uid() or referee = auth.uid());

-- приглашённый вводит код друга (friend_code) в первые 7 дней после регистрации
create or replace function public.referral_claim(p_code text) returns text
language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid := auth.uid(); v_ref uuid; v_created timestamptz;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  select id into v_ref from profiles where upper(friend_code) = upper(trim(p_code));
  if v_ref is null then return 'not_found'; end if;
  if v_ref = v_uid then return 'self'; end if;
  if exists (select 1 from referrals where referee = v_uid) then return 'already'; end if;
  if exists (select 1 from referrals where referee = v_ref and referrer = v_uid) then return 'mutual'; end if;
  select created_at into v_created from auth.users where id = v_uid;
  if v_created < now() - interval '7 days' then return 'too_late'; end if;
  if (select count(*) from referrals where referrer = v_ref and created_at > now() - interval '1 day') >= 20 then return 'limit'; end if;
  insert into referrals(referee, referrer) values (v_uid, v_ref);
  return 'ok';
end $$;

-- приглашённый сделал 3 засчитанные тренировки
create or replace function public.referral_qualify() returns void
language sql security definer set search_path = public as $$
  update referrals set qualified = true where referee = auth.uid() and not qualified;
$$;

-- пригласивший забирает бонус (по одному разу за каждого друга)
create or replace function public.referral_collect() returns setof uuid
language sql security definer set search_path = public as $$
  update referrals set paid = true where referrer = auth.uid() and qualified and not paid returning referee;
$$;

revoke all on function public.referral_claim(text) from public, anon;
revoke all on function public.referral_qualify() from public, anon;
revoke all on function public.referral_collect() from public, anon;
grant execute on function public.referral_claim(text) to authenticated;
grant execute on function public.referral_qualify() to authenticated;
grant execute on function public.referral_collect() to authenticated;

-- Flexo League v24: лимиты ИИ (дневник еды 3 раза в день, активность 2 раза в день).
-- Запускать после update_v23.sql. Повторный запуск безопасен.

create table if not exists public.ai_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  kind text not null,          -- food | activity | misc
  n int not null default 0,
  primary key (user_id, day, kind)
);
alter table public.ai_usage enable row level security;
drop policy if exists ai_usage_read on public.ai_usage;
create policy ai_usage_read on public.ai_usage for select using (user_id = auth.uid());

create or replace function public.ai_limit(p_kind text) returns int language sql immutable as $$
  select case p_kind when 'food' then 3 when 'activity' then 2 else 60 end;
$$;

-- день берём с телефона (локальная дата), но не дальше суток от серверной
create or replace function public.ai_day(p_day date) returns date language sql stable as $$
  select case when p_day between (now() at time zone 'utc')::date - 1 and (now() at time zone 'utc')::date + 1 then p_day else (now() at time zone 'utc')::date end;
$$;

-- списать одну попытку; вернёт сколько осталось после списания или -1, если лимит исчерпан.
-- Вызывает только Edge Function (service_role), из приложения напрямую нельзя.
create or replace function public.ai_quota_use(p_user uuid, p_kind text, p_day date) returns int
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := p_user; v_day date := ai_day(p_day); v_n int;
begin
  if v_uid is null then raise exception 'no user'; end if;
  if p_kind not in ('food', 'activity', 'misc') then raise exception 'bad kind'; end if;
  insert into ai_usage(user_id, day, kind, n) values (v_uid, v_day, p_kind, 1)
    on conflict (user_id, day, kind) do update set n = ai_usage.n + 1 where ai_usage.n < ai_limit(p_kind)
    returning n into v_n;
  if v_n is null then return -1; end if;
  return ai_limit(p_kind) - v_n;
end $$;

-- вернуть попытку, если ИИ не ответил
create or replace function public.ai_quota_refund(p_user uuid, p_kind text, p_day date) returns void
language sql security definer set search_path = public as $$
  update ai_usage set n = greatest(0, n - 1) where user_id = p_user and day = ai_day(p_day) and kind = p_kind;
$$;

-- сколько осталось сегодня
create or replace function public.ai_quota_left(p_day date) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'food', ai_limit('food') - coalesce((select n from ai_usage where user_id = auth.uid() and day = ai_day(p_day) and kind = 'food'), 0),
    'activity', ai_limit('activity') - coalesce((select n from ai_usage where user_id = auth.uid() and day = ai_day(p_day) and kind = 'activity'), 0));
$$;

revoke all on function public.ai_quota_use(uuid, text, date) from public, anon, authenticated;
revoke all on function public.ai_quota_refund(uuid, text, date) from public, anon, authenticated;
grant execute on function public.ai_quota_use(uuid, text, date) to service_role;
grant execute on function public.ai_quota_refund(uuid, text, date) to service_role;
revoke all on function public.ai_quota_left(date) from public, anon;
grant execute on function public.ai_quota_left(date) to authenticated;

-- ключ Gemini больше не хранится в базе: теперь он только в секретах Edge Functions
do $$ begin
  if to_regclass('public.app_config') is not null then delete from public.app_config where key = 'gemini_key'; end if;
end $$;
