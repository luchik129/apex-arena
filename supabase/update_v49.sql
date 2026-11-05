-- =====================================================================
-- Flexo League v49: честные дуэли и клановые битвы
--   * итог дуэли и битвы считает сервер (по дням из profiles.days), а не телефон
--   * награду каждый забирает один раз (duel_claim / clan_battle_claim)
--   * счёт идёт 7 полных дней со следующего дня после вызова
--   * сдача: первые 24 часа = отказ без последствий, потом = поражение
--   * анти-твинк: платная победа не чаще 2 за 7 дней, не чаще 1 раза в 30 дней
--     над тем же соперником, соперник старше 7 дней и с 3+ тренировками
--   * клановая битва сразу у обоих кланов, состав фиксируется на старте,
--     перезапустить нельзя, тот же клан не раньше чем через 21 день
-- Запусти один раз в Supabase → SQL Editor (после update_v41.sql). Можно запускать повторно.
-- =====================================================================

-- ---------- 0. Счёт игрока за 7 дней с p_from (по дням, которые сервер уже принял) ----------
create or replace function public.flx_window(p_uid uuid, p_from date) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(
           case when d.value ->> 'w' = '1' then 20 else 0 end
         + case when coalesce(d.value ->> 'p', '') ~ '^\d+$' then least((d.value ->> 'p')::int, 3) * 25 else 0 end), 0)::int
    from profiles p, jsonb_each(case when jsonb_typeof(p.days) = 'object' then p.days else '{}'::jsonb end) d
   where p.id = p_uid and d.key ~ '^\d{4}-\d{2}-\d{2}$' and d.key::date between p_from and p_from + 6;
$$;

-- сколько дней с тренировкой у игрока за последние 40 дней
create or replace function public.flx_workout_days(p_uid uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from profiles p, jsonb_each(case when jsonb_typeof(p.days) = 'object' then p.days else '{}'::jsonb end) d
   where p.id = p_uid and d.value ->> 'w' = '1';
$$;

-- ---------- 1. Дуэли: итог на сервере ----------
alter table public.duels add column if not exists a_score int;
alter table public.duels add column if not exists b_score int;
alter table public.duels add column if not exists winner uuid;
alter table public.duels add column if not exists forfeit_by uuid;
alter table public.duels add column if not exists settled_at timestamptz;

create table if not exists public.duel_results (
  user_id uuid not null references auth.users(id) on delete cascade,
  duel_id uuid not null references public.duels(id) on delete cascade,
  opp_id uuid,
  my_score int not null default 0,
  opp_score int not null default 0,
  result text not null,            -- win | loss | draw | gave
  paid boolean not null default false,
  reason text,                     -- почему без награды: opp_idle | me_idle | week_cap | same_opp | new_opp | opp_inactive
  created_at timestamptz not null default now(),
  primary key (user_id, duel_id)
);
alter table public.duel_results enable row level security;
drop policy if exists "duel results own" on public.duel_results;
create policy "duel results own" on public.duel_results for select to authenticated using (user_id = (select auth.uid()));
create index if not exists duel_results_paid_idx on public.duel_results(user_id, created_at) where paid;

-- участник может только сдаться (пока дуэль идёт); счёт и победителя пишет только сервер
create or replace function public.duels_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    new.status := 'active'; new.created_at := now();
    new.a_score := null; new.b_score := null; new.winner := null; new.forfeit_by := null; new.settled_at := null;
    if new.week_key !~ '^\d{4}-\d{2}-\d{2}$' or new.week_key::date not between current_date - 1 and current_date + 1 then new.week_key := current_date::text; end if;
    if exists (select 1 from duels d where d.status = 'active' and d.week_key::date > current_date - 8 and (new.a_id in (d.a_id, d.b_id))) then
      raise exception 'У тебя уже идёт дуэль';
    end if;
    if exists (select 1 from duels d where d.status = 'active' and d.week_key::date > current_date - 8 and (new.b_id in (d.a_id, d.b_id))) then
      raise exception 'У этого игрока уже идёт дуэль';
    end if;
    if (select count(*) from duels d where d.a_id = new.a_id and d.created_at > now() - interval '7 days') >= 3 then
      raise exception 'Не больше 3 вызовов в неделю';
    end if;
  else
    new.id := old.id; new.a_id := old.a_id; new.b_id := old.b_id; new.week_key := old.week_key; new.created_at := old.created_at;
    new.a_score := old.a_score; new.b_score := old.b_score; new.winner := old.winner; new.settled_at := old.settled_at; new.forfeit_by := old.forfeit_by;
    if new.status is distinct from old.status then
      -- сдаться можно только в идущей дуэли; после 24 часов это поражение
      if old.status = 'active' and new.status = 'cancelled' and current_date < old.week_key::date + 8 then
        new.forfeit_by := case when now() - old.created_at > interval '24 hours' then auth.uid() end;
      else
        new.status := old.status;
      end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists duels_guard on public.duels;
create trigger duels_guard before insert or update on public.duels for each row execute function public.duels_guard();

-- подвести итог дуэлей игрока, у которых закончилось время (или был сдан бой)
create or replace function public.flx_duel_settle(p_uid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d duels; sa int; sb int;
begin
  for d in select * from duels x
            where (x.a_id = p_uid or x.b_id = p_uid) and x.settled_at is null
              and ((x.status = 'active' and current_date >= x.week_key::date + 8) or (x.status = 'cancelled' and x.forfeit_by is not null))
            for update skip locked loop
    sa := flx_window(d.a_id, d.week_key::date + 1); sb := flx_window(d.b_id, d.week_key::date + 1);
    update duels set a_score = sa, b_score = sb, settled_at = now(),
      status = case when status = 'active' then 'done' else status end,
      winner = case when d.forfeit_by is not null then case when d.forfeit_by = d.a_id then d.b_id else d.a_id end
                    when sa > sb then d.a_id when sb > sa then d.b_id end
     where id = d.id;
  end loop;
end $$;

-- забрать итоги своих дуэлей: каждая строка возвращается один раз, paid = можно начислить награду
create or replace function public.duel_claim() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); d duels; v_opp uuid; v_my int; v_os int; v_res text; v_paid boolean; v_why text; v_out jsonb := '[]'::jsonb;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  perform flx_duel_settle(v_uid);
  for d in select * from duels x where (x.a_id = v_uid or x.b_id = v_uid) and x.settled_at is not null and x.settled_at > now() - interval '30 days'
             and not exists (select 1 from duel_results r where r.user_id = v_uid and r.duel_id = x.id) order by x.settled_at loop
    v_opp := case when d.a_id = v_uid then d.b_id else d.a_id end;
    v_my := case when d.a_id = v_uid then d.a_score else d.b_score end;
    v_os := case when d.a_id = v_uid then d.b_score else d.a_score end;
    v_res := case when d.forfeit_by = v_uid then 'gave' when d.winner = v_uid then 'win' when d.winner is null then 'draw' else 'loss' end;
    v_paid := false; v_why := null;
    if v_res = 'win' then
      v_why := case
        when coalesce(v_os, 0) <= 0 then 'opp_idle'
        when coalesce(v_my, 0) <= 0 then 'me_idle'
        when flx_banned(v_uid) then 'banned'
        when (select count(*) from duel_results r where r.user_id = v_uid and r.paid and r.created_at > now() - interval '7 days') >= 2 then 'week_cap'
        when exists (select 1 from duel_results r where r.user_id = v_uid and r.paid and r.opp_id = v_opp and r.created_at > now() - interval '30 days') then 'same_opp'
        when coalesce((select u.created_at from auth.users u where u.id = v_opp), now()) > now() - interval '7 days' then 'new_opp'
        when flx_workout_days(v_opp) < 3 then 'opp_inactive'
      end;
      v_paid := v_why is null;
    end if;
    insert into duel_results(user_id, duel_id, opp_id, my_score, opp_score, result, paid, reason)
      values (v_uid, d.id, v_opp, coalesce(v_my, 0), coalesce(v_os, 0), v_res, v_paid, v_why) on conflict do nothing;
    if found then
      v_out := v_out || jsonb_build_object('duel_id', d.id, 'opp_id', v_opp, 'my_score', coalesce(v_my, 0), 'opp_score', coalesce(v_os, 0), 'result', v_res, 'paid', v_paid, 'reason', v_why);
    end if;
  end loop;
  return v_out;
end $$;
grant execute on function public.duel_claim() to authenticated;
revoke execute on function public.flx_duel_settle(uuid) from anon, public, authenticated;

-- поиск дуэли: арена с сервера, бан, не больше 5 дуэлей за 7 дней, дуэль идёт 8 дней (день вызова + 7)
create or replace function public.duel_queue_join(p_arena int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare opp uuid; did uuid; v_arena int;
begin
  if auth.uid() is null then raise exception 'Нужно войти'; end if;
  if flx_banned(auth.uid()) then raise exception 'flx_banned: аккаунт заблокирован модератором' using errcode = '42501'; end if;
  select arena_idx into v_arena from profiles where id = auth.uid();
  v_arena := coalesce(v_arena, 0);
  delete from duel_queue where updated_at < now() - interval '60 seconds';
  if exists (select 1 from duels d where d.status = 'active' and d.week_key::date > current_date - 8 and (d.a_id = auth.uid() or d.b_id = auth.uid())) then
    delete from duel_queue where user_id = auth.uid();
    raise exception 'У тебя уже идёт дуэль';
  end if;
  if (select count(*) from duels d where (d.a_id = auth.uid() or d.b_id = auth.uid()) and d.created_at > now() - interval '7 days') >= 5 then
    delete from duel_queue where user_id = auth.uid();
    raise exception 'Не больше 5 дуэлей за 7 дней';
  end if;
  select q.user_id into opp from duel_queue q
   where q.user_id <> auth.uid()
     and not flx_banned(q.user_id)
     and not exists (select 1 from duels d where d.status = 'active' and d.week_key::date > current_date - 8 and (d.a_id = q.user_id or d.b_id = q.user_id))
   order by abs(q.arena_idx - v_arena), q.created_at limit 1 for update skip locked;
  if opp is not null then
    delete from duel_queue where user_id in (opp, auth.uid());
    insert into duels(week_key, a_id, b_id) values (current_date::text, opp, auth.uid()) returning id into did;
    update profiles set battle_open = true where id in (opp, auth.uid());
    return jsonb_build_object('matched', true, 'duel_id', did, 'opponent', opp);
  end if;
  insert into duel_queue(user_id, arena_idx) values (auth.uid(), v_arena)
    on conflict (user_id) do update set updated_at = now(), arena_idx = excluded.arena_idx;
  return jsonb_build_object('matched', false, 'waiting', (select count(*) from duel_queue where user_id <> auth.uid()));
end $$;

-- ---------- 2. Клановые битвы: отдельная таблица, состав на старте ----------
create table if not exists public.clan_battles (
  id uuid primary key default gen_random_uuid(),
  a_clan uuid not null references public.clans(id) on delete cascade,   -- кто вызвал
  b_clan uuid not null references public.clans(id) on delete cascade,
  start_day date not null default current_date,                        -- счёт идёт со следующего дня, 7 дней
  kind text not null default 'random',                                 -- random | challenge
  created_by uuid,
  created_at timestamptz not null default now(),
  a_score int, b_score int, winner_clan uuid, settled_at timestamptz
);
create index if not exists clan_battles_a_idx on public.clan_battles(a_clan, start_day);
create index if not exists clan_battles_b_idx on public.clan_battles(b_clan, start_day);

create table if not exists public.clan_battle_members (
  battle_id uuid not null references public.clan_battles(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  clan_id uuid not null,
  primary key (battle_id, user_id)
);
create index if not exists clan_battle_members_user_idx on public.clan_battle_members(user_id);

create table if not exists public.clan_battle_results (
  user_id uuid not null references auth.users(id) on delete cascade,
  battle_id uuid not null references public.clan_battles(id) on delete cascade,
  clan_id uuid,
  my_clan_score int not null default 0,
  opp_clan_score int not null default 0,
  result text not null,             -- win | loss | draw
  paid boolean not null default false,
  reason text,                      -- opp_idle | me_idle | left_clan | week_cap | banned
  created_at timestamptz not null default now(),
  primary key (user_id, battle_id)
);
create index if not exists clan_battle_results_paid_idx on public.clan_battle_results(user_id, created_at) where paid;

alter table public.clan_battles enable row level security;
alter table public.clan_battle_members enable row level security;
alter table public.clan_battle_results enable row level security;
drop policy if exists "clan battles read" on public.clan_battles;
create policy "clan battles read" on public.clan_battles for select to authenticated using (true);
drop policy if exists "clan battle members read" on public.clan_battle_members;
create policy "clan battle members read" on public.clan_battle_members for select to authenticated using (true);
drop policy if exists "clan battle results own" on public.clan_battle_results;
create policy "clan battle results own" on public.clan_battle_results for select to authenticated using (user_id = (select auth.uid()));
-- писать во все три таблицы можно только через функции ниже

-- подвести итог битв, у которых закончилось время
create or replace function public.flx_cb_settle(p_clan uuid default null, p_user uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare b clan_battles; sa int; sb int;
begin
  for b in select * from clan_battles x
            where x.settled_at is null and current_date >= x.start_day + 8
              and (p_clan is null or p_clan in (x.a_clan, x.b_clan))
              and (p_user is null or exists (select 1 from clan_battle_members m where m.battle_id = x.id and m.user_id = p_user))
            for update skip locked loop
    select coalesce(sum(flx_window(m.user_id, b.start_day + 1)), 0) into sa from clan_battle_members m where m.battle_id = b.id and m.clan_id = b.a_clan;
    select coalesce(sum(flx_window(m.user_id, b.start_day + 1)), 0) into sb from clan_battle_members m where m.battle_id = b.id and m.clan_id = b.b_clan;
    update clan_battles set a_score = sa, b_score = sb, settled_at = now(),
      winner_clan = case when sa > sb then b.a_clan when sb > sa then b.b_clan end where id = b.id;
  end loop;
end $$;
revoke execute on function public.flx_cb_settle(uuid, uuid) from anon, public, authenticated;

-- начать битву: лидер/заместитель; соперник должен участвовать в битвах; битва сразу у обоих кланов
create or replace function public.clan_battle_start(p_opponent uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; my_clan clans; opp clans; bid uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if flx_banned(auth.uid()) then raise exception 'flx_banned: аккаунт заблокирован модератором' using errcode = '42501'; end if;
  select * into me from profiles where id = auth.uid();
  if me.clan_id is null or me.clan_role not in ('leader', 'deputy') then raise exception 'Вызов может бросить лидер или заместитель'; end if;
  select * into my_clan from clans where id = me.clan_id for update;
  perform flx_cb_settle(me.clan_id, null);
  if exists (select 1 from clan_battles x where me.clan_id in (x.a_clan, x.b_clan) and x.settled_at is null and current_date < x.start_day + 8) then
    raise exception 'Битва уже идёт. Новую можно начать, когда она закончится';
  end if;
  if p_opponent is null then
    if my_clan.battle_open is false then raise exception 'Сначала включи «Клан участвует в битвах»'; end if;
    select c.* into opp from clans c
     where c.id <> me.clan_id and c.battle_open is not false
       and exists (select 1 from profiles p where p.clan_id = c.id)
       and not exists (select 1 from clan_battles x where c.id in (x.a_clan, x.b_clan) and x.settled_at is null and current_date < x.start_day + 8)
       and not exists (select 1 from clan_battles x where x.created_at > now() - interval '21 days'
                         and ((x.a_clan = me.clan_id and x.b_clan = c.id) or (x.b_clan = me.clan_id and x.a_clan = c.id)))
     order by random() limit 1 for update skip locked;
    if opp.id is null then raise exception 'Сейчас нет кланов, готовых к битве'; end if;
  else
    if p_opponent = me.clan_id then raise exception 'Нельзя вызвать свой клан'; end if;
    select * into opp from clans where id = p_opponent for update;
    if opp.id is null then raise exception 'Клан не найден'; end if;
    if opp.battle_open is false then raise exception 'Этот клан не участвует в битвах'; end if;
    if not exists (select 1 from profiles p where p.clan_id = opp.id) then raise exception 'В этом клане никого нет'; end if;
    perform flx_cb_settle(opp.id, null);
    if exists (select 1 from clan_battles x where opp.id in (x.a_clan, x.b_clan) and x.settled_at is null and current_date < x.start_day + 8) then
      raise exception 'У этого клана уже идёт битва';
    end if;
    if exists (select 1 from clan_battles x where x.created_at > now() - interval '21 days'
                 and ((x.a_clan = me.clan_id and x.b_clan = opp.id) or (x.b_clan = me.clan_id and x.a_clan = opp.id))) then
      raise exception 'С этим кланом уже была битва. Снова можно через 3 недели';
    end if;
  end if;
  insert into clan_battles(a_clan, b_clan, kind, created_by) values (me.clan_id, opp.id, case when p_opponent is null then 'random' else 'challenge' end, auth.uid())
    returning id into bid;
  insert into clan_battle_members(battle_id, user_id, clan_id)
    select bid, p.id, p.clan_id from profiles p where p.clan_id in (me.clan_id, opp.id) and not flx_banned(p.id);
  update clans set battle = null where id in (me.clan_id, opp.id);
  return jsonb_build_object('id', bid, 'opponent', opp.id, 'opponent_name', opp.name);
end $$;
grant execute on function public.clan_battle_start(uuid) to authenticated;

-- забрать итоги битв: каждая строка один раз; награда только участникам со старта, кто всё ещё в клане и тренировался
create or replace function public.clan_battle_claim() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan uuid; r record; v_my int; v_os int; v_res text; v_paid boolean; v_why text; v_out jsonb := '[]'::jsonb;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  perform flx_cb_settle(null, v_uid);
  select clan_id into v_clan from profiles where id = v_uid;
  for r in select b.*, m.clan_id as side from clan_battles b join clan_battle_members m on m.battle_id = b.id and m.user_id = v_uid
            where b.settled_at is not null and b.settled_at > now() - interval '30 days'
              and not exists (select 1 from clan_battle_results x where x.user_id = v_uid and x.battle_id = b.id)
            order by b.settled_at loop
    v_my := case when r.side = r.a_clan then r.a_score else r.b_score end;
    v_os := case when r.side = r.a_clan then r.b_score else r.a_score end;
    v_res := case when r.winner_clan is null then 'draw' when r.winner_clan = r.side then 'win' else 'loss' end;
    v_paid := false; v_why := null;
    if v_res = 'win' then
      v_why := case
        when coalesce(v_os, 0) <= 0 then 'opp_idle'
        when flx_window(v_uid, r.start_day + 1) <= 0 then 'me_idle'
        when v_clan is distinct from r.side then 'left_clan'
        when flx_banned(v_uid) then 'banned'
        when exists (select 1 from clan_battle_results x where x.user_id = v_uid and x.paid and x.created_at > now() - interval '6 days') then 'week_cap'
      end;
      v_paid := v_why is null;
    end if;
    insert into clan_battle_results(user_id, battle_id, clan_id, my_clan_score, opp_clan_score, result, paid, reason)
      values (v_uid, r.id, r.side, coalesce(v_my, 0), coalesce(v_os, 0), v_res, v_paid, v_why) on conflict do nothing;
    if found then
      v_out := v_out || jsonb_build_object('battle_id', r.id, 'opp_clan', case when r.side = r.a_clan then r.b_clan else r.a_clan end,
        'my_score', coalesce(v_my, 0), 'opp_score', coalesce(v_os, 0), 'result', v_res, 'paid', v_paid, 'reason', v_why);
    end if;
  end loop;
  return v_out;
end $$;
grant execute on function public.clan_battle_claim() to authenticated;

-- старое поле clans.battle больше не используется: приложение его не пишет, старые версии тоже не смогут
update public.clans set battle = null where battle is not null;
create or replace function public.clans_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  perform public.flx_check(new.name::text, new.description, new.about);
  if current_user in ('authenticated', 'anon') and tg_op = 'UPDATE' then
    new.id := old.id; new.leader_id := old.leader_id; new.code := old.code; new.created_at := old.created_at; new.name := old.name;
    new.capacity := least(greatest(coalesce(new.capacity, old.capacity), coalesce(old.capacity, 30)), coalesce(old.capacity, 30) + 10, 60);
    new.battle := null; -- v49: битвы только через clan_battle_start
  end if;
  return new;
end $$;

-- ---------- 3. Мелочи кланов ----------
-- заместитель выгоняет только обычных участников; лидер — любого, кроме себя
create or replace function public.clan_kick(p_member uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  select * into me from profiles where id = auth.uid();
  if me.clan_id is null or me.clan_role not in ('leader','deputy') then raise exception 'Нет прав'; end if;
  update profiles set clan_id = null, clan_role = 'member'
   where id = p_member and clan_id = me.clan_id and id <> auth.uid()
     and clan_role <> 'leader' and (me.clan_role = 'leader' or clan_role = 'member');
end $$;

-- вступление: забаненный не вступает, одновременные вступления не превышают число мест
create or replace function public.clan_join(p_code text) returns public.clans
language plpgsql security definer set search_path = public as $$
declare c public.clans; n int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if flx_banned(auth.uid()) then raise exception 'flx_banned: аккаунт заблокирован модератором' using errcode = '42501'; end if;
  if exists (select 1 from profiles where id = auth.uid() and clan_id is not null) then raise exception 'Сначала выйди из текущего клана'; end if;
  select * into c from clans where upper(clans.code) = upper(trim(p_code)) for update;
  if c.id is null then raise exception 'Клан с таким кодом не найден'; end if;
  select count(*) into n from profiles where clan_id = c.id;
  if n >= coalesce(c.capacity, 30) then raise exception 'Клан заполнен (%/%)', n, coalesce(c.capacity, 30); end if;
  update profiles set clan_id = c.id, clan_role = 'member', updated_at = now() where id = auth.uid();
  return c;
end $$;

revoke execute on function public.flx_window(uuid, date), public.flx_workout_days(uuid) from anon, public;
grant execute on function public.flx_window(uuid, date), public.flx_workout_days(uuid) to authenticated;
