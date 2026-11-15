-- v73: рейды на Титана (один или с друзьями, до 4 человек на неделю)
create table if not exists public.raids (
  id uuid primary key default gen_random_uuid(),
  week_key text not null,
  owner_id uuid not null references auth.users(id) on delete cascade,
  members jsonb not null default '[]'::jsonb,
  open boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists raids_week_idx on public.raids(week_key);
alter table public.raids enable row level security;

drop policy if exists raids_select on public.raids;
create policy raids_select on public.raids for select to authenticated using (true);

-- создать можно только свой рейд, в котором ты единственный участник
drop policy if exists raids_insert on public.raids;
create policy raids_insert on public.raids for insert to authenticated
  with check (owner_id = auth.uid() and jsonb_array_length(members) = 1 and members->0->>'id' = auth.uid()::text
    and not exists (select 1 from public.raids r where r.week_key = raids.week_key and r.members @> jsonb_build_array(jsonb_build_object('id', auth.uid()::text))));

create or replace function public.raid_join(p_raid uuid, p_hp int, p_from text)
returns void language plpgsql security definer set search_path = public as $$
declare r public.raids; me text := auth.uid()::text;
begin
  if auth.uid() is null then raise exception 'Нужен вход'; end if;
  select * into r from public.raids where id = p_raid for update;
  if not found then raise exception 'Рейд не найден'; end if;
  if not r.open then raise exception 'Рейд закрыт'; end if;
  if jsonb_array_length(r.members) >= 4 then raise exception 'В рейде уже 4 человека'; end if;
  if exists (select 1 from public.raids x where x.week_key = r.week_key and x.members @> jsonb_build_array(jsonb_build_object('id', me))) then
    raise exception 'Ты уже в рейде на этой неделе';
  end if;
  update public.raids set members = members || jsonb_build_array(jsonb_build_object('id', me, 'hp', greatest(300, least(20000, coalesce(p_hp, 300))), 'from', p_from)),
    open = jsonb_array_length(members) + 1 < 4
  where id = p_raid;
end $$;

create or replace function public.raid_leave(p_raid uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me text := auth.uid()::text; left_ jsonb;
begin
  select coalesce(jsonb_agg(m), '[]'::jsonb) into left_ from public.raids r, jsonb_array_elements(r.members) m
    where r.id = p_raid and m->>'id' <> me;
  if jsonb_array_length(left_) = 0 then delete from public.raids where id = p_raid;
  else update public.raids set members = left_, open = true,
    owner_id = case when owner_id = auth.uid() then (left_->0->>'id')::uuid else owner_id end where id = p_raid;
  end if;
end $$;

revoke all on function public.raid_join(uuid, int, text) from public;
revoke all on function public.raid_leave(uuid) from public;
grant execute on function public.raid_join(uuid, int, text) to authenticated;
grant execute on function public.raid_leave(uuid) to authenticated;
grant select, insert on public.raids to authenticated;
