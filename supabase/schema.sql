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

create or replace function public.clan_create(p_name text, p_emblem text) returns public.clans
language plpgsql security definer set search_path = public as $$
declare c public.clans; code text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if exists (select 1 from profiles where id = auth.uid() and clan_id is not null) then raise exception 'Ты уже в клане'; end if;
  if length(trim(p_name)) < 3 then raise exception 'Название от 3 символов'; end if;
  loop
    code := 'APEX' || lpad((floor(random() * 9000) + 1000)::int::text, 4, '0');
    exit when not exists (select 1 from clans where clans.code = code);
  end loop;
  insert into clans(name, emblem, code, leader_id) values (left(trim(p_name), 24), coalesce(nullif(p_emblem, ''), '🛡️'), code, auth.uid()) returning * into c;
  update profiles set clan_id = c.id, clan_role = 'leader', updated_at = now() where id = auth.uid();
  return c;
end $$;

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

grant execute on function public.clan_create(text, text), public.clan_join(text), public.clan_leave(), public.clan_set_role(uuid, text), public.clan_kick(uuid), public.random_opponent(int, text) to authenticated;

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
