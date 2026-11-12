-- v76: поиск соперника по рангу.
-- В очереди может сидеть сколько угодно людей. Сервер сам подбирает ближайшего по кубкам:
-- сначала в пределах ±150 кубков, и с каждой секундой ожидания круг шире на 15 кубков (через минуту — ±1050).
-- Подбор пробуется и при входе в очередь, и при каждом опросе, поэтому пара находится, даже если оба уже ждали.
-- Запусти один раз в Supabase → SQL Editor (после update_v41.sql; update_v75.sql — по желанию, порядок не важен).

alter table public.duel_queue add column if not exists trophies int not null default 0;

-- общая часть: найти пару для меня или встать в очередь
create or replace function public.duel_queue_match(p_me uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare mine duel_queue; opp uuid; did uuid;
begin
  select * into mine from duel_queue where user_id = p_me for update;
  if mine.user_id is null then return null; end if;
  select q.user_id into opp from duel_queue q
   where q.user_id <> p_me and q.updated_at > now() - interval '60 seconds'
     and not exists (select 1 from duels d where d.status = 'active' and d.week_key::date > current_date - 7 and (d.a_id = q.user_id or d.b_id = q.user_id))
     and abs(q.trophies - mine.trophies) <= 150 + 15 * extract(epoch from now() - least(q.created_at, mine.created_at))
   order by abs(q.trophies - mine.trophies), q.created_at
   limit 1 for update skip locked;
  if opp is null then return null; end if;
  delete from duel_queue where user_id in (opp, p_me);
  insert into duels(week_key, a_id, b_id) values (current_date::text, opp, p_me) returning id into did;
  update profiles set battle_open = true where id in (opp, p_me);
  return jsonb_build_object('matched', true, 'duel_id', did, 'opponent', opp);
end $$;
revoke all on function public.duel_queue_match(uuid) from public, anon, authenticated;

create or replace function public.duel_queue_join(p_arena int, p_trophies int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if auth.uid() is null then raise exception 'Нужно войти'; end if;
  delete from duel_queue where updated_at < now() - interval '60 seconds';
  if exists (select 1 from duels d where d.status = 'active' and d.week_key::date > current_date - 7 and (d.a_id = auth.uid() or d.b_id = auth.uid())) then
    delete from duel_queue where user_id = auth.uid();
    raise exception 'У тебя уже идёт дуэль';
  end if;
  insert into duel_queue(user_id, arena_idx, trophies) values (auth.uid(), p_arena, greatest(0, least(p_trophies, 1000000)))
    on conflict (user_id) do update set updated_at = now(), arena_idx = excluded.arena_idx, trophies = excluded.trophies;
  r := duel_queue_match(auth.uid());
  if r is not null then return r; end if;
  return jsonb_build_object('matched', false, 'waiting', (select count(*) from duel_queue where user_id <> auth.uid() and updated_at > now() - interval '60 seconds'));
end $$;

-- опрос: продлеваю ожидание, пробую подобрать пару (круг уже шире) и узнаю, не нашёл ли меня кто-то
create or replace function public.duel_queue_poll() returns jsonb
language plpgsql security definer set search_path = public as $$
declare did uuid; opp uuid; r jsonb;
begin
  update duel_queue set updated_at = now() where user_id = auth.uid();
  if found then
    r := duel_queue_match(auth.uid());
    if r is not null then return r; end if;
    return jsonb_build_object('matched', false, 'waiting', (select count(*) from duel_queue where user_id <> auth.uid() and updated_at > now() - interval '60 seconds'));
  end if;
  select d.id, case when d.a_id = auth.uid() then d.b_id else d.a_id end into did, opp from duels d
   where d.status = 'active' and (d.a_id = auth.uid() or d.b_id = auth.uid()) and d.created_at > now() - interval '10 minutes'
   order by d.created_at desc limit 1;
  if did is not null then return jsonb_build_object('matched', true, 'duel_id', did, 'opponent', opp); end if;
  return jsonb_build_object('matched', false, 'gone', true);
end $$;

grant execute on function public.duel_queue_join(int, int), public.duel_queue_poll() to authenticated;
