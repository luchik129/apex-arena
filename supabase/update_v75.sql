-- v75: всё из update_v74.sql (вызов на дуэль нужно принять) + «Подколоть»: соперник получает короткую фразу уведомлением.
-- Можно запускать вместо update_v74.sql или после него — повторный запуск безопасен.
--
-- v74: вызов на дуэль нужно принять.
-- Прямой вызов (друг, профиль игрока) создаётся со статусом 'pending'. Дуэль начинается, только когда
-- вызванный нажмёт «Принять»: тогда week_key и created_at сдвигаются на момент принятия, счёт идёт с нуля.
-- Случайный поиск (duel_queue_join) работает как раньше: оба сами нажали «Найти соперника», дуэль сразу 'active'.
-- Статусы: pending → active | declined (ответ вызванного) | cancelled (отозвал вызвавший); active → cancelled (сдался).
-- Запусти один раз в Supabase → SQL Editor.

alter table public.duels add column if not exists a_poke timestamptz, add column if not exists a_poke_t text,
  add column if not exists b_poke timestamptz, add column if not exists b_poke_t text;

create or replace function public.duels_guard() returns trigger
language plpgsql set search_path = public as $$
declare me uuid := auth.uid();
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;  -- функции сервера (очередь поиска) — как есть
  if tg_op = 'INSERT' then
    new.status := 'pending'; new.created_at := now();
    if new.week_key !~ '^\d{4}-\d{2}-\d{2}$' or new.week_key::date not between current_date - 1 and current_date + 1 then new.week_key := current_date::text; end if;
    if exists (select 1 from duels d where (d.status = 'active' and d.week_key::date > current_date - 7 or d.status = 'pending' and d.created_at > now() - interval '48 hours')
               and ((d.a_id = new.a_id and d.b_id = new.b_id) or (d.a_id = new.b_id and d.b_id = new.a_id))) then
      raise exception 'С этим игроком уже есть дуэль или вызов';
    end if;
    if exists (select 1 from profiles p where p.id = new.b_id and p.battle_open = false) then
      raise exception 'Игрок сейчас не принимает вызовы';
    end if;
    if (select count(*) from duels d where d.a_id = new.a_id and d.created_at > now() - interval '7 days') >= 5 then
      raise exception 'Не больше 5 вызовов в неделю';
    end if;
    return new;
  end if;
  -- UPDATE: менять можно только статус (по правилам) и свою «подколку» (не чаще раза в 3 часа, до 80 символов)
  new.id := old.id; new.a_id := old.a_id; new.b_id := old.b_id; new.week_key := old.week_key; new.created_at := old.created_at;
  if me = old.a_id and new.a_poke is distinct from old.a_poke and old.status = 'active' and (old.a_poke is null or old.a_poke < now() - interval '3 hours') then
    new.a_poke := now(); new.a_poke_t := left(coalesce(new.a_poke_t, ''), 80);
  else new.a_poke := old.a_poke; new.a_poke_t := old.a_poke_t; end if;
  if me = old.b_id and new.b_poke is distinct from old.b_poke and old.status = 'active' and (old.b_poke is null or old.b_poke < now() - interval '3 hours') then
    new.b_poke := now(); new.b_poke_t := left(coalesce(new.b_poke_t, ''), 80);
  else new.b_poke := old.b_poke; new.b_poke_t := old.b_poke_t; end if;
  if new.status = old.status then return new; end if;
  if old.status = 'pending' and new.status = 'active' and me = old.b_id then
    if old.created_at < now() - interval '48 hours' then raise exception 'Вызов устарел'; end if;
    if exists (select 1 from duels d where d.id <> old.id and d.status = 'active' and d.week_key::date > current_date - 7
               and (d.a_id in (old.a_id, old.b_id) or d.b_id in (old.a_id, old.b_id))) then
      raise exception 'У одного из вас уже идёт дуэль';
    end if;
    new.week_key := current_date::text; new.created_at := now();  -- дуэль идёт 7 дней с момента принятия
  elsif old.status = 'pending' and new.status = 'declined' and me = old.b_id then null;
  elsif old.status = 'pending' and new.status = 'cancelled' and me = old.a_id then null;
  elsif old.status = 'active' and new.status = 'cancelled' and me in (old.a_id, old.b_id) then null;
  else new.status := old.status;
  end if;
  return new;
end $$;
drop trigger if exists duels_guard on public.duels;
create trigger duels_guard before insert or update on public.duels for each row execute function public.duels_guard();

-- принять вызов и сразу отклонить остальные входящие
create or replace function public.duel_accept(p_duel uuid) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare r duels;
begin
  update duels set status = 'active' where id = p_duel and b_id = auth.uid() and status = 'pending' returning * into r;
  if r.id is null or r.status <> 'active' then raise exception 'Вызов уже недоступен'; end if;
  update duels set status = 'declined' where b_id = auth.uid() and status = 'pending' and id <> p_duel;
  return jsonb_build_object('ok', true, 'id', r.id, 'opponent', r.a_id, 'week_key', r.week_key);
end $$;
grant execute on function public.duel_accept(uuid) to authenticated;
