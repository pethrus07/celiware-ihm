"""Narração local com o Kokoro (sem serviço na nuvem).

Roda no venv de voz (~/.venvs/tts: kokoro 0.9.4, soundfile, numpy):
    python falar_kokoro.py <voz> <texto.txt> <saida.wav> [<texto.txt> <saida.wav> ...]
Vários pares numa chamada só: o modelo leva ~30 s para carregar.

Frase a frase: com a cena inteira de uma vez, o fraseamento piora no meio do
texto — "Toco em Liga e confirmo" saía "toca… confirma" na cena e certo na
frase sozinha (transcrição reversa, out/2026). Entre as frases, uma pausa curta.

Vozes em português do Brasil: pm_alex (masculina), pf_dora (feminina).
O edge-tts, que narrava antes, passou a receber 403 do serviço (out/2026).
"""
import re
import sys
import warnings

warnings.filterwarnings("ignore")

import numpy as np
import soundfile as sf
from kokoro import KPipeline

TAXA = 24000
PAUSA = {".": 0.30, "!": 0.30, "?": 0.30, ":": 0.18, ";": 0.18}

voz, pares = sys.argv[1], sys.argv[2:]
pipe = KPipeline(lang_code="p", repo_id="hexgrad/Kokoro-82M")
for entrada, saida in zip(pares[::2], pares[1::2]):
    texto = open(entrada, encoding="utf-8").read().strip()
    frases = [f for f in re.split(r"(?<=[.!?:;])\s+", texto) if f.strip()]
    partes = []
    for i, frase in enumerate(frases):
        for _, _, audio in pipe(frase, voice=voz):
            partes.append(audio if hasattr(audio, "shape") else audio.numpy())
        if i < len(frases) - 1:
            partes.append(np.zeros(int(PAUSA.get(frase.rstrip()[-1], 0.18) * TAXA), dtype=np.float32))
    sf.write(saida, np.concatenate(partes), TAXA)
