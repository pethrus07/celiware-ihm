"""Imagens e textos da ficha da Google Play — gera e confere (docs/loja/).

Uso (da raiz do repositório; requer Pillow):
  python tool/loja/imagens_loja.py capturas PASTA   copia as capturas de celular (cel-*.png) para a ficha
  python tool/loja/imagens_loja.py tablet           tira a transparência das capturas de tablet
  python tool/loja/imagens_loja.py grafico          gera o gráfico de recursos 1024 × 500
  python tool/loja/imagens_loja.py conferir         confere imagens e textos contra as regras da Play

As capturas de celular saem de um AVD de 1080 × 1920 (proporção 9:16, a que a
Play recomenda) com a demonstração rodando, tema escuro e a barra de status
limpa (modo demonstração do Android). Roteiro em docs/loja/ficha.md, "Imagens".

`conferir` é o portão: sai com erro se alguma peça não passa (tamanho,
proporção, transparência, peso, limite de caracteres, marcador esquecido).
Rode antes de subir qualquer coisa no Play Console.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
LOJA = ROOT / "docs" / "loja"
IMG = LOJA / "imagens"
CELULAR = IMG / "celular"
TABLET = ROOT / "docs" / "imagens" / "tablet"
ICONE = ROOT / "store" / "icone-512.png"
GRAFICO = IMG / "grafico-recursos.png"
FONTES = ROOT / "assets" / "fonts"

# Ordem da ficha: a primeira captura é a que aparece na busca.
CAPTURAS = [
    ("cel-operacao", "01-operacao"),
    ("cel-editor", "02-editor"),
    ("cel-variavel", "03-variavel-lendo-agora"),
    ("cel-alarme-na-tela", "04-alarme-na-tela"),
    ("cel-alarmes", "05-alarmes"),
    ("cel-graficos", "06-graficos"),
    ("cel-receita", "07-receitas"),
    ("cel-lider", "08-resumo-do-lider"),
]

# Cores do tema escuro do app (lib/core/theme/app_theme.dart, IndPalette.escuro).
BG = (0x0E, 0x10, 0x14)
SURFACE_HIGHER = (0x2A, 0x2F, 0x37)
TEXTO = (0xE8, 0xEA, 0xED)
TEXTO_DIM = (0xA1, 0xA7, 0xB0)
ICONE_BG = (0x1A, 0x1D, 0x22)  # fundo do ícone (tool/gerar_icone.py)

# Limites do Play Console (conferidos em 12/10/2026; a loja muda — rever no Console).
LIMITES_TEXTO = {
    "nome.txt": 30,
    "descricao-curta.txt": 80,
    "descricao-completa.txt": 4000,
    "notas-da-versao.txt": 500,
    "acesso-ao-app.txt": 500,  # instruções ao revisor; limite nosso, por folga
}
CAPTURA_LADO = (320, 3840)       # px, cada lado
CAPTURA_PROPORCAO = 2.0          # o lado maior até 2× o menor
CAPTURA_PESO = 8 * 1024 * 1024   # 8 MB
ICONE_PESO = 1024 * 1024         # 1 MB


def sem_transparencia(im: Image.Image) -> Image.Image:
    """PNG de 24 bits: a Play recusa canal alfa nas capturas e no gráfico."""
    if im.mode in ("RGBA", "LA", "P"):
        im = im.convert("RGBA")
        fundo = Image.new("RGB", im.size, BG)
        fundo.paste(im, mask=im.getchannel("A"))
        return fundo
    return im.convert("RGB")


def capturas(pasta: Path) -> None:
    CELULAR.mkdir(parents=True, exist_ok=True)
    for origem, destino in CAPTURAS:
        im = Image.open(pasta / f"{origem}.png")
        if im.size != (1080, 1920):
            sys.exit(f"{origem}.png tem {im.size[0]} × {im.size[1]}; o AVD da loja é 1080 × 1920.")
        sem_transparencia(im).save(CELULAR / f"{destino}.png", optimize=True)
        print(f"  {destino}.png")


def tablet() -> None:
    for f in sorted(TABLET.glob("*.png")):
        im = Image.open(f)
        if im.mode != "RGB":
            sem_transparencia(im).save(f, optimize=True)
            print(f"  {f.name}: {im.mode} → RGB")


def fonte(nome: str, tamanho: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(FONTES / nome), tamanho)


def grafico() -> None:
    """Gráfico de recursos 1024 × 500: marca à esquerda, a tela em operação à
    direita. Fundo chapado do tema escuro, sem degradê nem moldura de aparelho
    (ARQUITETURA §8: cor só onde há estado)."""
    sys.path.insert(0, str(ROOT / "tool"))
    from gerar_icone import glyph  # noqa: E402 — desenho do ícone do app

    L, A = 1024, 500
    g = Image.new("RGB", (L, A), BG)
    d = ImageDraw.Draw(g)

    # Ícone: quadrado arredondado com o medidor, como na tela inicial do Android.
    lado = 112
    x0, y0 = 76, 118
    icone = Image.new("RGBA", (lado * 4, lado * 4), (0, 0, 0, 0))
    ImageDraw.Draw(icone).rounded_rectangle([0, 0, lado * 4 - 1, lado * 4 - 1], radius=int(lado * 4 * 0.22), fill=ICONE_BG)
    icone.alpha_composite(glyph(lado * 4, 1.0))
    icone = icone.resize((lado, lado), Image.LANCZOS)
    g.paste(icone, (x0, y0), icone)

    d.text((x0 - 4, y0 + lado + 14), "Ware IoT", font=fonte("IBMPlexSansCondensed-Bold.ttf", 96), fill=TEXTO)
    d.text((x0, y0 + lado + 132), "A IHM da sua máquina no celular.", font=fonte("IBMPlexSans-500.ttf", 30), fill=TEXTO_DIM)

    # A tela em operação, sem a barra de status, cortada pela borda de baixo.
    tela = Image.open(CELULAR / "01-operacao.png").convert("RGB").crop((0, 84, 1080, 1920))
    largura = 318
    tela = tela.resize((largura, round(tela.height * largura / tela.width)), Image.LANCZOS)
    tx, ty = L - largura - 72, 52
    raio = 26
    mascara = Image.new("L", tela.size, 0)
    ImageDraw.Draw(mascara).rounded_rectangle([0, 0, tela.width - 1, tela.height + raio], radius=raio, fill=255)
    borda = 2
    d.rounded_rectangle([tx - borda, ty - borda, tx + largura + borda - 1, A + raio], radius=raio + borda, fill=SURFACE_HIGHER)
    g.paste(tela, (tx, ty), mascara)

    IMG.mkdir(parents=True, exist_ok=True)
    g.save(GRAFICO, optimize=True)
    print(f"  {GRAFICO.relative_to(ROOT)}")


def conferir() -> int:
    erros: list[str] = []

    def imagem(f: Path, *, tamanho=None, alfa_ok=False, peso=CAPTURA_PESO, captura=False):
        if not f.is_file():
            erros.append(f"falta {f.relative_to(ROOT)}")
            return
        im = Image.open(f)
        w, h = im.size
        nome = f.relative_to(ROOT).as_posix()
        if tamanho and (w, h) != tamanho:
            erros.append(f"{nome}: {w} × {h}, a Play pede {tamanho[0]} × {tamanho[1]}")
        if not alfa_ok and im.mode not in ("RGB", "L"):
            erros.append(f"{nome}: modo {im.mode}; a Play quer PNG de 24 bits, sem transparência")
        if f.stat().st_size > peso:
            erros.append(f"{nome}: {f.stat().st_size / 1e6:.1f} MB, acima do limite")
        if captura:
            if not (CAPTURA_LADO[0] <= min(w, h) and max(w, h) <= CAPTURA_LADO[1]):
                erros.append(f"{nome}: lado fora de {CAPTURA_LADO[0]}–{CAPTURA_LADO[1]} px")
            if max(w, h) / min(w, h) > CAPTURA_PROPORCAO:
                erros.append(f"{nome}: proporção {max(w, h) / min(w, h):.2f}:1, a Play aceita até 2:1")
        print(f"  ok? {nome:55s} {w} × {h} {im.mode} {f.stat().st_size // 1024} KB")

    imagem(ICONE, tamanho=(512, 512), alfa_ok=True, peso=ICONE_PESO)
    imagem(GRAFICO, tamanho=(1024, 500))
    cel = sorted(CELULAR.glob("*.png"))
    if not 2 <= len(cel) <= 8:
        erros.append(f"capturas de celular: {len(cel)}; a Play aceita de 2 a 8")
    for f in cel:
        imagem(f, captura=True)
    tab = sorted(TABLET.glob("*.png"))
    if tab and len(tab) > 8:
        erros.append(f"capturas de tablet: {len(tab)}; máximo 8 por tipo de tela")
    for f in tab:
        imagem(f, captura=True)

    for nome, limite in LIMITES_TEXTO.items():
        f = LOJA / nome
        if not f.is_file():
            erros.append(f"falta docs/loja/{nome}")
            continue
        texto = f.read_text(encoding="utf-8").strip()
        n = len(texto)
        print(f"  ok? docs/loja/{nome:44s} {n} de {limite} caracteres")
        if n > limite:
            erros.append(f"docs/loja/{nome}: {n} caracteres, limite {limite}")
        for marcador in ("EMAIL_CONTATO", "TODO", "XXX", "#LOJA-"):
            if marcador in texto:
                erros.append(f"docs/loja/{nome}: sobrou o marcador {marcador}")

    if erros:
        print("\nREPROVADO:")
        for e in erros:
            print(f"  - {e}")
        return 1
    print("\nTudo dentro das regras da Play.")
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "capturas" and len(sys.argv) > 2:
        capturas(Path(sys.argv[2]))
    elif cmd == "tablet":
        tablet()
    elif cmd == "grafico":
        grafico()
    elif cmd == "conferir":
        sys.exit(conferir())
    else:
        sys.exit(__doc__)
