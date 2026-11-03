-- Flexo League v32: новичков и игроков обычного уровня не отправляем на проверку за быстрый рост.
-- Правило: если результат (e1RM) не выше 60% от предела «N× веса тела» для упражнения, скачок и рост за 30 дней не проверяются.
-- Пример для мужчины 80 кг: жим до 96 кг, присед до 130 кг, становая до 144 кг проходят без модератора.
-- Предел ratio, мировые рекорды и топ-10 проверяются как раньше. Долю можно менять в админке: ключ free_share в правилах anticheat (0 = выключить).
-- Вставь целиком в Supabase → SQL Editor → Run (после update_v31.sql). Можно запускать повторно.

update public.app_config set value = ('{"free_share": 0.6}'::jsonb || value::jsonb)::text where key = 'anticheat';

-- обычный ли это уровень: e1RM <= вес тела × предел упражнения × free_share
create or replace function public.flx_ac_free(p_uid uuid, p_ex text, p_e1rm numeric, p_bw numeric) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare r jsonb := flx_rules(); k text; lim numeric; v_share numeric; v_sex text;
begin
  v_share := coalesce((r ->> 'free_share')::numeric, 0.6);
  if v_share <= 0 or coalesce(p_bw, 0) <= 0 or p_e1rm is null then return false; end if;
  k := flx_ex_kind(p_uid, p_ex);
  select sex into v_sex from profiles where id = p_uid;
  lim := coalesce((r -> 'ratio' ->> p_ex)::numeric, (r -> 'ratio' ->> k)::numeric, (r -> 'ratio' ->> 'other')::numeric, 3);
  if v_sex = 'f' then lim := lim * coalesce((r ->> 'female')::numeric, 0.72); end if;
  return p_e1rm <= p_bw * lim * v_share;
end $$;

create or replace function public.flx_lift_reasons(p_uid uuid, p_ex text, p_e1rm numeric, p_prev numeric, p_bw numeric) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare r jsonb := flx_rules(); k text; lim numeric; out text[] := '{}'; v_sex text; v_base numeric; v_n int; v_all int; v_free boolean;
begin
  if not coalesce((r ->> 'enabled')::boolean, false) or p_e1rm is null then return out; end if;
  k := flx_ex_kind(p_uid, p_ex);
  if (r -> 'record' ->> k) is not null and p_e1rm > (r -> 'record' ->> k)::numeric then out := array_append(out, 'record'); end if;
  if p_e1rm < coalesce((r ->> 'min_kg')::numeric, 60) then return out; end if;
  select sex into v_sex from profiles where id = p_uid;
  lim := coalesce((r -> 'ratio' ->> p_ex)::numeric, (r -> 'ratio' ->> k)::numeric, (r -> 'ratio' ->> 'other')::numeric, 3);
  if v_sex = 'f' then lim := lim * coalesce((r ->> 'female')::numeric, 0.72); end if;
  if coalesce(p_bw, 0) > 0 and p_e1rm > p_bw * lim then out := array_append(out, 'ratio'); end if;
  -- v32: обычный уровень (ниже 60% от предела) — скачки и рост не проверяем
  v_free := flx_ac_free(p_uid, p_ex, p_e1rm, p_bw);
  if not v_free and coalesce(p_prev, 0) > 0 and p_e1rm > p_prev * (1 + coalesce((r ->> 'jump')::numeric, 0.15)) then out := array_append(out, 'jump'); end if;
  if not v_free and not 'jump' = any(out) and coalesce((r ->> 'growth')::numeric, 0) > 0 then
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
  v_ok := flx_trusted(v_uid);
  if coalesce(array_length(v_why, 1), 0) = 0 then
    v_why := array['jump'];
    -- v32: старые версии приложения помечают любой скачок; если вес обычного уровня — одобряем сразу
    if not v_ok and flx_ac_free(v_uid, p_ex, p_e1rm, v_bw) then
      insert into lift_reviews(user_id, lift_id, ex, weight, reps, e1rm, bodyweight, prev_best, ratio, lift_date, reasons, source, status, note, decided_at, seen)
      values (v_uid, p_lift_id, p_ex, p_weight, p_reps, round(p_e1rm, 1), v_bw, v_prev, case when coalesce(v_bw, 0) > 0 then round(p_e1rm / v_bw, 2) end,
              case when p_date between current_date - 30 and current_date + 1 then p_date else current_date end, v_why, 'app',
              'approved', 'Обычный прогресс', now(), true)
      returning * into v_row;
      return v_row.status;
    end if;
  end if;
  insert into lift_reviews(user_id, lift_id, ex, weight, reps, e1rm, bodyweight, prev_best, ratio, lift_date, reasons, source, status, note, decided_at, seen)
  values (v_uid, p_lift_id, p_ex, p_weight, p_reps, round(p_e1rm, 1), v_bw, v_prev, case when coalesce(v_bw, 0) > 0 then round(p_e1rm / v_bw, 2) end,
          case when p_date between current_date - 30 and current_date + 1 then p_date else current_date end, v_why, 'app',
          case when v_ok then 'approved' else 'pending' end, case when v_ok then 'Проверенный атлет' end, case when v_ok then now() end, v_ok)
  returning * into v_row;
  return v_row.status;
end $$;


revoke execute on function public.flx_ac_free(uuid, text, numeric, numeric) from anon, public, authenticated;

notify pgrst, 'reload schema';
