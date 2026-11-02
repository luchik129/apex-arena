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
