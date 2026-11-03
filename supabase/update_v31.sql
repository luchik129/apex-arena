-- Flexo League v31: каждый помеченный подход попадает в очередь модератора.
-- Вставь целиком в Supabase → SQL Editor → Run (после update_v30.sql). Можно запускать повторно.

-- 1) порог «скачка от прошлого рекорда» как в приложении: 15%
update public.app_config set value = (value::jsonb || '{"jump": 0.15}'::jsonb)::text where key = 'anticheat';

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

notify pgrst, 'reload schema';
