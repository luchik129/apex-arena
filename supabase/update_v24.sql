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
