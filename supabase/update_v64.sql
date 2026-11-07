-- Flexo League v64: экономия трафика рейтинга и кланов.
-- Приложение хранит список игроков и кланов на телефоне и качает с сервера только изменения.
-- Для этого нужны «отпечатки» картинок (md5) и время изменения клана. Запускать один раз в SQL Editor.
-- Безопасно запускать повторно. Старые версии приложения продолжают работать как раньше.

-- отпечаток аватарки: меняется только когда игрок поменял аватар
alter table public.profiles add column if not exists avatar_v text generated always as (md5(coalesce(avatar, ''))) stored;
-- отпечаток картинки клана
alter table public.clans add column if not exists photo_v text generated always as (md5(coalesce(photo, ''))) stored;
-- время последнего изменения клана
alter table public.clans add column if not exists updated_at timestamptz not null default now();
drop trigger if exists clans_touch on public.clans;
create trigger clans_touch before update on public.clans for each row execute function public.touch_updated_at();

-- быстрый поиск «что изменилось с прошлого раза»
create index if not exists profiles_updated_at_idx on public.profiles (updated_at);
create index if not exists clans_updated_at_idx on public.clans (updated_at);

notify pgrst, 'reload schema';
