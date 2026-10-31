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
