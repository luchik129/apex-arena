-- Flexo League v23: просмотры видео, реферальные приглашения, весовые категории.
-- Запускать после update_v19.sql … update_v22.sql. Повторный запуск безопасен.

-- 1) Просмотры видео: один человек = один просмотр
alter table public.posts add column if not exists view_count int not null default 0;
create table if not exists public.post_views (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
alter table public.post_views enable row level security;
drop policy if exists post_views_own on public.post_views;
create policy post_views_own on public.post_views for select using (user_id = auth.uid());

create or replace function public.post_view(p_post uuid) returns int
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_n int;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  insert into post_views(post_id, user_id) values (p_post, v_uid) on conflict do nothing;
  if found then update posts set view_count = view_count + 1 where id = p_post returning view_count into v_n;
  else select view_count into v_n from posts where id = p_post; end if;
  return coalesce(v_n, 0);
end $$;
revoke all on function public.post_view(uuid) from public, anon;
grant execute on function public.post_view(uuid) to authenticated;

-- 2) Весовая категория (только категория, точный вес другим не виден)
alter table public.profiles add column if not exists weight_class text;

-- 3) Реферальные приглашения
create table if not exists public.referrals (
  referee uuid primary key references auth.users(id) on delete cascade,   -- кого пригласили (один раз)
  referrer uuid not null references auth.users(id) on delete cascade,     -- кто пригласил
  qualified boolean not null default false,                              -- приглашённый сделал 3 тренировки
  paid boolean not null default false,                                   -- пригласивший забрал бонус
  created_at timestamptz not null default now()
);
create index if not exists referrals_referrer_idx on public.referrals(referrer);
alter table public.referrals enable row level security;
drop policy if exists referrals_read on public.referrals;
create policy referrals_read on public.referrals for select using (referrer = auth.uid() or referee = auth.uid());

-- приглашённый вводит код друга (friend_code) в первые 7 дней после регистрации
create or replace function public.referral_claim(p_code text) returns text
language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid := auth.uid(); v_ref uuid; v_created timestamptz;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  select id into v_ref from profiles where upper(friend_code) = upper(trim(p_code));
  if v_ref is null then return 'not_found'; end if;
  if v_ref = v_uid then return 'self'; end if;
  if exists (select 1 from referrals where referee = v_uid) then return 'already'; end if;
  if exists (select 1 from referrals where referee = v_ref and referrer = v_uid) then return 'mutual'; end if;
  select created_at into v_created from auth.users where id = v_uid;
  if v_created < now() - interval '7 days' then return 'too_late'; end if;
  if (select count(*) from referrals where referrer = v_ref and created_at > now() - interval '1 day') >= 20 then return 'limit'; end if;
  insert into referrals(referee, referrer) values (v_uid, v_ref);
  return 'ok';
end $$;

-- приглашённый сделал 3 засчитанные тренировки
create or replace function public.referral_qualify() returns void
language sql security definer set search_path = public as $$
  update referrals set qualified = true where referee = auth.uid() and not qualified;
$$;

-- пригласивший забирает бонус (по одному разу за каждого друга)
create or replace function public.referral_collect() returns setof uuid
language sql security definer set search_path = public as $$
  update referrals set paid = true where referrer = auth.uid() and qualified and not paid returning referee;
$$;

revoke all on function public.referral_claim(text) from public, anon;
revoke all on function public.referral_qualify() from public, anon;
revoke all on function public.referral_collect() from public, anon;
grant execute on function public.referral_claim(text) to authenticated;
grant execute on function public.referral_qualify() to authenticated;
grant execute on function public.referral_collect() to authenticated;
