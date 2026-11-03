-- =====================================================================
-- Flexo League v34: техническая гигиена сервера, отчёты об ошибках,
-- рейтинги без загрузки всех игроков.
-- Запускать после update_v32.sql. Можно запускать повторно.
-- Supabase → SQL Editor → вставить всё → Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Правила доступа (RLS): auth.uid() считается один раз на запрос,
--    а не для каждой строки (совет Supabase «auth_rls_initplan»).
--    Смысл правил не меняется — только форма записи.
-- ---------------------------------------------------------------------
do $$
declare r record; q text; c text; s text;
begin
  for r in select schemaname, tablename, policyname, qual, with_check from pg_policies
           where schemaname = 'public'
             and (coalesce(qual, '') ~ 'auth\.uid\(\)' or coalesce(with_check, '') ~ 'auth\.uid\(\)')
  loop
    q := case when r.qual is null then null else regexp_replace(r.qual, '(?<!SELECT )auth\.uid\(\)', '(select auth.uid())', 'g') end;
    c := case when r.with_check is null then null else regexp_replace(r.with_check, '(?<!SELECT )auth\.uid\(\)', '(select auth.uid())', 'g') end;
    if q is not distinct from r.qual and c is not distinct from r.with_check then continue; end if;
    s := format('alter policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
    if q is not null then s := s || ' using (' || q || ')'; end if;
    if c is not null then s := s || ' with check (' || c || ')'; end if;
    execute s;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 2. Индексы на внешние ключи (удаление аккаунта, ленты, жалобы)
-- ---------------------------------------------------------------------
create index if not exists adjustments_created_by_idx on public.adjustments(created_by);
create index if not exists admin_log_admin_id_idx on public.admin_log(admin_id);
create index if not exists bans_by_idx on public.bans("by");
create index if not exists clans_leader_id_idx on public.clans(leader_id);
create index if not exists feed_user_id_idx on public.feed(user_id);
create index if not exists friend_requests_to_id_idx on public.friend_requests(to_id);
create index if not exists friendships_friend_id_idx on public.friendships(friend_id);
create index if not exists lift_reviews_decided_by_idx on public.lift_reviews(decided_by);
create index if not exists post_comments_user_id_idx on public.post_comments(user_id);
create index if not exists post_likes_user_id_idx on public.post_likes(user_id);
create index if not exists post_views_user_id_idx on public.post_views(user_id);
create index if not exists posts_user_id_idx on public.posts(user_id);

-- первичные ключи для журналов анти-чита
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'bw_log' and column_name = 'id') then
    alter table public.bw_log add column id bigint generated always as identity primary key;
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'best_log' and column_name = 'id') then
    alter table public.best_log add column id bigint generated always as identity primary key;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. Рейтинги: приложение больше не качает всех игроков.
--    Сумма жим+присед+тяга хранится в колонке, чтобы сервер сам отдавал топ.
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists boss_total numeric generated always as (
    (case when coalesce(boss->>'bench', '')    ~ '^[0-9]+(\.[0-9]+)?$' then (boss->>'bench')::numeric    else 0 end)
  + (case when coalesce(boss->>'squat', '')    ~ '^[0-9]+(\.[0-9]+)?$' then (boss->>'squat')::numeric    else 0 end)
  + (case when coalesce(boss->>'deadlift', '') ~ '^[0-9]+(\.[0-9]+)?$' then (boss->>'deadlift')::numeric else 0 end)
) stored;
create index if not exists profiles_trophies_idx on public.profiles(trophies desc);
create index if not exists profiles_boss_total_idx on public.profiles(boss_total desc);
create index if not exists profiles_arena_trophies_idx on public.profiles(arena_idx, trophies desc);
create index if not exists profiles_friend_code_idx on public.profiles(friend_code);
create index if not exists bans_user_id_idx on public.bans(user_id);

-- ---------------------------------------------------------------------
-- 4. Отчёты об ошибках с телефонов (вкладка «Ошибки» в админке)
-- ---------------------------------------------------------------------
create table if not exists public.client_errors (
  id bigint generated always as identity primary key,
  user_id uuid default auth.uid() references auth.users(id) on delete cascade,
  at timestamptz not null default now(),
  msg text not null check (length(msg) <= 300),
  stack text check (length(stack) <= 2000),
  place text check (length(place) <= 200),
  screen text check (length(screen) <= 40),
  ver text check (length(ver) <= 40),
  ua text check (length(ua) <= 200)
);
create index if not exists client_errors_at_idx on public.client_errors(at desc);
create index if not exists client_errors_user_idx on public.client_errors(user_id);
alter table public.client_errors enable row level security;
drop policy if exists "errors insert own" on public.client_errors;
create policy "errors insert own" on public.client_errors for insert to authenticated with check (user_id = (select auth.uid()));
revoke all on public.client_errors from anon;
grant insert on public.client_errors to authenticated;

-- не больше 50 отчётов в сутки от одного игрока; старше 30 дней — удаляем
create or replace function public.client_errors_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from client_errors where user_id = new.user_id and at > now() - interval '1 day') >= 50 then return null; end if;
  new.at := now();
  if random() < 0.02 then delete from client_errors where at < now() - interval '30 days'; end if;
  return new;
end $$;
drop trigger if exists client_errors_guard on public.client_errors;
create trigger client_errors_guard before insert on public.client_errors for each row execute function public.client_errors_guard();

-- админка: ошибки, сгруппированные по тексту
create or replace function public.admin_errors(p_days int default 7, p_limit int default 100)
returns table(msg text, place text, n bigint, users bigint, first_at timestamptz, last_at timestamptz, vers text, screens text, stack text, ua text)
language plpgsql security definer set search_path = public as $$
begin
  perform flx_admin();
  return query
    select e.msg, min(e.place), count(*), count(distinct e.user_id), min(e.at), max(e.at),
           string_agg(distinct e.ver, ', '), string_agg(distinct e.screen, ', '),
           (array_agg(e.stack order by e.at desc))[1], (array_agg(e.ua order by e.at desc))[1]
      from client_errors e
     where e.at > now() - make_interval(days => greatest(1, least(p_days, 30)))
     group by e.msg
     order by max(e.at) desc
     limit greatest(1, least(p_limit, 300));
end $$;

create or replace function public.admin_errors_clear(p_msg text)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform flx_admin();
  delete from client_errors where p_msg is null or msg = p_msg;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.admin_errors(int, int) from public, anon;
revoke all on function public.admin_errors_clear(text) from public, anon;
grant execute on function public.admin_errors(int, int) to authenticated;
grant execute on function public.admin_errors_clear(text) to authenticated;
revoke all on function public.client_errors_guard() from public, anon, authenticated;

-- служебные функции, которые клиенту вызывать не нужно (их вызывают только
-- другие серверные функции от имени владельца)
revoke execute on function public.flx_is_admin(uuid) from public, anon, authenticated;
revoke execute on function public.flx_report_weight(uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';
