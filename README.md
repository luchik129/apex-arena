# Flexo League

Мобильное приложение: геймифицированный трекер силовых тренировок (арены, кубки, кланы, дуэли, питание).

## Что где лежит
- `index.html` — всё приложение одним файлом (веб-версия, библиотеки из CDN).
- `www/` — та же версия с локальными библиотеками для телефонов (собирается `./build_www.sh`).
- `android/` — проект Capacitor для Android.
- `ios/` — проект Capacitor для iPhone.
- `docs/` — страницы на GitHub Pages: политика конфиденциальности, удаление аккаунта, подтверждение почты, приглашения.
- `supabase/schema.sql` — схема базы; `supabase/update_vNN.sql` — обновления по порядку; `supabase/functions/` — Edge Functions (ai-log, gemini, snap-userinfo); `supabase/email/` — шаблон письма.

## Сборки (GitHub Actions)
- **Android:** при каждом push в `main` собирается APK и публикуется в **Releases** (`apex-arena.apk`).
  Если в Secrets есть `ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, рядом появится подписанный `flexo-league.aab` для Google Play.
- **iPhone:** при push в `main` проект собирается на Mac. Если в Secrets есть `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, сборка уходит в TestFlight.
- **Pages:** папка `docs/` публикуется на luchik129.github.io/apex-arena.

## Обновить приложение
1. Заменить `index.html`.
2. `./build_www.sh`, затем `npx cap sync`.
3. Push в `main`.

## Ключ Gemini
Ключа в приложении и в репозитории нет. Он хранится только в Supabase → Edge Functions → Secrets под именем `GEMINI_API_KEY`.
