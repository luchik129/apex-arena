-- v51: подписки (фолловеры) и уведомления об активности — лайки и комментарии к твоим постам, новые подписчики.
-- Запусти один раз в Supabase → SQL Editor (после update_v30.sql). Повторный запуск ничего не ломает.

-- 1. Подписки: кто на кого подписан
create table if not exists public.follows (
  follower_id uuid not null references auth.users(id) on delete cascade,
  followee_id uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (follower_id, followee_id),
  constraint follows_not_self check (follower_id <> followee_id)
);
create index if not exists follows_followee_idx on public.follows (followee_id, created_at desc);

alter table public.follows enable row level security;
drop policy if exists "follows read" on public.follows;
create policy "follows read" on public.follows for select to authenticated using (true);
drop policy if exists "follows insert own" on public.follows;
create policy "follows insert own" on public.follows for insert to authenticated
  with check (follower_id = auth.uid() and not public.flx_banned(auth.uid()));
drop policy if exists "follows delete own" on public.follows;
create policy "follows delete own" on public.follows for delete to authenticated using (follower_id = auth.uid());

-- 2. Время лайка (нужно, чтобы показать «кто и когда оценил»). Старым лайкам ставим время поста, чтобы они не пришли как новые.
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'post_likes' and column_name = 'created_at') then
    alter table public.post_likes add column created_at timestamptz;
    update public.post_likes l set created_at = p.created_at from public.posts p where p.id = l.post_id;
    update public.post_likes set created_at = now() where created_at is null;
    alter table public.post_likes alter column created_at set default now();
    alter table public.post_likes alter column created_at set not null;
  end if;
end $$;
create index if not exists post_likes_post_idx on public.post_likes (post_id, created_at desc);
create index if not exists post_comments_post_idx on public.post_comments (post_id, created_at desc);

-- 3. Активность для колокольчика: лайки и комментарии к моим постам + новые подписчики (с ником и аватаром автора)
create or replace function public.my_activity(p_limit int default 60) returns json
language sql stable security definer set search_path = public as $$
  with lim as (select greatest(1, least(coalesce(p_limit, 60), 150)) as n),
  a as (
    (select 'like'::text as kind, l.user_id as uid, l.post_id as post, null::uuid as ref, null::text as text,
            left(coalesce(nullif(p.body, ''), p.ex, ''), 80) as prev, p.kind as pkind, l.created_at as ts
       from post_likes l join posts p on p.id = l.post_id
      where p.user_id = auth.uid() and l.user_id <> auth.uid()
      order by l.created_at desc limit (select n from lim))
    union all
    (select 'comment', c.user_id, c.post_id, c.id, left(c.body, 160),
            left(coalesce(nullif(p.body, ''), p.ex, ''), 80), p.kind, c.created_at
       from post_comments c join posts p on p.id = c.post_id
      where p.user_id = auth.uid() and c.user_id <> auth.uid() and not coalesce(c.hidden, false)
      order by c.created_at desc limit (select n from lim))
    union all
    (select 'follow', f.follower_id, null::uuid, null::uuid, null::text, null::text, null::text, f.created_at
       from follows f
      where f.followee_id = auth.uid()
      order by f.created_at desc limit (select n from lim))
  )
  select coalesce(json_agg(row_to_json(t)), '[]'::json) from (
    select a.kind, a.uid, a.post, a.ref, a.text, a.prev, a.pkind, a.ts,
           pr.nickname as nick, pr.avatar, pr.sex, pr.arena_idx
      from a left join profiles pr on pr.id = a.uid
     where not public.flx_banned(a.uid)
     order by a.ts desc
     limit (select n from lim)
  ) t;
$$;
revoke all on function public.my_activity(int) from public, anon;
grant execute on function public.my_activity(int) to authenticated;
