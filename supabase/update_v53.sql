-- v53: уровень рекорда в постах (бронза … легенда) — по силе относительно веса тела, считает приложение автора.
-- Запусти один раз в Supabase → SQL Editor. Повторный запуск ничего не ломает.
alter table public.posts add column if not exists pr_tier smallint;
alter table public.posts drop constraint if exists posts_pr_tier_range;
alter table public.posts add constraint posts_pr_tier_range check (pr_tier is null or pr_tier between 0 and 5);
