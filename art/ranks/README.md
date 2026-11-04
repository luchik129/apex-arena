# Иконки рангов

`src/rNN.jpg` — исходник медали ранга на чёрном фоне, `NN` = `id` арены из `CONFIG.ARENAS`.
`python3 art/ranks/build_icons.py` делает фон прозрачным, сжимает в WebP 288×288 и
записывает строку `RANK_ICONS` в `index.html`. Ранг без картинки рисуется старой векторной медалью.
После скрипта синхронизировать `www/index.html` и `docs/app/index.html` (как в прошлых версиях).

| id | Ранг | Цвет | Исходник |
|----|------|------|----------|
| 1 | Подвал | серый | нужно сгенерировать |
| 2 | Гараж | изумрудный | нужно сгенерировать |
| 3 | Качалка | синий | нужно сгенерировать |
| 4 | Тренажёрка | фиолетовый | готово |
| 5 | Железный рай | оранжевый | готово |
| 6 | Арена силы | красный | готово |
| 7 | Зал чемпионов | золотой | нужно сгенерировать |
| 8 | Титан | бирюзовый | готово |
| 9 | Зал славы | розовое золото | готово |
| 10 | Лига претендентов | розовый | готово |
| 11–13 | Мастер I–III | фиолетовый | готово |
| 14 | Чемпион лиги | ярко-золотой | нужно сгенерировать |
| 15 | Великий чемпион | оранжевый, дракон | нужно сгенерировать |
| 16 | Абсолют | малиновый, бесконечность | нужно сгенерировать |
| 17 | Легенда Flexo | золото, корона | нужно сгенерировать |

## Промпты для Higgsfield

Референс: `style_ref.jpg` (все готовые медали одним листом). Формат 1:1. Общее начало каждого промпта:

> Create ONE new rank badge icon in exactly the same art style as the reference sheet (ornate polished metal mobile-game rank emblem, glossy 3D render, sharp spikes, gems, centered, pure black background, no text, no letters).

- **1 Подвал:** This is the LOWEST rank 1 'Basement': a modest, simple, small badge of worn dark grey iron and cracked stone, a few rivets, a short chain and a small rusty kettlebell in the center, cold slate-grey and dim steel tones, faint grey glow, much less ornate than the reference badges, no wings, no crown.
- **2 Гараж:** This is rank 2 'Garage': a gunmetal steel shield badge with a crossed wrench and barbell over a garage-door ribbed plate, bolts and rivets, glowing emerald green gems and soft emerald green glow, simple design, no wings, no crown.
- **3 Качалка:** This is rank 3 'Gym': a polished silver and royal blue shield emblem with two crossed chrome dumbbells in the center, sapphire blue gems, short silver spikes on top, soft electric blue glow, medium detail, no wings, no crown.
- **7 Зал чемпионов:** This is rank 7 'Hall of Champions': a rich yellow-gold emblem with a golden champion trophy cup in the center framed by a golden laurel wreath, crossed golden barbell behind, amber and topaz gems, warm golden glow, very ornate, small spiked golden crest on top.
- **14 Чемпион лиги:** This is high league rank 14 'League Champion': a majestic bright gold emblem with a large golden chess king piece in the center, a jeweled golden crown above it, big golden feathered wings on both sides, citrine and diamond gems, radiant yellow-gold glow and light rays, grander than the purple master badges.
- **15 Великий чемпион:** This is top league rank 15 'Grand Champion': a fiery orange and gold dragon coiled around an ornate golden crest, dragon wings spread wide, glowing orange fire gem in the center, embers and flames, intense orange glow, extremely ornate and epic.
- **16 Абсолют:** This is top league rank 16 'Absolute': a platinum and crimson-ruby emblem with a glowing ruby infinity symbol in the center, sharp platinum spikes forming a radiant halo, large angelic platinum wings, many ruby and diamond gems, intense crimson-rose glow and energy, extremely ornate and epic.
- **17 Легенда Flexo:** This is the HIGHEST ultimate rank 17 'Flexo Legend': the most legendary badge of all, radiant pure gold emblem with a massive jeweled golden crown on top, several layers of huge golden wings, a central golden medallion with the same white running-athlete emblem as in the reference, rainbow prismatic diamonds, divine golden light rays and sparkles, maximum ornate and epic.
