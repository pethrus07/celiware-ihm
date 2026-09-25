"""Gera o ícone do app (Android legado + adaptativo) e o de 512 px da Play Store.

Desenho: medidor em arco âmbar com ponteiro e uma "lâmpada" verde acesa,
sobre grafite — o app em uma imagem (IHM industrial, cor só onde há estado).
Cores e proporções vêm do tema (lib/core/theme/app_theme.dart).

Uso:  python tool/gerar_icone.py      (requer Pillow)
Saída: android/app/src/main/res/mipmap-*/ic_launcher.png
       android/app/src/main/res/mipmap-*/ic_launcher_foreground.png
       android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml
       android/app/src/main/res/values/ic_launcher_background.xml
       store/icone-512.png
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "android" / "app" / "src" / "main" / "res"

BG = (0x1A, 0x1D, 0x22)
TRACK = (0x2B, 0x30, 0x38)
AMBER = (0xFF, 0xB0, 0x20)
TEXT = (0xE9, 0xED, 0xF1)
GREEN = (0x2F, 0xBF, 0x71)

S = 1024  # desenha grande e reduz (antisserrilhado de graça)


def glyph(size: int, scale: float) -> Image.Image:
    """Medidor + lâmpada, centrado, ocupando [scale] do quadro (transparente)."""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = S / 2
    r = S * 0.34 * scale
    w = int(S * 0.085 * scale)
    box = [c - r, c - r * 0.92, c + r, c + r * 1.08]
    # Arco de 240°, de 150° a 390° (sentido horário no PIL, 0° = leste).
    d.arc(box, start=150, end=390, fill=TRACK, width=w)
    d.arc(box, start=150, end=300, fill=AMBER, width=w)
    # Ponteiro no fim do trecho âmbar.
    a = math.radians(300)
    cx, cy = c, (box[1] + box[3]) / 2
    tip = (cx + math.cos(a) * r * 0.86, cy + math.sin(a) * r * 0.86)
    d.line([(cx, cy), tip], fill=TEXT, width=int(w * 0.55))
    hub = w * 0.62
    d.ellipse([cx - hub, cy - hub, cx + hub, cy + hub], fill=TEXT)
    # Lâmpada verde acesa embaixo, com halo.
    lr = w * 0.72
    ly = cy + r * 0.8
    for k, alpha in ((1.9, 40), (1.4, 70)):
        d.ellipse([cx - lr * k, ly - lr * k, cx + lr * k, ly + lr * k], fill=GREEN + (alpha,))
    d.ellipse([cx - lr, ly - lr, cx + lr, ly + lr], fill=GREEN)
    return img.resize((size, size), Image.LANCZOS)


def rounded_bg(size: int, radius_frac: float = 0.22) -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * radius_frac), fill=BG)
    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    # Legado (Android < 8): quadrado arredondado com o desenho dentro.
    legacy = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for dens, px in legacy.items():
        out = RES / f"mipmap-{dens}"
        out.mkdir(parents=True, exist_ok=True)
        icon = rounded_bg(px)
        icon.alpha_composite(glyph(px, 1.0))
        icon.save(out / "ic_launcher.png")

    # Adaptativo (Android 8+): camada da frente em 108 dp; o sistema recorta.
    # O desenho fica na "zona segura" central de 66 dp (~61%).
    adaptive = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
    for dens, px in adaptive.items():
        glyph(px, 0.64).save(RES / f"mipmap-{dens}" / "ic_launcher_foreground.png")

    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n',
        encoding="utf-8",
    )
    values = RES / "values"
    values.mkdir(parents=True, exist_ok=True)
    (values / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        '    <color name="ic_launcher_background">#1A1D22</color>\n</resources>\n',
        encoding="utf-8",
    )

    # Play Store: 512×512, sem transparência (a loja aplica o arredondamento).
    store = ROOT / "store"
    store.mkdir(exist_ok=True)
    full = Image.new("RGBA", (512, 512), BG + (255,))
    full.alpha_composite(glyph(512, 0.9))
    full.convert("RGB").save(store / "icone-512.png")
    print("Ícones gerados.")


if __name__ == "__main__":
    main()
