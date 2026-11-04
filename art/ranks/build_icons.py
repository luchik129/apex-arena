#!/usr/bin/env python3
"""Иконки рангов: art/ranks/src/rNN.jpg (NN = id арены из CONFIG.ARENAS, фон чёрный)
-> прозрачный WebP -> строка `RANK_ICONS: {...}` в index.html.

Запуск из корня репозитория:  python3 art/ranks/build_icons.py
Чтобы добавить/заменить иконку ранга: положить картинку на чёрном фоне в
art/ranks/src/rNN.jpg (или .png) и запустить скрипт ещё раз.
Ранги без картинки рисуются старой векторной медалью (UI.rankArt).
"""
import base64, glob, io, os, re
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'art', 'ranks', 'src')
OUT = os.path.join(ROOT, 'art', 'ranks', 'out')
HTML = os.path.join(ROOT, 'index.html')
SIZE = 288        # px: медаль в приложении не больше 200 css px
LO, HI = 6, 46    # яркость фона: <= LO — прозрачно, >= HI — непрозрачно


def cut(path):
    im = np.asarray(Image.open(path).convert('RGB')).astype(np.float32)
    v = im.max(axis=2)
    a = np.clip((v - LO) / (HI - LO), 0, 1)
    a = a * a * (3 - 2 * a)                       # smoothstep
    # картинка = цвет * alpha поверх чёрного -> восстанавливаем цвет без чёрной примеси
    rgb = np.where(a[..., None] > 0.01, im / np.maximum(a[..., None], 0.01), 0)
    rgb = np.clip(rgb, 0, 255)
    rgba = np.dstack([rgb, a * 255]).astype(np.uint8)
    img = Image.fromarray(rgba, 'RGBA')
    # обрезаем по содержимому и вписываем в квадрат с небольшим полем
    box = Image.fromarray((a > 0.08).astype(np.uint8) * 255).getbbox()
    img = img.crop(box)
    side = int(max(img.size) * 1.04)
    sq = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    sq.paste(img, ((side - img.width) // 2, (side - img.height) // 2))
    return sq.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    icons = {}
    for p in sorted(glob.glob(os.path.join(SRC, 'r*.*'))):
        m = re.match(r'r(\d+)\.(jpe?g|png|webp)$', os.path.basename(p), re.I)
        if not m:
            continue
        rid = int(m.group(1))
        img = cut(p)
        img.save(os.path.join(OUT, 'r%02d.png' % rid))
        buf = io.BytesIO()
        img.save(buf, 'WEBP', quality=82, method=6)
        icons[rid] = 'data:image/webp;base64,' + base64.b64encode(buf.getvalue()).decode()
        print('rank %2d: %5.1f KB' % (rid, len(buf.getvalue()) / 1024))
    line = '  RANK_ICONS: {' + ', '.join("%d: '%s'" % (k, v) for k, v in sorted(icons.items())) + '}, // @rank-icons (art/ranks/build_icons.py)\n'
    src = open(HTML, encoding='utf-8').read()
    src, n = re.subn(r'^  RANK_ICONS: .*// @rank-icons.*\n', lambda _: line, src, flags=re.M)
    if n != 1:
        raise SystemExit('не нашёл строку RANK_ICONS в index.html')
    open(HTML, 'w', encoding='utf-8').write(src)
    print('index.html: %d иконок' % len(icons))


if __name__ == '__main__':
    main()
