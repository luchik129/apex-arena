# Flexo League: маркетинговые агенты

Каждый день по расписанию запускается команда из трёх агентов (3 ролика в день). Порядок работы описан в `agents/PIPELINE.md`.

| Агент | Файл | Что делает |
|---|---|---|
| Аналитик | `.claude/agents/marketing-analyst.md` | собирает статистику прошлых роликов, пишет отчёт: что снимать больше, а что меньше |
| Сценарист | `.claude/agents/marketing-writer.md` | по отчёту каждый день пишет 3 сценария (JSON) |
| Монтажёр | `.claude/agents/marketing-editor.md` | рендерит, проверяет каждый кадр, исправляет, готовит видео и подписи |

Общие правила бренда (что можно и что нельзя обещать, аудитория, хуки) лежат в `agents/playbook.md`.

## Работа через Claude Code на компьютере
1. Один раз: `bash marketing/setup.sh` (нужны Node.js и ffmpeg: `brew install node ffmpeg`).
2. Открой репозиторий в Claude Code (`cd apex-arena && claude`).
3. Команда `/marketing-day` запускает всю команду. Например: `/marketing-day 3 больше смешных роликов про дуэли`.
4. Или зови агента напрямую: «попроси marketing-writer написать 3 сценария про кланы», «marketing-editor, сделай крупнее текст в ролике 05». Список агентов показывает `/agents`.
5. Видео будут в `marketing/data/days/<дата>/videos/`, подписи в `captions.md` там же.

## Где что лежит
- Код и промпты: в этом репозитории, папка `marketing/`.
- Данные: на компьютере `marketing/data/` (видео в git не попадают), в облачном проекте `/mnt/project-files/fitness/marketing/`. Там `log.json` (все ролики и их статистика), `stats/` (скриншоты аналитики), `reports/`, `days/<дата>/` (видео + `captions.md`).

## Движок
```
cd marketing/engine
OUT_DIR=/path node render.js ../examples/v01_ranked_gym.json            # mp4 + обложка
OUT_DIR=/path node render.js ../examples/v01_ranked_gym.json --preview  # кадры для проверки
python3 post.py <script.json> --when 2026-11-14T17:00:00                # Upload-Post, пробный прогон
python3 post.py <script.json> --when 2026-11-14T17:00:00 --confirm      # реальная отправка (только после ОК владельца)
```
Нужны Node + Playwright, ffmpeg, Python с numpy. Музыка синтезируется (`beat.py`), авторских прав нет.

## Публикация
Пока владелец выкладывает вручную: скачивает видео из треда и копирует подпись из `captions.md`.
Автопостинг: Upload-Post (Basic, $24/мес) подключает TikTok, Instagram и YouTube через одно API.
Напрямую через API соцсетей сложнее: TikTok без аудита публикует только приватно, Instagram требует Meta-приложение и бизнес-аккаунт, YouTube без проверки загружает только приватно.
Ключи передаются только через переменные окружения `UPLOAD_POST_API_KEY` и `UPLOAD_POST_USER`.
