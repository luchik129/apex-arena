# Flexo League

Мобильное приложение: геймифицированный трекер силовых тренировок (арены, кубки, кланы, дуэли).

- `index.html` — веб-версия (одним файлом, библиотеки из CDN).
- `www/` — та же версия с локальными библиотеками для Android/iOS (собирается `./build_www.sh`).
- `docs/app/` — копия `www/` для веб-эмулятора (`docs/emu.html`).
- `android/` — проект Capacitor. APK собирается автоматически в GitHub Actions при каждом push в `main`
  и публикуется в разделе **Releases** (файл `apex-arena.apk`).
- `supabase/schema.sql` — схема базы Supabase (таблицы, RLS, функции кланов).

## Обновить приложение
1. Заменить `index.html`.
2. `./build_www.sh` (нужны пакеты chart.js, chartjs-adapter-date-fns, @supabase/supabase-js, tailwindcss@3 в `../vendor`) и `npx cap sync android`.
3. Push в `main` → через несколько минут новый APK в Releases.

## Эмулятор в браузере
https://luchik129.github.io/apex-arena/emu.html — приложение в рамке телефона, можно тыкать мышкой с компьютера.
Это копия `www/` в `docs/app/` (обновляется вместе с `www/`), GitHub Pages публикует её при каждом push.

## Ключ Gemini
Ключа нет ни в приложении, ни в репозитории: ИИ работает через edge-функции Supabase (`supabase/functions/gemini`, `ai-log`).
Ключ хранится в секрете `GEMINI_API_KEY` (Supabase → Edge Functions → Secrets).

## Админ-панель
https://luchik129.github.io/apex-arena/admin/ — проверка подозрительных подходов, жалобы, игроки, баны, кубки и монеты, посты, журнал, правила анти-чита.
Это отдельный сайт (`docs/admin/index.html`), в приложение он не попадает. Все права проверяются на сервере (`supabase/update_v30.sql`).

1. Запусти `supabase/update_v30.sql` в Supabase → SQL Editor.
2. Сделай себя владельцем (свой email из приложения):
   `insert into public.admins(user_id, role) select id, 'owner' from auth.users where email = 'ТВОЙ_EMAIL' on conflict (user_id) do update set role = 'owner';`
3. Для входа через Google добавь `https://luchik129.github.io/apex-arena/admin/` в Supabase → Authentication → URL Configuration → Redirect URLs (вход по email и паролю работает и без этого).

Как работает анти-чит: если e1RM подхода тяжелее порога × вес тела (жим 2.0×, присед 2.7×, тяга 3.0× и т.д.), выросло больше чем на 25% от прошлого рекорда или выше мирового рекорда, подход уходит на проверку. Пока он там, кубков нет и в рейтинг он не попадает (сервер держит старый рекорд, даже если приложение взломано). После решения в админке приложение игрока само начисляет кубки или удаляет подход.
