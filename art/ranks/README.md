# Иконки рангов

`src/rNN.jpg` — исходник медали ранга на чёрном фоне, где `NN` = `id` арены из `CONFIG.ARENAS`.
Команда `python3 art/ranks/build_icons.py` делает фон прозрачным, сжимает картинки в WebP 288×288 и
записывает строку `RANK_ICONS` в `index.html`. После неё `art/ranks/sync.sh` обновляет `www/` и `docs/app/`.

Картинки-медали включаются только целым набором из 17 штук. Пока набор неполный, используются векторные медали `UI.rankArt`.

## Как сделан набор (Higgsfield, GPT Image 2.5, качество high, 1:1)

Сначала сгенерированы эталоны: ранг 4 и ранг 9. Остальные ранги генерировались с этими двумя
эталонами в качестве референсов и с общим началом промпта:

> Mobile game rank badge icon from the same set as the two attached badges. Match them exactly in rendering style, materials, bevels, lighting, glow and level of detail. Polished stylized 3D game emblem, strong readable silhouette, a single central symbol, no particles, no lightning, no sparkles, no text or letters. Front view, perfectly centered, filling about 85% of the frame, pure black background.

Рост по рангам: 1–3 — простые железные и стальные щиты; 4–6 — щит с плавниками и камнем;
7–8 — небольшие крылья; 9–17 — крылья и корона; Мастер I–III различаются числом шевронов снизу.
