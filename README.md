# APEX Arena

Мобильное приложение: геймифицированный трекер силовых тренировок (арены, кубки, кланы, дуэли).

- `index.html` — веб-версия (одним файлом, библиотеки из CDN).
- `www/` — та же версия с локальными библиотеками для Android (собирается `./build_www.sh`).
- `android/` — проект Capacitor. APK собирается автоматически в GitHub Actions при каждом push в `main`
  и публикуется в разделе **Releases** (файл `apex-arena.apk`).
- `supabase/schema.sql` — схема базы Supabase (таблицы, RLS, функции кланов).

## Обновить приложение
1. Заменить `index.html`.
2. `./build_www.sh` (нужны пакеты chart.js, chartjs-adapter-date-fns, @supabase/supabase-js, tailwindcss@3 в `../vendor`) и `npx cap sync android`.
3. Push в `main` → через несколько минут новый APK в Releases.

## Ключ Gemini
В репозитории ключа нет (GitHub запрещает секреты в коде). Добавь его в Settings → Secrets and variables → Actions → New repository secret: имя `GEMINI_KEY`. Сборка подставит его в приложение.
