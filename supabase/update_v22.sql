-- APEX Arena v22: удаление аккаунта из приложения (требование App Store 5.1.1(v) и Google Play).
-- Запускать после update_v19.sql, update_v20.sql и update_v21.sql. Повторный запуск безопасен.

create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  -- если игрок лидер клана, лидерство переходит заместителю или самому сильному участнику
  perform public.clan_leave();
  -- всё остальное (профиль, прогресс, посты, лайки, комментарии, жалобы, дружба, дуэли) удаляется каскадом
  delete from auth.users where id = v_uid;
end $$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- комментарий с 3 жалобами скрывается сразу (как посты)
alter table public.post_comments add column if not exists hidden boolean not null default false;
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'post_comments' and column_name = 'hidden') then
    execute $f$
      create or replace function public.reports_hide_comment() returns trigger language plpgsql security definer set search_path = public as $b$
      begin
        if new.target_kind = 'comment' and (select count(*) from reports r where r.target_id = new.target_id) >= 3 then
          update post_comments set hidden = true where id = new.target_id;
        end if;
        return new;
      end $b$;
    $f$;
    drop trigger if exists reports_hide_comment on public.reports;
    create trigger reports_hide_comment after insert on public.reports for each row execute function public.reports_hide_comment();
  end if;
end $$;
