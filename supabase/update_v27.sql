-- =====================================================================
-- Flexo League v27: анти-чит и фильтр мата на сервере
-- Запусти один раз в Supabase → SQL Editor (после update_v19…v24).
-- Можно запускать повторно: всё через create or replace / drop if exists.
-- =====================================================================

-- ---------- 1. Фильтр мата (рус + англ, обходы латиницей/цифрами/точками) ----------
create or replace function public.flx_bad(p text) returns boolean
language plpgsql immutable set search_path = public as $$
declare
  s text; tok text; c text; l text;
  ru text := '^(на|по|ни|от|ото|до|за|под|при|про|пере|недо|вы|у|о|об|обо|раз|рас|из|ис|с|со|долбо|мудо|а)?(ху[йиеяю]|[ъь]?еб(а|у|л|н|и|о|ш|ь|е|ы|т|к|ч|с|$)|бл[яэ](д|ть|т|$)|бл[яа]д[ьи]|с?сук(а|и|е|у|ой|ам|ами|ах)$|сучк|сучар|сукин|муд(ак|ач|ил|оз)|педик|педр[иа]л|чмо($|ш)|мраз[ьи]|гнид[аы]|уеб|еблан|(деб|диб)ил|идиот|кретин|чурк|тупорыл|манд(а|у|ой|ы|е)$|хул[иь]$|хер$|нахер|похер)';
  ru_any text := '(пи[зс]д|пе[зс]д|бляд|ебуч|ебл[аои]|пид[оа]р|пидр|гандон|гондон($|[^д])|шлюх|шалав|залуп|дроч|херн|ублюд|нигг?ер)';
  en text := '(fu?ck|fck|fuk|motherf|shit|cunt|bitch|as+hole|nig+(er|a)|fag+ot|^fag+s?$|whore|^slut|retard|^wank|^twat|bastard|^idiot|^moron|pi[zs]d|pe[zs]d|bl[yj]at|bl[yj]ad|^bl[yj]a$|xu[yj]|^(na|po|ni|ot|o|a)?(x|h|kh)u(y|j|ya|yu|ilo)|pid[oa]r|pidr|^mudak|zalup|g[ao]nd[oa]n|shl[yj]?u[hx]|dolbo|^s+uka$|^suchk|^cock(s|sucker)?$|^dick(s|head)?$|^(na|po|za|vy|u|ot|do)?y?eb(a[lnt]|an|al|ash|lo|nu))';
  ok text := '^(себ|страху|застраху|хулиг|хула|рубля|корабля|сабля|сукно|мандарин|мандат|херсон|херес|херувим|оскорбля|скипидар|потребля|употребля|ебург|ebay|shitake|cocktail|cockpit|dickens|scunthorpe|assassin)';
begin
  if p is null or p = '' then return false; end if;
  s := replace(lower(p), 'ё', 'е');
  -- знаки внутри слова: «п.и.з.д.а», «х*й»
  s := regexp_replace(s, '([[:alnum:]@$])[-.\_*''`~+|/\\]+(?=[[:alnum:]@$])', '\1', 'g');
  for tok in select x from regexp_split_to_table(s, '[^[:alnum:]@$!|]+') x loop
    continue when tok = '' or tok ~ ok;
    if tok ~ '[а-я]' then
      c := regexp_replace(translate(tok, 'abcehkmoptxyui03461@$', 'авсенкмортхуииозчбиас'), '[^а-я]', '', 'g');
      c := regexp_replace(c, '(.)\1+', '\1', 'g');
      if c ~ ru or c ~ ru_any then return true; end if;
    else
      l := regexp_replace(translate(tok, '01!3457@$|', 'oiieastasl'), '[^a-z]', '', 'g');
      l := regexp_replace(l, '(.)\1\1+', '\1', 'g');
      if l ~ en then return true; end if;
      c := regexp_replace(translate(l, 'abcehkmoptxyu', 'авсенкмортхуи'), '(.)\1+', '\1', 'g');
      if c ~ ru or c ~ ru_any then return true; end if;
    end if;
  end loop;
  -- «х у й» и «п и з д а» через пробел
  c := regexp_replace(translate(s, 'abcehkmoptxyui03461@$', 'авсенкмортхуииозчбиас'), '[^а-я]', '', 'g');
  if regexp_replace(c, '(.)\1+', '\1', 'g') ~ '(пи[зс]д|бляд|еблан|пид[оа]р|залуп|гандон)' then return true; end if;
  return false;
end $$;

create or replace function public.flx_check(variadic xs text[]) returns void
language plpgsql immutable set search_path = public as $$
declare x text;
begin
  foreach x in array xs loop
    if public.flx_bad(x) then raise exception 'flx_bad_words: текст нарушает правила сообщества' using errcode = '22023'; end if;
  end loop;
end $$;

-- посты, комментарии, лента рекордов
create or replace function public.flx_text_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_table_name = 'posts' then perform public.flx_check(new.body, new.ex);
  elsif tg_table_name = 'post_comments' then perform public.flx_check(new.body);
  elsif tg_table_name = 'feed' then perform public.flx_check(new.ex);
  end if;
  return new;
end $$;
drop trigger if exists posts_text_guard on public.posts;
create trigger posts_text_guard before insert or update on public.posts for each row execute function public.flx_text_guard();
drop trigger if exists comments_text_guard on public.post_comments;
create trigger comments_text_guard before insert or update on public.post_comments for each row execute function public.flx_text_guard();
drop trigger if exists feed_text_guard on public.feed;
create trigger feed_text_guard before insert or update on public.feed for each row execute function public.flx_text_guard();

-- ---------- 2. Профиль: нельзя самому назначить себя лидером клана, накрутить дуэли и т.п. ----------
create or replace function public.profiles_guard()
returns trigger language plpgsql set search_path = public as $$
declare
  v_caps jsonb := '{"bench":355,"squat":490,"deadlift":505}';
  v_gain int; v_arena int; v_days jsonb := '{}'::jsonb; k text; v jsonb;
  v_client boolean := current_user in ('authenticated', 'anon'); -- прямой запрос из приложения (не функция сервера)
begin
  if auth.uid() is null and not v_client then return new; end if;
  -- текст: мат в нике и титуле
  perform public.flx_check(new.nickname, new.title);
  if new.nickname is not null and length(trim(new.nickname)) not between 2 and 16 then raise exception 'Ник от 2 до 16 символов'; end if;
  if new.title is not null then new.title := left(new.title, 24); end if;

  new.bests := coalesce((select jsonb_object_agg(b.key, least(b.value::numeric, 600)) from jsonb_each_text(coalesce(new.bests, '{}'::jsonb)) b where b.value ~ '^[0-9]+(\.[0-9]+)?$'), '{}'::jsonb);
  new.boss := coalesce((select jsonb_object_agg(b.key, least(b.value::numeric, coalesce((v_caps ->> b.key)::numeric, 600))) from jsonb_each_text(coalesce(new.boss, '{}'::jsonb)) b where b.value ~ '^[0-9]+(\.[0-9]+)?$'), '{}'::jsonb);
  if new.avatar is not null and length(new.avatar) > 40000 then new.avatar := null; end if;
  new.level := least(greatest(coalesce(new.level, 1), 1), 300);
  new.power_score := least(greatest(coalesce(new.power_score, 0), 0), 100000);

  -- клан и код друга меняются только через функции сервера (clan_new / clan_join / clan_leave / clan_kick / clan_set_role)
  if v_client then
    if tg_op = 'INSERT' then new.clan_id := null; new.clan_role := 'member';
    else new.clan_id := old.clan_id; new.clan_role := old.clan_role; new.friend_code := coalesce(old.friend_code, new.friend_code);
    end if;
  end if;

  -- дни для дуэлей и битв кланов: добавлять можно только сегодня/вчера (по UTC ±1), прошлое не переписать
  for k, v in select key, value from jsonb_each(case when jsonb_typeof(new.days) = 'object' then new.days else '{}'::jsonb end) loop
    continue when k !~ '^\d{4}-\d{2}-\d{2}$';
    continue when k::date < current_date - 40 or k::date > current_date + 1;
    if tg_op = 'UPDATE' and k::date < current_date - 2 then
      if old.days ? k then v_days := v_days || jsonb_build_object(k, old.days -> k); end if;
      continue;
    end if;
    if tg_op = 'INSERT' and k::date < current_date - 2 then continue; end if;
    v_days := v_days || jsonb_build_object(k, jsonb_build_object(
      'w', case when coalesce((v ->> 'w'), '0') ~ '^[1-9]' then 1 else 0 end,
      'p', least(greatest(coalesce(nullif(regexp_replace(coalesce(v ->> 'p', '0'), '[^0-9]', '', 'g'), '')::int, 0), 0), 3)));
  end loop;
  if tg_op = 'UPDATE' and jsonb_typeof(old.days) = 'object' then -- старые дни, которые клиент «забыл», сохраняем
    for k, v in select key, value from jsonb_each(old.days) loop
      if k ~ '^\d{4}-\d{2}-\d{2}$' and k::date >= current_date - 40 and k::date < current_date - 2 and not v_days ? k then v_days := v_days || jsonb_build_object(k, v); end if;
    end loop;
  end if;
  new.days := v_days;
  new.week := public.flx_week(new.week); new.prev_week := public.flx_week(new.prev_week);

  -- кубки: не больше 150 в день (честный максимум около 130)
  if tg_op = 'INSERT' then
    new.trophies := least(greatest(coalesce(new.trophies, 0), 0), 100);
    new.trophy_day := current_date;
    new.trophy_gain := new.trophies;
  elsif new.trophies > old.trophies then
    v_gain := case when old.trophy_day = current_date then coalesce(old.trophy_gain, 0) else 0 end;
    new.trophies := least(new.trophies, old.trophies + greatest(0, 150 - v_gain));
    new.trophy_gain := v_gain + (new.trophies - old.trophies);
    new.trophy_day := current_date;
  else
    new.trophy_day := old.trophy_day;
    new.trophy_gain := old.trophy_gain;
  end if;
  select count(*) - 1 into v_arena from unnest(array[0, 300, 800, 1500, 2500, 4000, 6000, 9000, 12000, 14000, 16500, 19000, 22000, 25000, 28500, 32000, 36000]) m where m <= new.trophies;
  new.arena_idx := least(greatest(coalesce(new.arena_idx, 0), 0), v_arena);
  return new;
end $$;

create or replace function public.flx_week(w jsonb) returns jsonb
language sql immutable set search_path = public as $$
  select case when jsonb_typeof(w) = 'object' then jsonb_build_object(
    'workouts', least(greatest(coalesce(nullif(regexp_replace(coalesce(w ->> 'workouts', '0'), '[^0-9]', '', 'g'), '')::int, 0), 0), 7),
    'prs', least(greatest(coalesce(nullif(regexp_replace(coalesce(w ->> 'prs', '0'), '[^0-9]', '', 'g'), '')::int, 0), 0), 21),
    'streak', least(greatest(coalesce(nullif(regexp_replace(coalesce(w ->> 'streak', '0'), '[^0-9]', '', 'g'), '')::int, 0), 0), 3650))
  else '{"workouts":0,"prs":0,"streak":0}'::jsonb end;
$$;

-- ---------- 3. Клан: заместитель не может забрать лидерство и код ----------
create or replace function public.clans_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  perform public.flx_check(new.name::text, new.description, new.about);
  if current_user in ('authenticated', 'anon') and tg_op = 'UPDATE' then
    new.id := old.id; new.leader_id := old.leader_id; new.code := old.code; new.created_at := old.created_at; new.name := old.name;
    new.capacity := least(greatest(coalesce(new.capacity, old.capacity), coalesce(old.capacity, 30)), coalesce(old.capacity, 30) + 10, 60);
  end if;
  return new;
end $$;
drop trigger if exists clans_guard on public.clans;
create trigger clans_guard before insert or update on public.clans for each row execute function public.clans_guard();

-- ---------- 4. Дуэли: участник может только отменить, а не переписать дуэль ----------
create or replace function public.duels_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    new.status := 'active'; new.created_at := now();
    if new.week_key !~ '^\d{4}-\d{2}-\d{2}$' or new.week_key::date not between current_date - 1 and current_date + 1 then new.week_key := current_date::text; end if;
    if exists (select 1 from duels d where d.status = 'active' and d.week_key::date > current_date - 7
               and ((d.a_id = new.a_id and d.b_id = new.b_id) or (d.a_id = new.b_id and d.b_id = new.a_id))) then
      raise exception 'С этим игроком уже идёт дуэль';
    end if;
    if (select count(*) from duels d where d.a_id = new.a_id and d.created_at > now() - interval '7 days') >= 3 then
      raise exception 'Не больше 3 вызовов в неделю';
    end if;
  else
    new.id := old.id; new.a_id := old.a_id; new.b_id := old.b_id; new.week_key := old.week_key; new.created_at := old.created_at;
    if new.status <> old.status and not (old.status = 'active' and new.status = 'cancelled') then new.status := old.status; end if;
  end if;
  return new;
end $$;
drop trigger if exists duels_guard on public.duels;
create trigger duels_guard before insert or update on public.duels for each row execute function public.duels_guard();

-- ---------- 5. Друзья: только через заявку (friend_request → friend_respond) ----------
drop policy if exists "friends own" on public.friendships;
drop policy if exists "friends read own" on public.friendships;
drop policy if exists "friends delete own" on public.friendships;
create policy "friends read own" on public.friendships for select to authenticated using (user_id = auth.uid());
create policy "friends delete own" on public.friendships for delete to authenticated using (user_id = auth.uid());

-- ---------- 6. Скрытые комментарии не видны другим ----------
drop policy if exists "comments read" on public.post_comments;
create policy "comments read" on public.post_comments for select to authenticated using ((not hidden) or user_id = auth.uid());

-- ---------- 7. Жалобы: автоскрытие только по 3 жалобам от аккаунтов старше 3 дней ----------
create or replace function public.flx_report_weight(p_target uuid) returns int
language sql stable security definer set search_path = public, auth as $$
  select count(*)::int from reports r join auth.users u on u.id = r.reporter_id
  where r.target_id = p_target and u.created_at < now() - interval '3 days';
$$;
create or replace function public.report_hide() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.target_kind = 'post' and public.flx_report_weight(new.target_id) >= 3 then update posts set hidden = true where id = new.target_id; end if;
  return null;
end $$;
create or replace function public.reports_hide_comment() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.target_kind = 'comment' and public.flx_report_weight(new.target_id) >= 3 then update post_comments set hidden = true where id = new.target_id; end if;
  return new;
end $$;

-- ---------- 8. Рефералы: засчитываем только после 3 настоящих дней тренировок ----------
create or replace function public.referral_qualify() returns void
language sql security definer set search_path = public, auth as $$
  update referrals set qualified = true
  where referee = auth.uid() and not qualified
    and (select created_at from auth.users where id = auth.uid()) < now() - interval '2 days'
    and (select count(*) from profiles p, jsonb_each(coalesce(p.days, '{}'::jsonb)) d where p.id = auth.uid() and (d.value ->> 'w') = '1') >= 3;
$$;

-- ---------- 9. ИИ: лимит считается по дате сервера (раньше можно было брать лимит «вчера» и «завтра») ----------
create or replace function public.ai_day(p_day date) returns date
language sql stable set search_path = public as $$ select (now() at time zone 'utc')::date; $$;
create or replace function public.ai_limit(p_kind text) returns integer
language sql immutable set search_path = public as $$ select case p_kind when 'food' then 3 when 'activity' then 2 else 40 end; $$;

-- ---------- 10. Права: гостям (anon) функции не нужны, триггерные функции никому не вызывать напрямую ----------
alter function public.touch_updated_at() set search_path = public;
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig, p.prorettype = 'trigger'::regtype as trg from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e') loop
    execute format('revoke execute on function %s from anon, public', f.sig);
    if f.trg then execute format('revoke execute on function %s from authenticated', f.sig);
    else execute format('grant execute on function %s to authenticated, service_role', f.sig); end if;
  end loop;
end $$;
revoke execute on function public.ai_quota_use(uuid, text, date) from authenticated;
revoke execute on function public.ai_quota_refund(uuid, text, date) from authenticated;
revoke execute on function public.flx_report_weight(uuid) from authenticated;
grant execute on function public.nick_available(text) to anon; -- проверка ника на экране регистрации

notify pgrst, 'reload schema';
