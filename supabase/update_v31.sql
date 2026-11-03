-- Flexo League v31: каждый помеченный подход попадает в очередь модератора,
-- вес тела для анти-чита = минимум за 30 дней, рост рекорда >25% за 30 дней и попадание в топ-10 идут на проверку,
-- монеты на сервере растут не больше чем на 1000 в день.
-- Вставь целиком в Supabase → SQL Editor → Run (после update_v30.sql). Можно запускать повторно.

-- 1) порог «скачка от прошлого рекорда» как в приложении: 15%
update public.app_config set value = ('{"growth": 0.25, "top": 10, "top_min": 100, "top_from": 30}'::jsonb || value::jsonb || '{"jump": 0.15}'::jsonb)::text where key = 'anticheat';

-- 1a) история веса тела (пишет сервер, игрок её не меняет). Для анти-чита берётся минимум за 30 дней,
--     поэтому «поставить себе 130 кг» не поднимает лимиты.
create table if not exists public.bw_log (
  user_id uuid not null references auth.users(id) on delete cascade,
  bw numeric not null,
  at timestamptz not null default now()
);
create index if not exists bw_log_user_at on public.bw_log(user_id, at desc);
alter table public.bw_log enable row level security;

-- история рекордов (что реально попало в профиль и когда)
create table if not exists public.best_log (
  user_id uuid not null references auth.users(id) on delete cascade,
  ex text not null,
  val numeric not null,
  at timestamptz not null default now()
);
create index if not exists best_log_user_ex_at on public.best_log(user_id, ex, at);
alter table public.best_log enable row level security;

-- текущие значения считаем «старыми» (31 день назад), чтобы у всех была точка отсчёта
insert into public.bw_log(user_id, bw, at)
  select s.user_id, b.v, now() - interval '31 days' from public.app_state s
  cross join lateral (select nullif(regexp_replace(coalesce(s.data #>> '{profile,bodyweight}', ''), '[^0-9.]', '', 'g'), '')::numeric v) b
  where b.v between 20 and 400 and not exists (select 1 from public.bw_log l where l.user_id = s.user_id);
insert into public.best_log(user_id, ex, val, at)
  select p.id, b.key, b.value::numeric, now() - interval '31 days' from public.profiles p, jsonb_each_text(coalesce(p.bests, '{}'::jsonb)) b
  where b.value ~ '^[0-9]+(\.[0-9]+)?$' and not exists (select 1 from public.best_log l where l.user_id = p.id);

alter table public.app_state add column if not exists coin_day date;
alter table public.app_state add column if not exists coin_gain int not null default 0;

create or replace function public.flx_bw_now(p_uid uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select nullif(regexp_replace(coalesce(data #>> '{profile,bodyweight}', ''), '[^0-9.]', '', 'g'), '')::numeric from app_state where user_id = p_uid;
$$;

-- вес тела для анти-чита: минимум из текущего и всех значений за последние 30 дней
create or replace function public.flx_bw(p_uid uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select least(flx_bw_now(p_uid),
               (select min(bw) from bw_log where user_id = p_uid and at > now() - interval '30 days'),
               (select bw from bw_log where user_id = p_uid and at <= now() - interval '30 days' order by at desc limit 1))
  where auth.uid() is null or auth.uid() = p_uid or exists (select 1 from admins where user_id = auth.uid());
$$;

-- от чего считать рост за 30 дней: лучший рекорд 30+ дней назад (или самый первый), но не ниже одобренного модератором
create or replace function public.flx_growth_base(p_uid uuid, p_ex text) returns numeric
language sql stable security definer set search_path = public as $$
  select greatest(coalesce((select max(val) from best_log where user_id = p_uid and ex = p_ex and at <= now() - interval '30 days'),
                           (select val from best_log where user_id = p_uid and ex = p_ex order by at limit 1), 0),
                  flx_approved_max(p_uid, p_ex));
$$;

-- почему подход подозрительный: ratio, jump, record + growth (рост >25% за 30 дней) и top (место в топ-10)
create or replace function public.flx_lift_reasons(p_uid uuid, p_ex text, p_e1rm numeric, p_prev numeric, p_bw numeric) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare r jsonb := flx_rules(); k text; lim numeric; out text[] := '{}'; v_sex text; v_base numeric; v_n int; v_all int;
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
  if not 'jump' = any(out) and coalesce((r ->> 'growth')::numeric, 0) > 0 then
    v_base := flx_growth_base(p_uid, p_ex);
    if v_base > 0 and p_e1rm > v_base * (1 + (r ->> 'growth')::numeric) then out := array_append(out, 'growth'); end if;
  end if;
  if coalesce((r ->> 'top')::int, 0) > 0 and p_e1rm >= coalesce((r ->> 'top_min')::numeric, 100) then
    -- пока в рейтинге упражнения меньше top_from игроков (30), топ-10 не проверяем: иначе на проверку уйдёт почти всё
    select count(*) filter (where (p.bests ->> p_ex)::numeric >= p_e1rm), count(*) into v_n, v_all from profiles p left join bans b on b.user_id = p.id and (b.until is null or b.until > now())
      where p.id <> p_uid and b.user_id is null and coalesce(p.bests ->> p_ex, '') ~ '^[0-9]+(\.[0-9]+)?$';
    if v_all >= coalesce((r ->> 'top_from')::int, 30) and v_n < (r ->> 'top')::int then out := array_append(out, 'top'); end if;
  end if;
  return out;
end $$;

-- записываем в историю рекорды, которые реально попали в профиль
create or replace function public.flx_best_log_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text; v text;
begin
  for k, v in select key, value from jsonb_each_text(coalesce(new.bests, '{}'::jsonb)) loop
    continue when v !~ '^[0-9]+(\.[0-9]+)?$';
    continue when tg_op = 'UPDATE' and coalesce(old.bests ->> k, '') ~ '^[0-9]+(\.[0-9]+)?$' and v::numeric <= (old.bests ->> k)::numeric + 0.5;
    insert into best_log(user_id, ex, val) values (new.id, k, v::numeric);
  end loop;
  return null;
end $$;
drop trigger if exists profiles_best_log on public.profiles;
create trigger profiles_best_log after insert or update of bests on public.profiles for each row execute function public.flx_best_log_trg();

-- резервная копия игрока: пишем историю веса тела и ограничиваем рост монет (1000 в день)
create or replace function public.app_state_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_new numeric; v_old numeric; v_c numeric; v_oc numeric; v_gain int; v_extra numeric := 0; v_cap int := 1000;
begin
  if current_setting('flx.admin', true) = '1' then return new; end if;
  -- вес тела
  v_new := nullif(regexp_replace(coalesce(new.data #>> '{profile,bodyweight}', ''), '[^0-9.]', '', 'g'), '')::numeric;
  v_old := case when tg_op = 'UPDATE' then nullif(regexp_replace(coalesce(old.data #>> '{profile,bodyweight}', ''), '[^0-9.]', '', 'g'), '')::numeric end;
  if v_new between 20 and 400 and v_new is distinct from v_old then
    if v_old between 20 and 400 and not exists (select 1 from bw_log where user_id = new.user_id) then insert into bw_log(user_id, bw) values (new.user_id, v_old); end if;
    insert into bw_log(user_id, bw) values (new.user_id, v_new);
  end if;
  -- монеты
  v_c := case when coalesce(new.data #>> '{game,coins}', '') ~ '^-?[0-9]+(\.[0-9]+)?$' then (new.data #>> '{game,coins}')::numeric end;
  if v_c is null then return new; end if;
  if tg_op = 'INSERT' then
    new.coin_day := current_date; new.coin_gain := least(greatest(v_c, 0), v_cap)::int;
    if v_c > v_cap then new.data := jsonb_set(new.data, '{game,coins}', to_jsonb(v_cap)); end if;
    return new;
  end if;
  v_oc := case when coalesce(old.data #>> '{game,coins}', '') ~ '^-?[0-9]+(\.[0-9]+)?$' then (old.data #>> '{game,coins}')::numeric else 0 end;
  v_gain := case when old.coin_day = current_date then coalesce(old.coin_gain, 0) else 0 end;
  if v_c <= v_oc then new.coin_day := old.coin_day; new.coin_gain := old.coin_gain; return new; end if;
  -- монеты, которые выдал модератор за последние сутки, в лимит не входят
  select coalesce(sum(case when mode = 'delta' and amount > 0 then amount when mode = 'set' then greatest(amount - v_oc, 0) else 0 end), 0) into v_extra
    from adjustments where user_id = new.user_id and kind = 'coins' and applied_at > now() - interval '1 day';
  if v_c > v_oc + greatest(0, v_cap - v_gain) + v_extra then
    v_c := v_oc + greatest(0, v_cap - v_gain) + v_extra;
    new.data := jsonb_set(new.data, '{game,coins}', to_jsonb(round(v_c)));
  end if;
  new.coin_day := current_date; new.coin_gain := least(v_gain + greatest(v_c - v_oc - v_extra, 0), 100000)::int;
  return new;
end $$;
drop trigger if exists app_state_guard on public.app_state;
create trigger app_state_guard before insert or update on public.app_state for each row execute function public.app_state_guard();

-- 2) подход, который прислало приложение, всегда ждёт решения (кроме «проверенных атлетов»)
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
  v_bw := coalesce(least(nullif(p_bw, 0), flx_bw(v_uid)), flx_bw(v_uid), nullif(p_bw, 0)); -- вес из приложения не выше серверного
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

-- служебные функции из приложения напрямую не вызываются
revoke execute on function public.flx_best_log_trg() from anon, public, authenticated;
revoke execute on function public.app_state_guard() from anon, public, authenticated;
revoke execute on function public.flx_growth_base(uuid, text) from anon, public, authenticated;
revoke execute on function public.flx_bw_now(uuid) from anon, public, authenticated;

notify pgrst, 'reload schema';
