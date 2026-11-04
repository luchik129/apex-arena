-- =====================================================================
-- Flexo League v41: поиск дуэли (очередь), передача лидерства в клане, дуэли открыты у всех
-- Запусти один раз в Supabase → SQL Editor (после update_v30.sql). Можно запускать повторно.
-- =====================================================================

alter table public.profiles add column if not exists battle_open boolean not null default true;

-- ---------- 1. Очередь поиска дуэли ----------
create table if not exists public.duel_queue (
  user_id uuid primary key references auth.users(id) on delete cascade,
  arena_idx int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.duel_queue enable row level security;
drop policy if exists "queue read" on public.duel_queue;
create policy "queue read" on public.duel_queue for select to authenticated using (true);  -- видно, сколько людей ищет
-- писать в очередь можно только через функции ниже

-- встать в поиск: если кто-то уже ждёт — сразу начинаем дуэль с ним, иначе ждём
create or replace function public.duel_queue_join(p_arena int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare opp uuid; did uuid;
begin
  if auth.uid() is null then raise exception 'Нужно войти'; end if;
  delete from duel_queue where updated_at < now() - interval '60 seconds';
  if exists (select 1 from duels d where d.status = 'active' and d.week_key::date > current_date - 7 and (d.a_id = auth.uid() or d.b_id = auth.uid())) then
    delete from duel_queue where user_id = auth.uid();
    raise exception 'У тебя уже идёт дуэль';
  end if;
  select q.user_id into opp from duel_queue q
   where q.user_id <> auth.uid()
     and not exists (select 1 from duels d where d.status = 'active' and d.week_key::date > current_date - 7 and (d.a_id = q.user_id or d.b_id = q.user_id))
   order by abs(q.arena_idx - p_arena), q.created_at limit 1 for update skip locked;
  if opp is not null then
    delete from duel_queue where user_id in (opp, auth.uid());
    insert into duels(week_key, a_id, b_id) values (current_date::text, opp, auth.uid()) returning id into did;
    update profiles set battle_open = true where id in (opp, auth.uid());
    return jsonb_build_object('matched', true, 'duel_id', did, 'opponent', opp);
  end if;
  insert into duel_queue(user_id, arena_idx) values (auth.uid(), p_arena)
    on conflict (user_id) do update set updated_at = now(), arena_idx = excluded.arena_idx;
  return jsonb_build_object('matched', false, 'waiting', (select count(*) from duel_queue where user_id <> auth.uid()));
end $$;

-- пока ищу: продлеваю ожидание и узнаю, не нашёлся ли соперник
create or replace function public.duel_queue_poll() returns jsonb
language plpgsql security definer set search_path = public as $$
declare did uuid; opp uuid;
begin
  update duel_queue set updated_at = now() where user_id = auth.uid();
  if found then return jsonb_build_object('matched', false, 'waiting', (select count(*) from duel_queue where user_id <> auth.uid() and updated_at > now() - interval '60 seconds')); end if;
  select d.id, case when d.a_id = auth.uid() then d.b_id else d.a_id end into did, opp from duels d
   where d.status = 'active' and (d.a_id = auth.uid() or d.b_id = auth.uid()) and d.created_at > now() - interval '10 minutes'
   order by d.created_at desc limit 1;
  if did is not null then return jsonb_build_object('matched', true, 'duel_id', did, 'opponent', opp); end if;
  return jsonb_build_object('matched', false, 'gone', true);
end $$;

create or replace function public.duel_queue_leave() returns void
language sql security definer set search_path = public as $$ delete from duel_queue where user_id = auth.uid(); $$;

grant execute on function public.duel_queue_join(int), public.duel_queue_poll(), public.duel_queue_leave() to authenticated;

-- ---------- 2. Передать лидерство в клане ----------
create or replace function public.clan_transfer_leader(p_member uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  select * into me from profiles where id = auth.uid();
  if me.clan_id is null or me.clan_role <> 'leader' then raise exception 'Передать лидерство может только лидер'; end if;
  if not exists (select 1 from profiles where id = p_member and clan_id = me.clan_id and id <> auth.uid()) then raise exception 'Игрок не в клане'; end if;
  update profiles set clan_role = 'leader' where id = p_member;
  update profiles set clan_role = 'deputy' where id = auth.uid();
  update clans set leader_id = p_member where id = me.clan_id;
end $$;
grant execute on function public.clan_transfer_leader(uuid) to authenticated;

-- ---------- 3. Случайные дуэли открыты у всех ----------
update public.profiles set battle_open = true where battle_open is distinct from true;
alter table public.profiles alter column battle_open set default true;
