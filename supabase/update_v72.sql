-- v72: подписки убраны из приложения, вместо них в профилях показывается число друзей.
-- Политика "friends read own" не даёт читать чужие строки friendships, поэтому число друзей
-- другого игрока отдаёт эта функция (только количество, без списка).
create or replace function public.friend_count(p_user uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int from public.friendships where user_id = p_user;
$$;

revoke all on function public.friend_count(uuid) from public;
grant execute on function public.friend_count(uuid) to authenticated;

-- Таблицу follows не удаляем: приложение её больше не читает и не пишет.
