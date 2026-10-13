"""Trechos "Veja funcionando" do site: loops mudos recortados do vídeo de apresentação.

Lê tool/video/saida/ware-iot-apresentacao.mp4 (fora do git; gerado por
apresentacao.py), recorta só a tela do celular (o celular fica à esquerda do
quadro: x 173 nas cenas da máquina de demonstração, x 83 na cena "O chão de
fábrica", com o simulador ao lado) e grava em site/video/:

    <nome>.mp4   H.264, sem áudio, 432×960 (9:20, quase o tamanho nativo da tela no quadro)
    <nome>.webm  VP9, sem áudio — só se ficar menor que o MP4 (o site oferece primeiro)
    <nome>.webp  capa (poster)

Uso (na raiz do repositório):  python tool/video/trechos_site.py
"""

import subprocess
import sys
from pathlib import Path

AQUI = Path(__file__).resolve().parent
RAIZ = AQUI.parent.parent
FONTE = Path(sys.argv[1]) if len(sys.argv) > 1 else AQUI / "saida" / "ware-iot-apresentacao.mp4"
DESTINO = RAIZ / "site" / "video"
FFMPEG = next((Path.home() / "AppData/Local/Microsoft/WinGet/Packages").glob("Gyan.FFmpeg*/**/bin/ffmpeg.exe"))

# nome, início (s), duração (s), x do recorte, velocidade, instante da capa (s, no trecho já acelerado)
TRECHOS = [
    # 00:21,5 · Operar: toca em LIGA, confirma "Ligar?", o botão acende quando a máquina confirma.
    ("ligar", 21.5, 10.0, 173, 1.0, 4.0),
    # 02:11 · O chão de fábrica: a porta abre no simulador, a faixa de alarme chega (1 · Porta aberta)
    # e volta ao normal quando a porta fecha.
    ("alarme", 131.0, 10.5, 83, 1.0, 5.0),
    # 01:05,5 · Montar a tela: lâmpada e botão escolhidos, ligados à variável e já operando (1,4×).
    ("montar", 65.5, 16.0, 173, 1.4, 9.4),
]


def ffmpeg(*args: str) -> None:
    subprocess.run([str(FFMPEG), "-v", "error", "-y", *args], check=True)


def main() -> None:
    DESTINO.mkdir(parents=True, exist_ok=True)
    for nome, ini, dur, x, vel, capa in TRECHOS:
        vf = f"crop=438:974:{x}:53,scale=432:960:flags=lanczos,setpts=PTS/{vel},fps=30"
        corte = ["-ss", str(ini), "-t", str(dur), "-i", str(FONTE), "-an", "-vf", vf]
        mp4, webm, webp = (DESTINO / f"{nome}.{ext}" for ext in ("mp4", "webm", "webp"))
        ffmpeg(*corte, "-c:v", "libx264", "-preset", "veryslow", "-crf", "23", "-profile:v", "high",
               "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(mp4))
        ffmpeg(*corte, "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "36", "-row-mt", "1",
               "-deadline", "good", "-cpu-used", "1", "-pix_fmt", "yuv420p", str(webm))
        ffmpeg("-ss", str(capa), "-i", str(mp4), "-frames:v", "1", "-c:v", "libwebp", "-quality", "72", str(webp))
        kb = lambda p: p.stat().st_size // 1024  # noqa: E731
        # WebM só fica se for menor que o MP4 (o HTML só cita os .webm que existem).
        fica = webm.stat().st_size < mp4.stat().st_size
        print(f"{nome}: mp4 {kb(mp4)} KB · webm {kb(webm)} KB{'' if fica else ' (apagado: não ficou menor)'} · capa {kb(webp)} KB")
        if not fica:
            webm.unlink()


if __name__ == "__main__":
    main()
