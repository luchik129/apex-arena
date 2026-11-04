#!/usr/bin/env python3
"""Иконки рангов: art/ranks/src/rNN.jpg (NN = номер ранга 01…17, фон чёрный)
-> прозрачный WebP 512×512 -> ranks/rank_NN.webp (+ копии в www/ranks и docs/app/ranks).
Приложение берёт их через UI.medalSrc.

Запуск из корня репозитория:  python3 art/ranks/build_icons.py
Чтобы добавить/заменить иконку ранга: положить картинку на чёрном фоне в
art/ranks/src/rNN.jpg (или .png) и запустить скрипт ещё раз.
"""
import base64, glob, io, os, re
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'art', 'ranks', 'src')
SIZE = 512
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
    n = 0
    for p in sorted(glob.glob(os.path.join(SRC, 'r*.*'))):
        m = re.match(r'r(\d+)\.(jpe?g|png|webp)$', os.path.basename(p), re.I)
        if not m:
            continue
        rid = int(m.group(1))
        img = cut(p)
        for d in ('ranks', 'www/ranks', 'docs/app/ranks'):
            os.makedirs(os.path.join(ROOT, d), exist_ok=True)
            img.save(os.path.join(ROOT, d, 'rank_%02d.webp' % rid), 'WEBP', quality=86, method=6)
        print('rank %2d: %5.1f KB' % (rid, os.path.getsize(os.path.join(ROOT, 'ranks', 'rank_%02d.webp' % rid)) / 1024))
        n += 1
    print('готово: %d рангов' % n)


if __name__ == '__main__':
    main()
