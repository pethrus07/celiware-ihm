"""Gera o ícone do app (Android legado + adaptativo), o de 512 px da Play Store
e os ícones do site.

Desenho: medidor em arco com ponteiro e uma "lâmpada" verde acesa, sobre
grafite — o app em uma imagem (IHM industrial, cor só onde há estado). O arco
é o destaque do app (`accent` do tema escuro, verde-água desde a 1.2.0): a
cor vem de lib/core/theme/app_theme.dart, lida a cada execução, para o ícone
nunca mais ficar numa cor que o app não usa (era âmbar até a 1.4.0).

Uso:  python tool/gerar_icone.py      (requer Pillow)
Saída: android/app/src/main/res/mipmap-*/ic_launcher.png
       android/app/src/main/res/mipmap-*/ic_launcher_foreground.png
       android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml
       android/app/src/main/res/values/ic_launcher_background.xml
       store/icone-512.png
       site/apple-touch-icon.png, site/favicon.ico
       site/favicon.svg e o logo em SVG das páginas do site (só a cor do arco)

Antes de gravar, confere o contraste do desenho contra o grafite do ícone e
contra fundo preto (papel de parede escuro): abaixo do mínimo, não gera nada.
Depois, rode `python tool/loja/imagens_loja.py grafico` para o gráfico de
recursos da Play, que usa este mesmo desenho.
"""

from __future__ import annotations

import math
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "android" / "app" / "src" / "main" / "res"
SITE = ROOT / "site"
THEME = ROOT / "lib" / "core" / "theme" / "app_theme.dart"


def theme_color(palette: str, name: str) -> tuple[int, int, int]:
    """Cor `name` da paleta `palette` (escuro/claro) do tema do app."""
    src = THEME.read_text(encoding="utf-8")
    block = re.search(rf"static const {palette} = IndPalette\((.*?)\n  \);", src, re.S)
    if not block:
        sys.exit(f"Não achei a paleta '{palette}' em {THEME.relative_to(ROOT)}.")
    m = re.search(rf"\b{name}: Color\(0xFF([0-9A-Fa-f]{{6}})\)", block.group(1))
    if not m:
        sys.exit(f"Não achei '{name}' na paleta '{palette}' de {THEME.relative_to(ROOT)}.")
    h = m.group(1)
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


BG = (0x1A, 0x1D, 0x22)  # grafite do ícone
TRACK = (0x2B, 0x30, 0x38)  # trecho apagado do arco
ACCENT = theme_color("escuro", "accent")  # arco aceso: o destaque do app
TEXT = (0xE9, 0xED, 0xF1)  # ponteiro
GREEN = theme_color("escuro", "ok")  # lâmpada acesa

S = 1024  # desenha grande e reduz (antisserrilhado de graça)


def hexa(c: tuple[int, int, int]) -> str:
    return "#%02X%02X%02X" % c


def contrast(a: tuple[int, int, int], b: tuple[int, int, int]) -> float:
    """Razão de contraste WCAG 2."""

    def lum(c: tuple[int, int, int]) -> float:
        ch = [v / 255 for v in c]
        ch = [v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4 for v in ch]
        return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2]

    x, y = lum(a), lum(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)


def check_contrast() -> None:
    """Portão: arco, ponteiro e lâmpada precisam aparecer no grafite do ícone
    (onde ele sempre está) e também direto sobre preto — o recorte adaptativo
    e o papel de parede escuro encostam o desenho num fundo quase preto. No
    fundo claro o ícone leva o próprio grafite, que contrasta com o branco."""
    falhas = []
    for nome, cor, minimo in (("arco", ACCENT, 4.5), ("ponteiro", TEXT, 4.5), ("lâmpada", GREEN, 3.0)):
        for fundo_nome, fundo in (("grafite", BG), ("preto", (0, 0, 0))):
            r = contrast(cor, fundo)
            print(f"  contraste {nome} {hexa(cor)} × {fundo_nome}: {r:.1f}:1 (mínimo {minimo}:1)")
            if r < minimo:
                falhas.append(f"{nome} × {fundo_nome}")
    r = contrast(BG, (255, 255, 255))
    print(f"  contraste grafite do ícone × branco: {r:.1f}:1 (mínimo 3:1)")
    if r < 3:
        falhas.append("grafite × branco")
    if falhas:
        sys.exit("Contraste insuficiente: " + ", ".join(falhas) + ". Nada foi gerado.")


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
    d.arc(box, start=150, end=300, fill=ACCENT, width=w)
    # Ponteiro no fim do trecho aceso.
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


def full_bleed(size: int) -> Image.Image:
    """Quadrado inteiro de grafite com o desenho (quem arredonda é a loja, o
    iOS ou a aba do navegador)."""
    full = Image.new("RGBA", (size, size), BG + (255,))
    full.alpha_composite(glyph(size, 0.9))
    return full


# O arco aceso no SVG do site (favicon.svg e o logo de cada página).
SVG_ARC = re.compile(r'(<path d="M15\.5 43\.3A19 19 0 0 1 41\.5 17\.3" fill="none" stroke=")#[0-9A-Fa-f]{6}(")')


def site() -> None:
    full_bleed(180).convert("RGB").save(SITE / "apple-touch-icon.png", optimize=True)
    # Cada tamanho desenhado no próprio tamanho, não reduzido do maior.
    full_bleed(32).save(SITE / "favicon.ico", sizes=[(16, 16), (32, 32)], append_images=[full_bleed(16)])
    for f in [SITE / "favicon.svg", *sorted(SITE.glob("*.html"))]:
        text = f.read_bytes().decode("utf-8")
        new, n = SVG_ARC.subn(rf"\g<1>{hexa(ACCENT)}\g<2>", text)
        if f.suffix == ".svg" and n != 1:
            sys.exit(f"{f.relative_to(ROOT)}: não achei o arco do medidor no SVG.")
        if new != text:
            f.write_bytes(new.encode("utf-8"))
            print(f"  {f.relative_to(ROOT)}: arco em {hexa(ACCENT)} ({n}×)")


def main() -> None:
    check_contrast()

    # Legado (Android < 8): quadrado arredondado com o desenho dentro.
    legacy = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for dens, px in legacy.items():
        out = RES / f"mipmap-{dens}"
        out.mkdir(parents=True, exist_ok=True)
        icon = rounded_bg(px)
        icon.alpha_composite(glyph(px, 1.0))
        icon.save(out / "ic_launcher.png")

    # Adaptativo (Android 8+): camada da frente em 108 dp; o sistema recorta.
    # O desenho fica na "zona segura" central de 66 dp (~61%). É também o que
    # o Android 12+ mostra na abertura do app (splash), sobre o fundo do tema.
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
        f'    <color name="ic_launcher_background">{hexa(BG)}</color>\n</resources>\n',
        encoding="utf-8",
    )

    # Play Store: 512×512, sem transparência (a loja aplica o arredondamento).
    store = ROOT / "store"
    store.mkdir(exist_ok=True)
    full_bleed(512).convert("RGB").save(store / "icone-512.png")

    site()
    print("Ícones gerados.")


if __name__ == "__main__":
    main()
