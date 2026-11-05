-- v52: время сервера для честных кубков за день.
-- Приложение сверяет часы телефона с сервером: перевели часы — награды «за день» ждут, пока время снова станет честным.
-- Запусти один раз в Supabase → SQL Editor. Повторный запуск ничего не ломает.
create or replace function public.flx_now() returns timestamptz
language sql stable as $$ select now() $$;
revoke all on function public.flx_now() from public;
grant execute on function public.flx_now() to anon, authenticated;
