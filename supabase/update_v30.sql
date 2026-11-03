-- =====================================================================
-- Flexo League v30: админ-панель и модерация (анти-чит, жалобы, баны)
-- Запусти один раз в Supabase → SQL Editor (после update_v27.sql).
-- Можно запускать повторно: всё через if not exists / create or replace.
--
-- ПОСЛЕ ЗАПУСКА сделай себя админом (подставь свой email, с которым входишь в приложение):
--   insert into public.admins(user_id, role) select id, 'owner' from auth.users where email = 'ТВОЙ_EMAIL'
--   on conflict (user_id) do update set role = 'owner';
-- Админка: https://luchik129.github.io/apex-arena/admin/
-- =====================================================================

-- ---------- 1. Таблицы ----------
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'moderator',            -- owner | moderator
  added_at timestamptz not null default now()
);

create table if not exists public.bans (
  user_id uuid primary key references auth.users(id) on delete cascade,
  until timestamptz,                                 -- null = навсегда
  reason text not null default '',
  by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.player_flags (
  user_id uuid primary key references auth.users(id) on delete cascade,
  trusted boolean not null default false,            -- проверенный атлет: подходы не уходят на проверку
  strikes int not null default 0,                    -- сколько раз отклоняли результаты
  note text not null default '',                     -- заметка админа
  updated_at timestamptz not null default now()
);

create table if not exists public.lift_reviews (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  lift_id text not null,                             -- id подхода в приложении, или srv:/scan: для найденных сервером
  ex text not null,
  weight numeric, reps int, e1rm numeric not null,
  bodyweight numeric, prev_best numeric, ratio numeric,
  lift_date date,
  reasons text[] not null default '{}',              -- ratio | jump | record
  source text not null default 'app',                -- app | server | scan
  status text not null default 'pending',            -- pending | approved | rejected
  note text,
  seen boolean not null default false,               -- игрок получил решение
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references auth.users(id) on delete set null,
  unique (user_id, lift_id)
);
create index if not exists lift_reviews_status_idx on public.lift_reviews(status, created_at desc);
create index if not exists lift_reviews_user_idx on public.lift_reviews(user_id, ex);

create table if not exists public.adjustments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,                                -- trophies | coins | reset_ex
  mode text not null default 'delta',                -- delta | set
  amount numeric not null default 0,
  ex text,
  note text not null default '',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  applied_at timestamptz                             -- когда приложение игрока применило
);
create index if not exists adjustments_user_idx on public.adjustments(user_id) where applied_at is null;

create table if not exists public.admin_log (
  id bigserial primary key,
  admin_id uuid references auth.users(id) on delete set null,
  action text not null,
  target_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists admin_log_created_idx on public.admin_log(created_at desc);

alter table public.reports add column if not exists resolved_at timestamptz;
alter table public.reports add column if not exists resolved_by uuid;
alter table public.reports add column if not exists resolution text;
create index if not exists reports_target_idx on public.reports(target_id);

alter table public.admins enable row level security;
alter table public.bans enable row level security;
alter table public.player_flags enable row level security;
alter table public.lift_reviews enable row level security;
alter table public.adjustments enable row level security;
alter table public.admin_log enable row level security;
-- игрок видит только свои проверки; всё остальное читается и меняется только через функции ниже
drop policy if exists lift_reviews_own on public.lift_reviews;
create policy lift_reviews_own on public.lift_reviews for select to authenticated using (user_id = auth.uid());

-- ---------- 2. Правила анти-чита (меняются в админке → Настройки) ----------
insert into public.app_config(key, value) values ('anticheat', '{
  "enabled": true,
  "ratio": {"Bench Press": 2.0, "Incline Bench": 1.8, "Overhead Press": 1.4, "Squat": 2.7, "Deadlift": 3.0,
            "Romanian Deadlift": 2.6, "Barbell Row": 1.8, "Pull-ups": 2.2, "Dips": 2.4, "Leg Press": 6.0,
            "Lunges": 2.0, "Hip Thrust": 4.0, "Bicep Curl": 1.0, "Lateral Raise": 0.6, "Calf Raise": 4.0,
            "bench": 2.0, "squat": 2.7, "deadlift": 3.0, "other": 3.0},
  "record": {"bench": 355, "squat": 490, "deadlift": 505},
  "female": 0.72,
  "jump": 0.15,
  "min_kg": 60
}') on conflict (key) do nothing;

create or replace function public.flx_rules() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select value::jsonb from app_config where key = 'anticheat'), '{"enabled":false}'::jsonb);
$$;

-- ---------- 3. Вспомогательные функции ----------
create or replace function public.flx_is_admin(p_uid uuid default auth.uid()) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = p_uid);
$$;

-- проверка в начале каждой админ-функции; заодно разрешает менять защищённые поля профиля
create or replace function public.flx_admin() returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not exists (select 1 from admins where user_id = auth.uid()) then
    raise exception 'forbidden: нет прав администратора' using errcode = '42501';
  end if;
  perform set_config('flx.admin', '1', true);
  return auth.uid();
end $$;

create or replace function public.flx_banned(p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from bans where user_id = p_uid and (until is null or until > now()));
$$;

create or replace function public.flx_log(p_action text, p_target uuid, p_details jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = public as $$
  insert into admin_log(admin_id, action, target_id, details) values (auth.uid(), p_action, p_target, coalesce(p_details, '{}'::jsonb));
$$;

-- вес тела игрока (из его резервной копии)
create or replace function public.flx_bw(p_uid uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select nullif(regexp_replace(coalesce(data #>> '{profile,bodyweight}', ''), '[^0-9.]', '', 'g'), '')::numeric from app_state where user_id = p_uid
    and (auth.uid() is null or auth.uid() = p_uid or exists (select 1 from admins where user_id = auth.uid()));
$$;

-- тип упражнения: bench / squat / deadlift / other (свои упражнения берут «босса» из настроек игрока)
create or replace function public.flx_ex_kind(p_uid uuid, p_ex text) returns text
language sql stable security definer set search_path = public as $$
  select case p_ex when 'Bench Press' then 'bench' when 'Squat' then 'squat' when 'Deadlift' then 'deadlift'
    else coalesce((select nullif(c ->> 'boss', '') from app_state s, jsonb_array_elements(case when jsonb_typeof(s.data -> 'customExercises') = 'array' then s.data -> 'customExercises' else '[]'::jsonb end) c
                   where s.user_id = p_uid and c ->> 'name' = p_ex limit 1), 'other') end;
$$;

-- почему подход подозрительный: ratio (тяжелее N× веса тела), jump (скачок от прошлого рекорда), record (выше мирового рекорда)
create or replace function public.flx_lift_reasons(p_uid uuid, p_ex text, p_e1rm numeric, p_prev numeric, p_bw numeric) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare r jsonb := flx_rules(); k text; lim numeric; out text[] := '{}'; v_sex text;
begin
  if not coalesce((r ->> 'enabled')::boolean, false) or p_e1rm is null then return out; end if;
  k := flx_ex_kind(p_uid, p_ex);
  if (r -> 'record' ->> k) is not null and p_e1rm > (r -> 'record' ->> k)::numeric then out := array_append(out, 'record'); end if;
  if p_e1rm < coalesce((r ->> 'min_kg')::numeric, 60) then return out; end if;
  select sex into v_sex from profiles where id = p_uid;
  lim := coalesce((r -> 'ratio' ->> p_ex)::numeric, (r -> 'ratio' ->> k)::numeric, (r -> 'ratio' ->> 'other')::numeric, 3);
  if v_sex = 'f' then lim := lim * coalesce((r ->> 'female')::numeric, 0.72); end if;
  if coalesce(p_bw, 0) > 0 and p_e1rm > p_bw * lim then out := array_append(out, 'ratio'); end if;
  if coalesce(p_prev, 0) > 0 and p_e1rm > p_prev * (1 + coalesce((r ->> 'jump')::numeric, 0.15)) then out := array_append(out, 'jump'); end if;
  return out;
end $$;

create or replace function public.flx_approved_max(p_uid uuid, p_ex text) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(max(e1rm), 0) from lift_reviews where user_id = p_uid and ex = p_ex and status = 'approved';
$$;

create or replace function public.flx_trusted(p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select trusted from player_flags where user_id = p_uid), false);
$$;

-- сервер сам нашёл подозрительный рекорд в профиле (например, взломанное или старое приложение)
create or replace function public.flx_review_auto(p_uid uuid, p_ex text, p_e1rm numeric, p_prev numeric, p_bw numeric, p_reasons text[], p_source text default 'server') returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and auth.uid() <> p_uid and not exists (select 1 from admins where user_id = auth.uid()) then return; end if;
  if exists (select 1 from lift_reviews where user_id = p_uid and ex = p_ex and status = 'pending') then return; end if;
  if exists (select 1 from lift_reviews where user_id = p_uid and ex = p_ex and status = 'rejected' and e1rm <= p_e1rm + 1) then return; end if;
  insert into lift_reviews(user_id, lift_id, ex, e1rm, bodyweight, prev_best, ratio, reasons, source, lift_date)
  values (p_uid, (case when p_source = 'scan' then 'scan:' else 'srv:' end) || p_ex || ':' || round(p_e1rm)::text, p_ex, round(p_e1rm, 1), p_bw, nullif(p_prev, 0),
          case when coalesce(p_bw, 0) > 0 then round(p_e1rm / p_bw, 2) end, p_reasons, p_source, current_date)
  on conflict (user_id, lift_id) do nothing;
end $$;

create or replace function public.flx_adj_pending(p_uid uuid, p_kind text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from adjustments where user_id = p_uid and kind = p_kind and applied_at is null);
$$;

-- ---------- 4. Защита профиля: подозрительные рекорды не попадают в рейтинги до проверки ----------
create or replace function public.profiles_guard()
returns trigger language plpgsql set search_path = public as $$
declare
  v_caps jsonb := '{"bench":355,"squat":490,"deadlift":505}';
  v_gain int; v_arena int; v_days jsonb := '{}'::jsonb; k text; v jsonb;
  v_client boolean := current_user in ('authenticated', 'anon'); -- прямой запрос из приложения (не функция сервера)
  v_old_bests jsonb; v_bw numeric; v_val numeric; v_prev numeric; v_why text[]; v_held text[] := '{}'; v_kind text;
begin
  if current_setting('flx.admin', true) = '1' then return new; end if; -- правка из админки
  if auth.uid() is null and not v_client then return new; end if;
  -- текст: мат в нике и титуле
  perform public.flx_check(new.nickname, new.title);
  if new.nickname is not null and length(trim(new.nickname)) not between 2 and 16 then raise exception 'Ник от 2 до 16 символов'; end if;
  if new.title is not null then new.title := left(new.title, 24); end if;

  new.bests := coalesce((select jsonb_object_agg(b.key, least(b.value::numeric, 600)) from jsonb_each_text(coalesce(new.bests, '{}'::jsonb)) b where b.value ~ '^[0-9]+(\.[0-9]+)?$'), '{}'::jsonb);
  new.boss := coalesce((select jsonb_object_agg(b.key, least(b.value::numeric, coalesce((v_caps ->> b.key)::numeric, 600))) from jsonb_each_text(coalesce(new.boss, '{}'::jsonb)) b where b.value ~ '^[0-9]+(\.[0-9]+)?$'), '{}'::jsonb);

  -- v30: рост рекорда выше правил анти-чита держим на старом значении и отправляем на проверку
  if not public.flx_trusted(new.id) then
    v_old_bests := case when tg_op = 'UPDATE' then coalesce(old.bests, '{}'::jsonb) else '{}'::jsonb end;
    v_bw := public.flx_bw(new.id);
    for k, v in select key, value from jsonb_each(new.bests) loop
      v_val := (v #>> '{}')::numeric; v_prev := coalesce((v_old_bests ->> k)::numeric, 0);
      continue when v_val <= v_prev + 0.5;
      continue when v_val <= public.flx_approved_max(new.id, k) + 1;
      v_why := public.flx_lift_reasons(new.id, k, v_val, v_prev, v_bw);
      continue when coalesce(array_length(v_why, 1), 0) = 0;
      if v_prev > 0 then new.bests := jsonb_set(new.bests, array[k], to_jsonb(v_prev)); else new.bests := new.bests - k; end if;
      perform public.flx_review_auto(new.id, k, v_val, v_prev, v_bw, v_why, 'server');
      v_kind := public.flx_ex_kind(new.id, k); if v_kind <> 'other' then v_held := array_append(v_held, v_kind); end if;
    end loop;
    foreach v_kind in array v_held loop
      continue when not new.boss ? v_kind;
      new.boss := jsonb_set(new.boss, array[v_kind], to_jsonb(least(coalesce((new.boss ->> v_kind)::numeric, 0),
        greatest(case when tg_op = 'UPDATE' then coalesce((old.boss ->> v_kind)::numeric, 0) else 0 end, public.flx_approved_max(new.id, case v_kind when 'bench' then 'Bench Press' when 'squat' then 'Squat' else 'Deadlift' end)))));
    end loop;
  end if;

  if new.avatar is not null and length(new.avatar) > 40000 then new.avatar := null; end if;
  new.level := least(greatest(coalesce(new.level, 1), 1), 300);
  new.power_score := least(greatest(coalesce(new.power_score, 0), 0), 100000);

  -- клан и код друга меняются только через функции сервера (clan_new / clan_join / clan_leave / clan_kick / clan_set_role)
  if v_client then
    if tg_op = 'INSERT' then new.clan_id := null; new.clan_role := 'member';
    else new.clan_id := old.clan_id; new.clan_role := old.clan_role; new.friend_code := coalesce(old.friend_code, new.friend_code);
    end if;
  end if;

  -- дни для дуэлей и битв кланов: добавлять можно только сегодня/вчера (по UTC ±1), прошлое не переписать
  for k, v in select key, value from jsonb_each(case when jsonb_typeof(new.days) = 'object' then new.days else '{}'::jsonb end) loop
    continue when k !~ '^\d{4}-\d{2}-\d{2}$';
    continue when k::date < current_date - 40 or k::date > current_date + 1;
    if tg_op = 'UPDATE' and k::date < current_date - 2 then
      if old.days ? k then v_days := v_days || jsonb_build_object(k, old.days -> k); end if;
      continue;
    end if;
    if tg_op = 'INSERT' and k::date < current_date - 2 then continue; end if;
    v_days := v_days || jsonb_build_object(k, jsonb_build_object(
      'w', case when coalesce((v ->> 'w'), '0') ~ '^[1-9]' then 1 else 0 end,
      'p', least(greatest(coalesce(nullif(regexp_replace(coalesce(v ->> 'p', '0'), '[^0-9]', '', 'g'), '')::int, 0), 0), 3)));
  end loop;
  if tg_op = 'UPDATE' and jsonb_typeof(old.days) = 'object' then -- старые дни, которые клиент «забыл», сохраняем
    for k, v in select key, value from jsonb_each(old.days) loop
      if k ~ '^\d{4}-\d{2}-\d{2}$' and k::date >= current_date - 40 and k::date < current_date - 2 and not v_days ? k then v_days := v_days || jsonb_build_object(k, v); end if;
    end loop;
  end if;
  new.days := v_days;
  new.week := public.flx_week(new.week); new.prev_week := public.flx_week(new.prev_week);

  -- кубки: не больше 150 в день (честный максимум около 130)
  if tg_op = 'INSERT' then
    new.trophies := least(greatest(coalesce(new.trophies, 0), 0), 100);
    new.trophy_day := current_date;
    new.trophy_gain := new.trophies;
  elsif new.trophies > old.trophies and public.flx_adj_pending(new.id, 'trophies') then
    -- v30: админ поменял кубки, а приложение игрока ещё не получило правку: старое значение не возвращаем
    new.trophies := old.trophies; new.trophy_day := old.trophy_day; new.trophy_gain := old.trophy_gain;
  elsif new.trophies > old.trophies then
    v_gain := case when old.trophy_day = current_date then coalesce(old.trophy_gain, 0) else 0 end;
    new.trophies := least(new.trophies, old.trophies + greatest(0, 150 - v_gain));
    new.trophy_gain := v_gain + (new.trophies - old.trophies);
    new.trophy_day := current_date;
  else
    new.trophy_day := old.trophy_day;
    new.trophy_gain := old.trophy_gain;
  end if;
  select count(*) - 1 into v_arena from unnest(array[0, 300, 800, 1500, 2500, 4000, 6000, 9000, 12000, 14000, 16500, 19000, 22000, 25000, 28500, 32000, 36000]) m where m <= new.trophies;
  new.arena_idx := least(greatest(coalesce(new.arena_idx, 0), 0), v_arena);
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before insert or update on public.profiles for each row execute function public.profiles_guard();

-- ---------- 5. Бан: забаненный не пишет посты/комментарии/жалобы/дуэли и не виден другим ----------
create or replace function public.flx_ban_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if current_setting('flx.admin', true) = '1' then return new; end if;
  if auth.uid() is not null and public.flx_banned(auth.uid()) then
    raise exception 'flx_banned: аккаунт заблокирован модератором' using errcode = '42501';
  end if;
  return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['posts', 'post_comments', 'post_likes', 'feed', 'reports', 'duels', 'friend_requests', 'friendships'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists %I on public.%I', t || '_ban_guard', t);
      execute format('create trigger %I before insert on public.%I for each row execute function public.flx_ban_guard()', t || '_ban_guard', t);
    end if;
  end loop;
end $$;

drop policy if exists "profiles read" on public.profiles;
create policy "profiles read" on public.profiles for select to authenticated using (id = auth.uid() or not public.flx_banned(id));
drop policy if exists "posts read" on public.posts;
create policy "posts read" on public.posts for select to authenticated using (user_id = auth.uid() or (not hidden and not public.flx_banned(user_id)));
drop policy if exists "comments read" on public.post_comments;
create policy "comments read" on public.post_comments for select to authenticated using (user_id = auth.uid() or (not hidden and not public.flx_banned(user_id)));
drop policy if exists "feed read" on public.feed;
create policy "feed read" on public.feed for select to authenticated using (user_id = auth.uid() or not public.flx_banned(user_id));

-- случайный соперник: без забаненных
create or replace function public.random_opponent(p_arena int, p_week text) returns setof public.profiles
language sql security definer set search_path = public as $$
  select * from profiles p
  where p.id <> auth.uid()
    and p.battle_open
    and not public.flx_banned(p.id)
    and abs(p.arena_idx - p_arena) <= 2
    and not exists (select 1 from duels d where d.week_key = p_week and d.status = 'active' and ((d.a_id = auth.uid() and d.b_id = p.id) or (d.b_id = auth.uid() and d.a_id = p.id)))
  order by abs(p.arena_idx - p_arena), random() limit 1;
$$;

-- ---------- 6. Функции для приложения игрока ----------
-- приложение отправляет подозрительный подход на проверку; сервер сам решает, нужна ли проверка
create or replace function public.lift_review_submit(p_lift_id text, p_ex text, p_weight numeric, p_reps int, p_e1rm numeric, p_bw numeric, p_date date) returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_row lift_reviews; v_prev numeric; v_bw numeric; v_why text[]; v_ok boolean;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if flx_banned(v_uid) then return 'banned'; end if;
  if p_lift_id is null or length(p_lift_id) > 40 or p_ex is null or length(p_ex) > 60 or coalesce(p_e1rm, 0) <= 0 or p_e1rm > 1000 then raise exception 'bad lift'; end if;
  select * into v_row from lift_reviews where user_id = v_uid and lift_id = p_lift_id;
  if found then return v_row.status; end if;
  if (select count(*) from lift_reviews where user_id = v_uid and status = 'pending') >= 20 then return 'limit'; end if;
  select (bests ->> p_ex)::numeric into v_prev from profiles where id = v_uid;
  v_bw := coalesce(nullif(p_bw, 0), flx_bw(v_uid));
  v_why := flx_lift_reasons(v_uid, p_ex, p_e1rm, v_prev, v_bw);
  -- v31: приложение отправляет только помеченные подходы, поэтому без пометки сервера они тоже ждут модератора
  if coalesce(array_length(v_why, 1), 0) = 0 then v_why := array['jump']; end if;
  v_ok := flx_trusted(v_uid);
  insert into lift_reviews(user_id, lift_id, ex, weight, reps, e1rm, bodyweight, prev_best, ratio, lift_date, reasons, source, status, note, decided_at, seen)
  values (v_uid, p_lift_id, p_ex, p_weight, p_reps, round(p_e1rm, 1), v_bw, v_prev, case when coalesce(v_bw, 0) > 0 then round(p_e1rm / v_bw, 2) end,
          case when p_date between current_date - 30 and current_date + 1 then p_date else current_date end, v_why, 'app',
          case when v_ok then 'approved' else 'pending' end, case when v_ok then 'Проверенный атлет' end, case when v_ok then now() end, v_ok)
  returning * into v_row;
  return v_row.status;
end $$;

-- приложение забирает решения модератора, бан и правки кубков/монет (каждая правка выдаётся один раз)
create or replace function public.my_moderation() returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_ban json; v_rev json; v_adj json;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  select json_build_object('until', until, 'reason', reason, 'at', created_at) into v_ban from bans where user_id = v_uid and (until is null or until > now());
  with x as (update lift_reviews set seen = true where user_id = v_uid and status <> 'pending' and not seen
             returning lift_id, ex, e1rm, status, note, source)
  select coalesce(json_agg(x), '[]'::json) into v_rev from x;
  with a as (update adjustments set applied_at = now() where user_id = v_uid and applied_at is null
             returning id, kind, mode, amount, ex, note, created_at)
  select coalesce(json_agg(a order by a.created_at), '[]'::json) into v_adj from a;
  return json_build_object('ban', v_ban, 'reviews', v_rev, 'adjustments', v_adj, 'trusted', flx_trusted(v_uid),
    'pending', (select coalesce(json_agg(lift_id), '[]'::json) from lift_reviews where user_id = v_uid and status = 'pending'));
end $$;

-- ---------- 7. Админ-функции ----------
create or replace function public.admin_me() returns json
language sql stable security definer set search_path = public, auth as $$
  select json_build_object('uid', auth.uid(), 'is_admin', flx_is_admin(), 'role', (select role from admins where user_id = auth.uid()),
    'email', (select email from auth.users where id = auth.uid()), 'nick', (select nickname from profiles where id = auth.uid()));
$$;

create or replace function public.admin_stats() returns json
language plpgsql security definer set search_path = public, auth as $$
begin
  perform flx_admin();
  return json_build_object(
    'players', (select count(*) from profiles),
    'new_today', (select count(*) from auth.users where created_at > now() - interval '1 day'),
    'new_week', (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'active_today', (select count(*) from profiles where updated_at > now() - interval '1 day'),
    'active_week', (select count(*) from profiles where updated_at > now() - interval '7 days'),
    'banned', (select count(*) from bans where until is null or until > now()),
    'pending_reviews', (select count(*) from lift_reviews where status = 'pending'),
    'new_reports', (select count(distinct target_id) from reports where status = 'new'),
    'reports_today', (select count(*) from reports where created_at > now() - interval '1 day'),
    'posts_today', (select count(*) from posts where created_at > now() - interval '1 day'),
    'hidden_posts', (select count(*) from posts where hidden),
    'approved_week', (select count(*) from lift_reviews where status = 'approved' and decided_at > now() - interval '7 days' and decided_by is not null),
    'rejected_week', (select count(*) from lift_reviews where status = 'rejected' and decided_at > now() - interval '7 days'),
    'signups', (select json_agg(json_build_object('d', d::date, 'n', (select count(*) from auth.users u where u.created_at::date = d::date)) order by d)
                from generate_series((current_date - 13)::timestamp, current_date::timestamp, interval '1 day') d),
    'active', (select json_agg(json_build_object('d', d::date, 'n', (select count(*) from profiles p where p.days ? to_char(d, 'YYYY-MM-DD'))) order by d)
               from generate_series((current_date - 13)::timestamp, current_date::timestamp, interval '1 day') d)
  );
end $$;

-- очередь проверки подходов
create or replace function public.admin_reviews(p_status text default 'pending', p_limit int default 100) returns json
language plpgsql security definer set search_path = public, auth as $$
begin
  perform flx_admin();
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select r.*, p.nickname, p.avatar, p.sex, p.trophies, p.arena_idx, p.bests,
      u.email, u.created_at as account_created,
      flx_trusted(r.user_id) as trusted, flx_banned(r.user_id) as banned,
      (select strikes from player_flags f where f.user_id = r.user_id) as strikes,
      (select count(*) from lift_reviews z where z.user_id = r.user_id and z.status = 'rejected') as rejected_total,
      (select count(*) from reports z where z.target_id = r.user_id) as reports_total,
      (select nickname from profiles a where a.id = r.decided_by) as decided_nick,
      flx_ex_kind(r.user_id, r.ex) as kind,
      -- история этого упражнения из приложения игрока (последние 12 подходов)
      (select coalesce(json_agg(h order by h.ts desc), '[]'::json) from (
         select l ->> 'date' as date, (l ->> 'weight')::numeric as weight, (l ->> 'reps')::int as reps, (l ->> 'e1rm')::numeric as e1rm, (l ->> 'ts')::bigint as ts, l ->> 'id' as id, coalesce((l ->> 'flagged')::boolean, false) as flagged
         from app_state s, jsonb_array_elements(case when jsonb_typeof(s.data -> 'lifts') = 'array' then s.data -> 'lifts' else '[]'::jsonb end) l
         where s.user_id = r.user_id and l ->> 'exerciseName' = r.ex order by (l ->> 'ts')::bigint desc nulls last limit 12) h) as history
    from lift_reviews r left join profiles p on p.id = r.user_id left join auth.users u on u.id = r.user_id
    where (p_status = 'all' or r.status = p_status)
    order by r.created_at desc limit least(greatest(p_limit, 1), 300)) x), '[]'::json);
end $$;

create or replace function public.admin_review_decide(p_id uuid, p_approve boolean, p_note text default null) returns json
language plpgsql security definer set search_path = public as $$
declare v_admin uuid := flx_admin(); r lift_reviews; v_kind text; v_best numeric;
begin
  select * into r from lift_reviews where id = p_id for update;
  if not found then raise exception 'Проверка не найдена'; end if;
  update lift_reviews set status = case when p_approve then 'approved' else 'rejected' end, note = nullif(trim(coalesce(p_note, '')), ''),
    decided_at = now(), decided_by = v_admin, seen = false where id = p_id;
  v_kind := flx_ex_kind(r.user_id, r.ex);
  if p_approve then
    -- рекорд сразу появляется в рейтингах
    update profiles set bests = jsonb_set(coalesce(bests, '{}'::jsonb), array[r.ex], to_jsonb(greatest(coalesce((bests ->> r.ex)::numeric, 0), round(r.e1rm)))),
      boss = case when v_kind in ('bench', 'squat', 'deadlift') then jsonb_set(coalesce(boss, '{}'::jsonb), array[v_kind], to_jsonb(greatest(coalesce((boss ->> v_kind)::numeric, 0), round(r.e1rm)))) else boss end
      where id = r.user_id;
  else
    insert into player_flags(user_id, strikes) values (r.user_id, 1) on conflict (user_id) do update set strikes = player_flags.strikes + 1, updated_at = now();
    -- если такой рекорд уже был в профиле, откатываем его
    select (bests ->> r.ex)::numeric into v_best from profiles where id = r.user_id;
    if v_best is not null and v_best >= r.e1rm - 1 then
      update profiles set bests = case when coalesce(r.prev_best, 0) > 0 and r.prev_best < r.e1rm then jsonb_set(bests, array[r.ex], to_jsonb(round(r.prev_best))) else bests - r.ex end,
        boss = case when v_kind in ('bench', 'squat', 'deadlift') and coalesce((boss ->> v_kind)::numeric, 0) >= r.e1rm - 1 then jsonb_set(boss, array[v_kind], to_jsonb(round(coalesce(r.prev_best, 0)))) else boss end
        where id = r.user_id;
    end if;
  end if;
  perform flx_log(case when p_approve then 'review_approve' else 'review_reject' end, r.user_id, json_build_object('ex', r.ex, 'e1rm', r.e1rm, 'note', p_note)::jsonb);
  return json_build_object('ok', true);
end $$;

-- найти подозрительные рекорды, которые уже есть в базе (до появления проверки)
create or replace function public.admin_scan() returns int
language plpgsql security definer set search_path = public as $$
declare p record; k text; v text; v_bw numeric; v_why text[]; n int := 0; before int;
begin
  perform flx_admin();
  select count(*) into before from lift_reviews where status = 'pending';
  for p in select id, bests from profiles where not flx_trusted(id) loop
    v_bw := flx_bw(p.id);
    for k, v in select key, value from jsonb_each_text(coalesce(p.bests, '{}'::jsonb)) loop
      continue when v !~ '^[0-9]+(\.[0-9]+)?$';
      continue when v::numeric <= flx_approved_max(p.id, k) + 1;
      v_why := flx_lift_reasons(p.id, k, v::numeric, 0, v_bw);
      continue when coalesce(array_length(v_why, 1), 0) = 0;
      perform flx_review_auto(p.id, k, v::numeric, 0, v_bw, v_why, 'scan');
    end loop;
  end loop;
  select count(*) - before into n from lift_reviews where status = 'pending';
  perform flx_log('scan', null, json_build_object('found', n)::jsonb);
  return n;
end $$;

-- жалобы, сгруппированные по цели
create or replace function public.admin_reports(p_status text default 'new', p_limit int default 60) returns json
language plpgsql security definer set search_path = public, auth as $$
begin
  perform flx_admin();
  return coalesce((select json_agg(g order by g.last_at desc) from (
    select r.target_id, r.target_kind, count(*) as n, max(r.created_at) as last_at, min(r.created_at) as first_at,
      bool_or(r.status = 'new') as open, max(r.resolution) as resolution,
      json_agg(json_build_object('reason', r.reason, 'note', r.note, 'at', r.created_at, 'status', r.status, 'reporter', r.reporter_id,
        'reporter_nick', (select nickname from profiles x where x.id = r.reporter_id)) order by r.created_at desc) as items,
      case r.target_kind
        when 'post' then (select json_build_object('id', po.id, 'author', po.user_id, 'author_nick', pr.nickname, 'body', po.body, 'kind', po.kind, 'photo', po.photo, 'video', po.video,
                            'ex', po.ex, 'weight', po.weight, 'reps', po.reps, 'hidden', po.hidden, 'likes', po.like_count, 'created_at', po.created_at)
                          from posts po left join profiles pr on pr.id = po.user_id where po.id = r.target_id)
        when 'comment' then (select json_build_object('id', c.id, 'author', c.user_id, 'author_nick', pr.nickname, 'body', c.body, 'post_id', c.post_id, 'hidden', c.hidden, 'created_at', c.created_at)
                          from post_comments c left join profiles pr on pr.id = c.user_id where c.id = r.target_id)
        else (select json_build_object('id', pr.id, 'author', pr.id, 'author_nick', pr.nickname, 'avatar', pr.avatar, 'trophies', pr.trophies, 'title', pr.title, 'bests', pr.bests)
              from profiles pr where pr.id = r.target_id)
      end as target
    from reports r
    group by r.target_id, r.target_kind
    having (p_status = 'all') or (p_status = 'new' and bool_or(r.status = 'new')) or (p_status = 'closed' and not bool_or(r.status = 'new'))
    order by max(r.created_at) desc limit least(greatest(p_limit, 1), 200)) g), '[]'::json);
end $$;

-- закрыть жалобы на цель: dismiss (жалобы ложные, вернуть скрытое) | ok (принято к сведению) | hide | delete
create or replace function public.admin_report_resolve(p_target uuid, p_action text, p_note text default null) returns json
language plpgsql security definer set search_path = public as $$
declare v_admin uuid := flx_admin(); v_kind text;
begin
  select target_kind into v_kind from reports where target_id = p_target limit 1;
  if p_action not in ('dismiss', 'ok', 'hide', 'delete') then raise exception 'bad action'; end if;
  if v_kind = 'post' then
    if p_action = 'hide' then update posts set hidden = true where id = p_target;
    elsif p_action = 'delete' then delete from posts where id = p_target;
    elsif p_action = 'dismiss' then update posts set hidden = false where id = p_target; end if;
  elsif v_kind = 'comment' then
    if p_action = 'hide' then update post_comments set hidden = true where id = p_target;
    elsif p_action = 'delete' then delete from post_comments where id = p_target;
    elsif p_action = 'dismiss' then update post_comments set hidden = false where id = p_target; end if;
  end if;
  update reports set status = case when p_action = 'dismiss' then 'dismissed' else 'resolved' end, resolution = p_action || coalesce(': ' || nullif(trim(p_note), ''), ''),
    resolved_at = now(), resolved_by = v_admin where target_id = p_target and status = 'new';
  perform flx_log('report_' || p_action, p_target, json_build_object('kind', v_kind, 'note', p_note)::jsonb);
  return json_build_object('ok', true);
end $$;

-- список игроков: поиск по нику/email/id, фильтры
create or replace function public.admin_players(p_q text default '', p_filter text default 'all', p_limit int default 50, p_offset int default 0) returns json
language plpgsql security definer set search_path = public, auth as $$
declare q text := lower(trim(coalesce(p_q, '')));
begin
  perform flx_admin();
  return coalesce((select json_agg(x) from (
    select p.id, p.nickname, p.avatar, p.sex, p.trophies, p.arena_idx, p.level, p.bests, p.updated_at, p.clan_id,
      u.email, u.created_at, u.last_sign_in_at,
      (s.data #>> '{game,coins}')::numeric as coins, flx_bw(p.id) as bodyweight,
      flx_banned(p.id) as banned, flx_trusted(p.id) as trusted, exists (select 1 from admins a where a.user_id = p.id) as is_admin,
      (select count(*) from reports r where r.target_id = p.id and r.status = 'new') as open_reports,
      (select count(*) from lift_reviews r where r.user_id = p.id and r.status = 'pending') as pending_reviews,
      (select strikes from player_flags f where f.user_id = p.id) as strikes,
      -- самый подозрительный рекорд: во сколько раз тяжелее веса тела
      (select max(round((b.value::numeric / nullif(flx_bw(p.id), 0)), 2)) from jsonb_each_text(coalesce(p.bests, '{}'::jsonb)) b
        where b.key in ('Bench Press', 'Squat', 'Deadlift') and b.value ~ '^[0-9]+(\.[0-9]+)?$') as max_ratio
    from profiles p left join auth.users u on u.id = p.id left join app_state s on s.user_id = p.id
    where (q = '' or lower(p.nickname::text) like '%' || q || '%' or lower(coalesce(u.email, '')) like '%' || q || '%' or p.id::text = q or upper(p.friend_code) = upper(q))
      and case p_filter
        when 'banned' then flx_banned(p.id)
        when 'trusted' then flx_trusted(p.id)
        when 'new' then u.created_at > now() - interval '7 days'
        when 'reported' then exists (select 1 from reports r where r.target_id = p.id)
        when 'suspicious' then exists (select 1 from lift_reviews r where r.user_id = p.id and r.status in ('pending', 'rejected'))
        else true end
    order by case when p_filter = 'new' then extract(epoch from u.created_at) else p.trophies end desc nulls last
    limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) x), '[]'::json);
end $$;

-- карточка игрока
create or replace function public.admin_player(p_id uuid) returns json
language plpgsql security definer set search_path = public, auth as $$
declare s jsonb;
begin
  perform flx_admin();
  select data into s from app_state where user_id = p_id;
  return json_build_object(
    'profile', (select to_jsonb(p) from profiles p where p.id = p_id),
    'auth', (select json_build_object('email', u.email, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at, 'provider', u.raw_app_meta_data ->> 'provider', 'confirmed', u.email_confirmed_at is not null) from auth.users u where u.id = p_id),
    'clan', (select json_build_object('id', c.id, 'name', c.name, 'role', p.clan_role) from profiles p join clans c on c.id = p.clan_id where p.id = p_id),
    'state', case when s is null then null else jsonb_build_object(
      'game', jsonb_build_object('trophies', s #> '{game,trophies}', 'coins', s #> '{game,coins}', 'xp', s #> '{game,xp}', 'arenaIdx', s #> '{game,arenaIdx}', 'lastWorkoutDay', s #> '{game,lastWorkoutDay}', 'workouts', jsonb_array_length(coalesce(s #> '{game,countedWorkoutDays}', '[]'::jsonb))),
      'profile', jsonb_build_object('bodyweight', s #> '{profile,bodyweight}', 'height', s #> '{profile,height}', 'age', s #> '{profile,age}', 'sex', s #> '{profile,sex}', 'units', s #> '{profile,units}', 'lang', s #> '{profile,lang}'),
      'weights', (select coalesce(jsonb_agg(w order by w ->> 'date' desc), '[]'::jsonb) from (select w from jsonb_array_elements(case when jsonb_typeof(s #> '{health,weights}') = 'array' then s #> '{health,weights}' else '[]'::jsonb end) w limit 60) z),
      'lifts', (select coalesce(jsonb_agg(l order by (l ->> 'ts')::bigint desc), '[]'::jsonb) from (select l from jsonb_array_elements(case when jsonb_typeof(s -> 'lifts') = 'array' then s -> 'lifts' else '[]'::jsonb end) l order by (l ->> 'ts')::bigint desc nulls last limit 400) z),
      'ledger', (select coalesce(jsonb_agg(l order by (l ->> 'ts')::bigint desc), '[]'::jsonb) from (select l from jsonb_array_elements(case when jsonb_typeof(s -> 'ledger') = 'array' then s -> 'ledger' else '[]'::jsonb end) l order by (l ->> 'ts')::bigint desc nulls last limit 150) z),
      'saved_at', (select updated_at from app_state where user_id = p_id)) end,
    'flags', (select to_jsonb(f) from player_flags f where f.user_id = p_id),
    'ban', (select json_build_object('until', b.until, 'reason', b.reason, 'at', b.created_at, 'active', b.until is null or b.until > now()) from bans b where b.user_id = p_id),
    'is_admin', exists (select 1 from admins a where a.user_id = p_id),
    'reviews', (select coalesce(json_agg(r order by r.created_at desc), '[]'::json) from lift_reviews r where r.user_id = p_id),
    'reports_against', (select coalesce(json_agg(json_build_object('reason', r.reason, 'note', r.note, 'kind', r.target_kind, 'target', r.target_id, 'status', r.status, 'at', r.created_at, 'reporter_nick', (select nickname from profiles x where x.id = r.reporter_id)) order by r.created_at desc), '[]'::json)
                        from reports r where r.target_id = p_id or r.target_id in (select id from posts where user_id = p_id) or r.target_id in (select id from post_comments where user_id = p_id)),
    'reports_made', (select count(*) from reports r where r.reporter_id = p_id),
    'posts', (select coalesce(json_agg(json_build_object('id', po.id, 'kind', po.kind, 'body', po.body, 'photo', po.photo is not null, 'video', po.video, 'ex', po.ex, 'weight', po.weight, 'reps', po.reps, 'hidden', po.hidden, 'likes', po.like_count, 'comments', po.comment_count, 'created_at', po.created_at) order by po.created_at desc), '[]'::json)
              from (select * from posts where user_id = p_id order by created_at desc limit 30) po),
    'adjustments', (select coalesce(json_agg(a order by a.created_at desc), '[]'::json) from adjustments a where a.user_id = p_id),
    'log', (select coalesce(json_agg(json_build_object('action', l.action, 'details', l.details, 'at', l.created_at, 'admin_nick', (select nickname from profiles x where x.id = l.admin_id)) order by l.created_at desc), '[]'::json)
            from (select * from admin_log where target_id = p_id order by created_at desc limit 50) l),
    'friends', (select count(*) from friendships where user_id = p_id)
  );
end $$;

-- бан: p_days = null → навсегда, 0 → снять бан
create or replace function public.admin_ban(p_user uuid, p_days int, p_reason text default '') returns json
language plpgsql security definer set search_path = public as $$
declare v_admin uuid := flx_admin();
begin
  if p_user = v_admin then raise exception 'Нельзя забанить себя'; end if;
  if exists (select 1 from admins where user_id = p_user and role = 'owner') then raise exception 'Нельзя забанить владельца'; end if;
  if p_days = 0 then
    delete from bans where user_id = p_user;
    perform flx_log('unban', p_user, '{}'::jsonb);
  else
    insert into bans(user_id, until, reason, by) values (p_user, case when p_days is null then null else now() + make_interval(days => p_days) end, coalesce(p_reason, ''), v_admin)
      on conflict (user_id) do update set until = excluded.until, reason = excluded.reason, by = excluded.by, created_at = now();
    update duels set status = 'cancelled' where status = 'active' and (a_id = p_user or b_id = p_user);
    perform flx_log('ban', p_user, json_build_object('days', p_days, 'reason', p_reason)::jsonb);
  end if;
  return json_build_object('ok', true);
end $$;

-- правка кубков или монет: p_mode = delta | set. Кубки в рейтинге меняются сразу, в приложении — при следующем входе в сеть
create or replace function public.admin_adjust(p_user uuid, p_kind text, p_mode text, p_amount numeric, p_note text default '') returns json
language plpgsql security definer set search_path = public as $$
declare v_admin uuid := flx_admin(); v_t int; v_arena int;
begin
  if p_kind not in ('trophies', 'coins') or p_mode not in ('delta', 'set') then raise exception 'bad args'; end if;
  if p_mode = 'set' and p_amount < 0 then raise exception 'Значение не может быть меньше 0'; end if;
  if abs(p_amount) > 1000000 then raise exception 'Слишком большое число'; end if;
  insert into adjustments(user_id, kind, mode, amount, note, created_by) values (p_user, p_kind, p_mode, round(p_amount), coalesce(p_note, ''), v_admin);
  if p_kind = 'trophies' then
    select greatest(0, case when p_mode = 'set' then round(p_amount) else trophies + round(p_amount) end)::int into v_t from profiles where id = p_user;
    select count(*) - 1 into v_arena from unnest(array[0, 300, 800, 1500, 2500, 4000, 6000, 9000, 12000, 14000, 16500, 19000, 22000, 25000, 28500, 32000, 36000]) m where m <= v_t;
    update profiles set trophies = v_t, arena_idx = least(arena_idx, v_arena) where id = p_user;
  end if;
  perform flx_log('adjust_' || p_kind, p_user, json_build_object('mode', p_mode, 'amount', p_amount, 'note', p_note)::jsonb);
  return json_build_object('ok', true);
end $$;

-- сбросить рекорд по упражнению (до p_max кг e1RM или полностью). Приложение игрока удалит подходы тяжелее.
create or replace function public.admin_reset_ex(p_user uuid, p_ex text, p_max numeric default 0, p_note text default '') returns json
language plpgsql security definer set search_path = public as $$
declare v_kind text;
begin
  perform flx_admin();
  v_kind := flx_ex_kind(p_user, p_ex);
  update profiles set bests = case when coalesce(p_max, 0) > 0 then jsonb_set(bests, array[p_ex], to_jsonb(round(p_max))) else bests - p_ex end,
    boss = case when v_kind in ('bench', 'squat', 'deadlift') then jsonb_set(coalesce(boss, '{}'::jsonb), array[v_kind], to_jsonb(least(coalesce((boss ->> v_kind)::numeric, 0), round(coalesce(p_max, 0))))) else boss end
    where id = p_user;
  update lift_reviews set status = 'rejected', decided_at = now(), decided_by = auth.uid(), note = coalesce(nullif(p_note, ''), 'Рекорд сброшен'), seen = true
    where user_id = p_user and ex = p_ex and status = 'pending';
  insert into adjustments(user_id, kind, mode, amount, ex, note, created_by) values (p_user, 'reset_ex', 'set', coalesce(p_max, 0), p_ex, coalesce(p_note, ''), auth.uid());
  perform flx_log('reset_ex', p_user, json_build_object('ex', p_ex, 'max', p_max, 'note', p_note)::jsonb);
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_set_flags(p_user uuid, p_trusted boolean default null, p_note text default null) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform flx_admin();
  insert into player_flags(user_id, trusted, note) values (p_user, coalesce(p_trusted, false), coalesce(p_note, ''))
    on conflict (user_id) do update set trusted = coalesce(p_trusted, player_flags.trusted), note = coalesce(p_note, player_flags.note), updated_at = now();
  if p_trusted is not null then perform flx_log(case when p_trusted then 'trust' else 'untrust' end, p_user, '{}'::jsonb); end if;
  if p_note is not null then perform flx_log('note', p_user, json_build_object('note', p_note)::jsonb); end if;
  return json_build_object('ok', true);
end $$;

-- лента постов для модерации
create or replace function public.admin_posts(p_mode text default 'recent', p_limit int default 40, p_before timestamptz default null) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform flx_admin();
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select po.id, po.user_id, pr.nickname, pr.avatar, po.kind, po.body, po.tags, po.photo, po.video, po.ex, po.weight, po.reps, po.like_count, po.comment_count, po.view_count, po.hidden, po.created_at,
      (select count(*) from reports r where r.target_id = po.id) as reports, flx_banned(po.user_id) as banned
    from posts po left join profiles pr on pr.id = po.user_id
    where (p_before is null or po.created_at < p_before)
      and case p_mode when 'hidden' then po.hidden when 'reported' then exists (select 1 from reports r where r.target_id = po.id) when 'video' then po.video is not null else true end
    order by po.created_at desc limit least(greatest(p_limit, 1), 100)) x), '[]'::json);
end $$;

create or replace function public.admin_post_action(p_id uuid, p_action text) returns json
language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  perform flx_admin();
  select user_id into v_user from posts where id = p_id;
  if p_action = 'hide' then update posts set hidden = true where id = p_id;
  elsif p_action = 'unhide' then update posts set hidden = false where id = p_id;
  elsif p_action = 'delete' then delete from posts where id = p_id;
  else raise exception 'bad action'; end if;
  update reports set status = 'resolved', resolution = p_action, resolved_at = now(), resolved_by = auth.uid() where target_id = p_id and status = 'new' and p_action <> 'unhide';
  perform flx_log('post_' || p_action, v_user, json_build_object('post', p_id)::jsonb);
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_log_list(p_limit int default 100) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform flx_admin();
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select l.id, l.action, l.details, l.created_at, l.target_id,
      (select nickname from profiles p where p.id = l.admin_id) as admin_nick,
      (select nickname from profiles p where p.id = l.target_id) as target_nick
    from admin_log l order by l.created_at desc limit least(greatest(p_limit, 1), 500)) x), '[]'::json);
end $$;

create or replace function public.admin_rules_set(p_rules jsonb) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform flx_admin();
  if jsonb_typeof(p_rules) <> 'object' or jsonb_typeof(p_rules -> 'ratio') <> 'object' then raise exception 'Неверный формат правил'; end if;
  insert into app_config(key, value) values ('anticheat', p_rules::text) on conflict (key) do update set value = excluded.value;
  perform flx_log('rules', null, p_rules);
  return flx_rules()::json;
end $$;

create or replace function public.admin_rules_get() returns json
language plpgsql security definer set search_path = public as $$
begin perform flx_admin(); return flx_rules()::json; end $$;

-- команда модераторов (добавлять и убирать может только владелец)
create or replace function public.admin_team() returns json
language plpgsql security definer set search_path = public, auth as $$
begin
  perform flx_admin();
  return coalesce((select json_agg(json_build_object('user_id', a.user_id, 'role', a.role, 'added_at', a.added_at, 'nickname', p.nickname, 'email', u.email) order by a.added_at)
    from admins a left join profiles p on p.id = a.user_id left join auth.users u on u.id = a.user_id), '[]'::json);
end $$;

create or replace function public.admin_team_set(p_user uuid, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform flx_admin();
  if not exists (select 1 from admins where user_id = auth.uid() and role = 'owner') then raise exception 'Только владелец может менять команду'; end if;
  if p_user = auth.uid() then raise exception 'Себя убрать нельзя'; end if;
  if p_on then insert into admins(user_id, role) values (p_user, 'moderator') on conflict (user_id) do nothing;
  else delete from admins where user_id = p_user and role <> 'owner'; end if;
  perform flx_log(case when p_on then 'team_add' else 'team_remove' end, p_user, '{}'::jsonb);
  return json_build_object('ok', true);
end $$;

-- ---------- 8. Права ----------
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig, p.prorettype = 'trigger'::regtype as trg, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' and (p.proname like 'admin\_%' or p.proname like 'flx\_%' or p.proname in ('lift_review_submit', 'my_moderation')) loop
    execute format('revoke execute on function %s from anon, public', f.sig);
    if f.trg then execute format('revoke execute on function %s from authenticated', f.sig);
    else execute format('grant execute on function %s to authenticated, service_role', f.sig); end if;
  end loop;
end $$;
-- служебные функции из приложения напрямую не нужны
revoke execute on function public.flx_log(text, uuid, jsonb) from authenticated;
revoke execute on function public.flx_admin() from authenticated;
-- остальные flx_* остаются для authenticated: их вызывают правила RLS и защита профиля от имени игрока
-- (flx_bw и flx_review_auto сами проверяют, что игрок работает только со своими данными).
-- admin_* функции сами проверяют, что вызывающий — админ (flx_admin внутри них работает от владельца функции).

notify pgrst, 'reload schema';
