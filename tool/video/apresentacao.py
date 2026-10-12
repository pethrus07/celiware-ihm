"""Vídeo de apresentação do Ware IoT — gravado do sistema rodando de verdade.

Método da Retífica (retifica-os/onboarding): nada é encenado, a narração manda
no tempo (cada cena dura o que a voz precisar; se a ação acabar antes, a tela
fica mostrando o resultado), e o toque aparece na tela (show_touches).

Diferença daqui: em vez do navegador, grava
  • o celular — `adb shell screenrecord` no emulador;
  • o simulador — a janela do painel (sim/simulador.py --painel), via
    ffmpeg gdigrab, ao mesmo tempo que o celular nas cenas de rede.

Uso (de celiware-ihm/):
  python tool/video/apresentacao.py ensaio     # roda as ações e tira fotos (sem gravar)
  python tool/video/apresentacao.py            # grava, narra e monta
  python tool/video/apresentacao.py remontar   # monta de novo das gravações (sem aparelho)
Pré-requisitos: emulador ligado com o app instalado EM PROFILE
(`flutter build apk --profile`: compilado como o release, mas depurável — o
`run-as` que põe o projeto do vídeo no app só funciona assim); `tool/video/preparar_projeto.py`
já tem o projeto (ele é empurrado para o aparelho no início).
Saída: tool/video/saida/ware-iot-apresentacao.mp4 (+ capítulos).
"""
from __future__ import annotations

import ctypes
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from PIL import Image, ImageDraw, ImageFont

RAIZ = Path(__file__).resolve().parents[2]
AQUI = Path(__file__).resolve().parent
TRAB = AQUI / ".trabalho"
SAIDA = AQUI / "saida"
FONTES = RAIZ / "assets" / "fonts"
SIM = RAIZ / "sim"

ANDROID = Path(os.environ.get("ANDROID_HOME", Path.home() / "AppData/Local/Android/Sdk"))
ADB = str(ANDROID / "platform-tools" / "adb.exe")
FFMPEG = next((Path.home() / "AppData/Local/Microsoft/WinGet/Packages").glob("Gyan.FFmpeg*/**/bin/ffmpeg.exe"))
FFPROBE = FFMPEG.with_name("ffprobe.exe")
PYTHON = sys.executable
PAINEL_TITULO = "Simulador Modbus TCP — Ware IoT"  # igual a sim/painel.py
PACOTE = "com.celiware.ihm"
# Voz local (tool/video/falar_kokoro.py) no venv de voz; o edge-tts passou a
# receber 403 do serviço em out/2026.
PYTHON_VOZ = Path(os.environ.get("PYTHON_VOZ", Path.home() / ".venvs/tts/Scripts/python.exe"))
VOZ = "pm_alex"
# Grafia para a voz, cada uma conferida por transcrição reversa (faster-whisper
# small e medium) — como saía antes: "Ware IoT" → "Ariut", "Siemens" → "se m",
# "OPC UA" → "opua", "app" → "apa" (às vezes), "faca" → "feca".
PRONUNCIA = {"Ware IoT": "Uéar ai ou tí", "Siemens": "Símens", "OPC UA": "O P C U A",
             "app": "épi", "faca": "fácca", "Faca": "Fácca"}

L, A = 1920, 1080  # palco
BG = (18, 20, 24)
SURFACE = (35, 40, 48)
# Destaque = o verde-água do app no tema escuro (Ind.accent, 0xFF2EC4D0).
TEXTO, DIM, DESTAQUE = (233, 237, 241), (163, 173, 184), (46, 196, 208)


# ── Celular ──────────────────────────────────────────────────────────────────

class Celular:
    """Ajudantes de toque no emulador (coordenadas em pixels do aparelho)."""

    def adb(self, *args, check=True):
        return subprocess.run([ADB, *args], capture_output=True, text=True, check=check)

    def toque(self, x, y, espera=0.9):
        self.adb("shell", "input", "tap", str(x), str(y)); time.sleep(espera)

    def tecla(self, codigo, espera=0.6):
        self.adb("shell", "input", "keyevent", str(codigo)); time.sleep(espera)

    def texto(self, s, espera=0.6):
        # ritmo: letra por letra parece gente digitando (lição da Retífica)
        for ch in s:
            self.adb("shell", "input", "text", ch); time.sleep(0.12)
        time.sleep(espera)

    def arrastar(self, x1, y1, x2, y2, ms=700, espera=1.0):
        self.adb("shell", "input", "swipe", str(x1), str(y1), str(x2), str(y2), str(ms)); time.sleep(espera)

    def foto(self, nome):
        TRAB.joinpath("fotos").mkdir(parents=True, exist_ok=True)
        with open(TRAB / "fotos" / f"{nome}.png", "wb") as f:
            f.write(subprocess.run([ADB, "exec-out", "screencap", "-p"], capture_output=True).stdout)

    @staticmethod
    def espera(s):
        time.sleep(s)


ENSAIO = len(sys.argv) > 1 and sys.argv[1] == "ensaio"
# remontar: monta de novo com as gravações de .trabalho/bruto, sem aparelho —
# para quando só a montagem (filtro, arte, narração) mudou.
REMONTAR = len(sys.argv) > 1 and sys.argv[1] == "remontar"
PRE_ROLL = 0.9


def marco(c: "Celular", nome: str):
    """Foto de conferência no meio de uma ação — só no modo ensaio."""
    if ENSAIO:
        c.foto(nome)


def comando_painel(palavra: str):
    """Aperta um botão do painel do simulador sem mouse (ver sim/painel.py)."""
    (SIM / ".comando").write_text(palavra, encoding="utf-8")


# ── Roteiro ──────────────────────────────────────────────────────────────────

@dataclass
class Cena:
    id: str
    titulo: str
    narracao: str
    tipo: str = "celular"          # celular · dividido · cartao
    pontos: list[str] = field(default_factory=list)
    acao: Callable[[Celular], None] | None = None
    # cartão: palavra da narração em que cada ponto aparece (sem isso, espaçados por igual)
    gatilhos: list[str] = field(default_factory=list)


# Coordenadas do Pixel 7 (1080×2400), medidas nas capturas do ensaio.
LIGA, CONFIRMAR = (204, 948), (697, 1412)
AJUSTE = (300, 1300)
TECLA = {"1": (209, 1884), "2": (540, 1884), "6": (871, 1715), "0": (540, 2054)}
GRAVAR = (708, 2220)
LAPIS, CONCLUIR = (890, 220), (925, 220)
ELEMENTO, MAIS_ELEMENTO = (462, 2242), (980, 2242)
PALETA_BOTAO, PALETA_LAMPADA = (288, 1060), (792, 1060)
ESCOLHER_VARIAVEL = (540, 1128)
ABA_TELAS, ABA_VARIAVEIS = (135, 2256), (675, 2256)
FAB = (840, 2042)
TELA_OPERACAO, TELA_REDE = (540, 540), (300, 2000)


def c_inicio(c: Celular):
    c.espera(4.5)
    c.toque(*TELA_OPERACAO, espera=2.0)


def c_operar(c: Celular):
    c.espera(1.5)
    c.toque(*LIGA, espera=1.3)
    c.toque(*CONFIRMAR, espera=10)


def c_ajuste(c: Celular):
    c.toque(*AJUSTE, espera=1.4)
    marco(c, "ajuste-teclado")
    # 60, não 120: a demonstração esquenta para 32 + 0,62 × velocidade; a 120
    # ela passa de 85 °C no meio do editor, para sozinha e põe a faixa de
    # alarme no topo — que empurra a tela e desvia os toques seguintes.
    for k in "60":
        c.toque(*TECLA[k], espera=0.45)
    c.toque(*GRAVAR, espera=1.4)
    marco(c, "ajuste-confirmar")
    c.toque(*CONFIRMAR, espera=3.5)


def c_graficos(c: Celular):
    c.arrastar(540, 1900, 540, 650, ms=900, espera=6)


def c_editor(c: Celular):
    c.tecla(4, espera=1.2)                      # volta para a lista de telas
    c.toque(*FAB, espera=1.2)                   # Nova tela
    c.texto("Painel")
    c.tecla(66, espera=2.0)                     # Enter → abre o editor
    c.toque(*ELEMENTO, espera=1.4)
    c.toque(*PALETA_LAMPADA, espera=1.6)        # já abre a configuração
    marco(c, "editor-config-lampada")
    c.toque(*ESCOLHER_VARIAVEL, espera=1.3)
    c.toque(540, 1684, espera=1.6)              # Faca acionada
    c.tecla(4, espera=1.2)                      # fecha a configuração
    c.toque(*MAIS_ELEMENTO, espera=1.4)
    c.toque(*PALETA_BOTAO, espera=1.6)
    marco(c, "editor-config-botao")
    c.toque(*ESCOLHER_VARIAVEL_BOTAO, espera=1.3)
    marco(c, "editor-escolha-botao")
    c.toque(540, 1290, espera=1.6)              # Liga máquina
    c.tecla(4, espera=1.2)
    c.toque(*CONCLUIR, espera=3.0)


ESCOLHER_VARIAVEL_BOTAO = (540, 1290)
EQUIP_DEMO = (288, 770)                         # "Cortadora de rótulos" (o form abre na rede)
ENDERECO = (378, 1928)
SUGESTAO = (540, 1732)                          # o form rola ao focar o endereço
DESCARTAR = (794, 1380)                         # "Descartar alterações?" ao sair do form


def c_variavel(c: Celular):
    c.tecla(4, espera=1.0)
    c.toque(*ABA_VARIAVEIS, espera=1.6)
    c.toque(*FAB, espera=2.0)                   # Nova variável
    c.toque(*EQUIP_DEMO, espera=1.0)            # a demonstração está rodando: o valor lido não é zero
    marco(c, "variavel-form")
    c.toque(*ENDERECO, espera=0.8)
    c.tecla(67, espera=0.3)
    c.texto("40003")
    c.tecla(4, espera=3.0)                      # "voltar" fecha o teclado (ESC não fecha o numérico)
    marco(c, "variavel-erro")                   # sem rolar: o "Lendo agora" (com o erro) fica à vista
    c.toque(*SUGESTAO, espera=4.0)


def c_rede(c: Celular):
    c.tecla(4, espera=1.0)
    c.toque(*DESCARTAR, espera=1.2)
    c.toque(*ABA_TELAS, espera=1.4)
    c.toque(*TELA_REDE, espera=4.5)
    c.toque(*LIGA, espera=1.3)
    c.toque(*CONFIRMAR, espera=7)


def c_falhas(c: Celular):
    c.espera(2.5)
    comando_painel("porta"); c.espera(6.5)
    comando_painel("porta"); c.espera(2.0)
    comando_painel("cair"); c.espera(12)


ROTEIRO = [
    Cena("abertura", "Ware IoT", tipo="cartao",
         narracao="Este é o Ware IoT: a IHM da máquina, montada e operada no celular, "
                  "conversando direto com o CLP pela rede da fábrica.",
         pontos=["A IHM da máquina, no celular"], gatilhos=["a IHM"]),
    Cena("inicio", "Pronto para usar", acao=c_inicio,
         narracao="O app já abre com uma demonstração pronta: uma cortadora de rótulos simulada, "
                  "com a tela de operação e o resumo do líder. Funciona sem nada na rede.",
         pontos=["Demonstração embutida", "Funciona sem CLP"]),
    Cena("operar", "Operar", acao=c_operar,
         # "Toco em Liga e confirmo" saía "toque… confirme" (a voz fecha o -o final)
         narracao="Cada elemento da tela está ligado a uma memória do CLP. Um toque em Liga, "
                  "e o app pede confirmação. "
                  "O botão só acende quando o equipamento confirma que ligou. "
                  "A velocidade sobe em rampa, a produção conta, e o motor começa a esquentar.",
         pontos=["Estado real, lido do CLP", "Confirmação antes de gravar", "Cor só onde importa"]),
    Cena("ajuste", "Ajustar", acao=c_ajuste,
         narracao="Para mudar um parâmetro, é só tocar e digitar num teclado grande, "
                  "feito para o chão de fábrica, e com os limites de segurança que o integrador definir.",
         pontos=["Teclado grande", "Limites de segurança"]),
    Cena("graficos", "Acompanhar", acao=c_graficos,
         narracao="Mais abaixo, a tendência dos últimos minutos e a produção por hora: "
                  "oito memórias seguidas, lidas num pedido só.",
         pontos=["Tendência ao vivo", "Produção por hora"]),
    Cena("editor", "Montar a tela", acao=c_editor,
         # A narração acompanha a ação (~25 s): mais curta, sobravam 10 s de silêncio.
         # Sem "crio", "escolho", "concluo": a voz fecha o -o final e a
         # transcrição ouvia "cri", "escolha", "conclui".
         narracao="Montar uma tela é tão simples quanto usar. Vou criar uma tela nova, o Painel. "
                  "Toco em Elemento, toco na lâmpada e ligo na variável da faca: "
                  "ela já aparece com o valor ao vivo. Depois, um botão ligado em Liga máquina. "
                  "Toco em Concluir, e a tela está pronta. Não existe botão de salvar: tudo fica gravado na hora.",
         pontos=["Arrastar e soltar", "Valor ao vivo na edição", "Salva sozinho"]),
    Cena("variavel", "Variáveis", acao=c_variavel,
         narracao="Cada variável é só um nome para uma memória. Toco no equipamento e, no endereço, "
                  "vai o número como vem no manual: quarenta mil e três. O app avisa que ele não existe "
                  "no equipamento e sugere o certo. Com um toque, já aparece o valor lido: "
                  "a velocidade da máquina, ao vivo.",
         pontos=["Lendo agora, enquanto digita", "Entende a notação do manual"]),
    Cena("rede", "Rede de verdade", tipo="dividido", acao=c_rede,
         narracao="Agora, com rede de verdade: volto às telas e abro a Cortadora na rede. "
                  "No computador, o simulador faz o papel do CLP. "
                  "O celular conecta pelo IP, e cada pedido aparece aqui do lado: "
                  "repare que as variáveis vizinhas saem num pedido só. "
                  "Ligo a máquina pelo celular, confirmo, e o simulador responde na hora.",
         pontos=["Modbus TCP real", "Leituras agrupadas"]),
    Cena("falhas", "O chão de fábrica, no celular", tipo="dividido", acao=c_falhas,
         narracao="E o que acontece na máquina aparece no celular. No simulador, eu abro a porta: "
                  "a máquina para e o alarme dispara na hora, e o botão Liga avisa que ficou sem retorno. "
                  "Fecho a porta. Agora derrubo a rede: o app não mostra um zero falso. "
                  "Ele mantém o último valor esmaecido, avisa que perdeu a conexão, "
                  "e reconecta sozinho quando a rede volta.",
         pontos=["Alarme na hora", "Queda de rede sem zero falso", "Reconecta sozinho"]),
    # O fecho era um cartão só, de 26 s, com os "próximos passos" na tela
    # enquanto a voz falava de outra coisa: virou dois.
    Cena("base", "Por baixo disso tudo", tipo="cartao",
         narracao="Por baixo disso tudo: quase oitocentos testes automáticos, simulador para testar sem hardware, "
                  "tutorial em cada tela e documentação técnica completa. "
                  "O app já tem receitas, registro em planilha e alarme falado no fone, "
                  "e fala também Siemens S7, OPC UA, MQTT e Arduino, que passam nos testes com simulador.",
         pontos=["Quase 800 testes automáticos", "Simulador para testar sem hardware",
                 "Tutorial em cada tela e documentação técnica", "Receitas, planilha e alarme falado no fone",
                 "Siemens S7, OPC UA, MQTT e Arduino, testados no simulador"],
         gatilhos=["quase", "simulador", "tutorial", "receitas", "Siemens"]),
    Cena("fecho", "Próximos passos", tipo="cartao",
         narracao="Próximos passos: conferir tudo na cortadora e nas máquinas das marcas parceiras, "
                  "e publicar na Play Store.",
         pontos=["Teste na cortadora de rótulos", "Conferência nas marcas parceiras", "Publicação na Play Store"],
         gatilhos=["cortadora", "marcas", "publicar"]),
]


# ── Narração ─────────────────────────────────────────────────────────────────

def duracao(arquivo: Path) -> float:
    r = subprocess.run([str(FFPROBE), "-v", "error", "-show_entries", "format=duration",
                        "-of", "default=noprint_wrappers=1:nokey=1", str(arquivo)],
                       capture_output=True, text=True, check=True)
    return float(r.stdout.strip())


def falado(texto: str) -> str:
    """O texto como a voz precisa ler (a tela continua com a grafia certa)."""
    for escrito, dito in PRONUNCIA.items():
        texto = re.sub(rf"\b{re.escape(escrito)}\b", dito, texto)
    return texto


MOTOR_VOZ = "kokoro-frase-a-frase"   # entra na chave do cache: mudou o motor, refaz tudo


def audio_da_cena(cena: Cena) -> Path:
    chave = hashlib.sha1(f"{MOTOR_VOZ}|{VOZ}|{falado(cena.narracao)}".encode()).hexdigest()[:12]
    return TRAB / "audio" / f"{cena.id}-{chave}.mp3"


def narrar_tudo(cenas: list[Cena]):
    """Texto → mp3 (Kokoro, local) das cenas sem áudio, numa chamada só; volume em −16 LUFS.

    Cache por texto+voz: mudar uma frase só refaz aquela cena."""
    pasta = TRAB / "audio"; pasta.mkdir(parents=True, exist_ok=True)
    faltam = [c for c in cenas if not audio_da_cena(c).exists() or audio_da_cena(c).stat().st_size == 0]
    if not faltam:
        return
    pares = []
    for c in faltam:
        txt, wav = pasta / f"{c.id}.txt", pasta / f"{c.id}.wav"
        txt.write_text(falado(c.narracao), encoding="utf-8")   # por arquivo: acento quebra linha de comando
        pares += [str(txt), str(wav)]
    print(f"Narrando {len(faltam)} cena(s) com o Kokoro ({VOZ})…", flush=True)
    subprocess.run([str(PYTHON_VOZ), str(AQUI / "falar_kokoro.py"), VOZ, *pares],
                   check=True, capture_output=True)
    for c in faltam:
        txt, wav = pasta / f"{c.id}.txt", pasta / f"{c.id}.wav"
        ff("-i", str(wav), "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "48000",
           "-c:a", "libmp3lame", "-b:a", "192k", str(audio_da_cena(c)))
        txt.unlink(); wav.unlink()


def narrar(cena: Cena) -> tuple[Path, float]:
    mp3 = audio_da_cena(cena)
    return mp3, duracao(mp3)


# ── Gravação ─────────────────────────────────────────────────────────────────

def painel_aberto() -> bool:
    """A janela do painel existe e não está minimizada (minimizada, a captura para)."""
    u = ctypes.windll.user32
    h = u.FindWindowW(None, PAINEL_TITULO)
    if not h:
        return False
    if u.IsIconic(h):
        u.ShowWindow(h, 9)   # SW_RESTORE
    return True


# Captura da JANELA do painel (Windows Graphics Capture, ffmpeg ≥ 8): grava o
# conteúdo dela mesmo com outra janela por cima. A captura anterior era da
# ÁREA da tela (ddagrab) e, em out/2026, o console do emulador e o VS Code
# entraram no vídeo no lugar do simulador. Sem a moldura do Windows, em
# pixels físicos (o gdigrab por título errava com a escala de 250%).
CAPTURA_PAINEL = ("gfxcapture=window_title=Simulador Modbus TCP.*:capture_cursor=0:max_framerate=30"
                  ":width=-2:height=-2,hwdownload,format=bgra")


def gravar(cena: Cena, c: Celular, minimo: float) -> tuple[Path, Path | None]:
    """Grava a ação da cena. Devolve (vídeo do celular, vídeo do painel ou None)."""
    pasta = TRAB / "bruto"; pasta.mkdir(parents=True, exist_ok=True)
    cel = pasta / f"{cena.id}-celular.mp4"
    pan = pasta / f"{cena.id}-painel.mp4" if cena.tipo == "dividido" else None
    for f in (cel, pan):
        if f and f.exists():
            f.unlink()   # lição da Retífica: arquivo velho vira vídeo curto sem aviso

    c.adb("shell", "rm", "-f", "/sdcard/cena.mp4", check=False)
    rec = subprocess.Popen([ADB, "shell", "screenrecord", "--size", "720x1600",
                            "--bit-rate", "10000000", "/sdcard/cena.mp4"])
    grab = None
    if pan:
        if not painel_aberto():
            raise SystemExit("O painel do simulador não está aberto: a cena dividida ficaria sem ele.")
        grab = subprocess.Popen([str(FFMPEG), "-hide_banner", "-loglevel", "error", "-y",
                                 "-f", "lavfi", "-i", CAPTURA_PAINEL,
                                 "-c:v", "libx264", "-preset", "ultrafast", "-crf", "16",
                                 "-pix_fmt", "yuv420p", str(pan)], stdin=subprocess.PIPE)
    time.sleep(1.2)   # os dois gravadores levam um instante para começar
    t0 = time.time()
    if cena.acao:
        cena.acao(c)
    falta = minimo - (time.time() - t0)
    if falta > 0:
        time.sleep(falta)
    time.sleep(0.8)
    c.adb("shell", "pkill", "-2", "screenrecord", check=False)
    if grab:
        grab.communicate(b"q")
    rec.wait(timeout=20)
    time.sleep(1.5)   # o screenrecord fecha o mp4 depois do sinal
    c.adb("pull", "/sdcard/cena.mp4", str(cel))
    if pan and (not pan.exists() or pan.stat().st_size == 0):
        raise SystemExit(f"A captura do painel falhou na cena {cena.id}.")
    return cel, pan


# ── Arte (cartões e legendas) ────────────────────────────────────────────────

def fonte(nome, tam):
    return ImageFont.truetype(str(FONTES / nome), tam)


def fundo(cena: Cena, idx: int, total: int) -> Path:
    """Palco da cena: fundo, título, pontos e o lugar do celular/painel."""
    img = Image.new("RGB", (L, A), BG)
    d = ImageDraw.Draw(img)
    titulo_f = fonte("IBMPlexSansCondensed-Bold.ttf", 76)
    ponto_f = fonte("IBMPlexSans-500.ttf", 36)
    marca_f = fonte("IBMPlexSansCondensed-SemiBold.ttf", 26)

    if cena.tipo == "cartao":
        # Os pontos e a barra de progresso NÃO entram aqui: cada ponto vira uma
        # camada que aparece quando a narração chega nele, e a barra é desenhada
        # depois do zoom (ver montar).
        d.text((160, 330), "WARE IOT", font=marca_f, fill=DESTAQUE)
        d.text((160, 380), cena.titulo, font=fonte("IBMPlexSansCondensed-Bold.ttf", 120), fill=TEXTO)
        d.rectangle([160, 540, 360, 548], fill=DESTAQUE)
        icone = RAIZ / "store" / "icone-512.png"
        if icone.exists():
            ic = Image.open(icone).convert("RGB").resize((380, 380))
            m = Image.new("L", ic.size, 0); ImageDraw.Draw(m).rounded_rectangle([0, 0, 379, 379], 84, fill=255)
            img.paste(ic, (1380, 350), m)
        CAMADAS[cena.id] = []
        for k, p in enumerate(cena.pontos):
            camada = Image.new("RGBA", (L, A), (0, 0, 0, 0))
            ImageDraw.Draw(camada).text((160, 600 + 66 * k), p, font=fonte("IBMPlexSans-500.ttf", 44), fill=DIM)
            arq_p = TRAB / "arte" / f"{cena.id}-ponto{k}.png"; arq_p.parent.mkdir(parents=True, exist_ok=True)
            camada.save(arq_p)
            CAMADAS[cena.id].append(arq_p)
        arq = TRAB / "arte" / f"{cena.id}.png"
        img.save(arq)
        return arq
    elif cena.tipo == "celular":
        d.rounded_rectangle([150, 30, 150 + 470, 30 + 1020], 46, fill=SURFACE)   # moldura do aparelho
        x = 760
        d.text((x, 300), "WARE IOT", font=marca_f, fill=DESTAQUE)
        d.text((x, 345), cena.titulo, font=titulo_f, fill=TEXTO)
        y = 480
        for p in cena.pontos:
            d.ellipse([x, y + 16, x + 14, y + 30], fill=DESTAQUE)
            d.text((x + 34, y), p, font=ponto_f, fill=DIM); y += 64
    else:  # dividido: celular à esquerda, painel à direita
        d.rounded_rectangle([60, 30, 60 + 470, 30 + 1020], 46, fill=SURFACE)
        d.text((620, 40), "WARE IOT  ·  SIMULADOR NO PC", font=marca_f, fill=DESTAQUE)
        d.text((620, 78), cena.titulo, font=fonte("IBMPlexSansCondensed-Bold.ttf", 60), fill=TEXTO)
        x = 620; y = 1000
        for p in cena.pontos:
            w = d.textlength(p, font=fonte("IBMPlexSans-500.ttf", 28))
            d.rounded_rectangle([x, y, x + w + 36, y + 48], 24, fill=SURFACE)
            d.text((x + 18, y + 7), p, font=fonte("IBMPlexSans-500.ttf", 28), fill=DIM)
            x += w + 56
    # progresso discreto no pé
    d.rectangle([0, A - 6, int(L * (idx + 1) / total), A], fill=DESTAQUE)
    arq = TRAB / "arte" / f"{cena.id}.png"; arq.parent.mkdir(parents=True, exist_ok=True)
    img.save(arq)
    return arq


# ── Montagem ─────────────────────────────────────────────────────────────────

def ff(*args):
    subprocess.run([str(FFMPEG), "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


CAMADAS: dict[str, list[Path]] = {}   # cartão → uma imagem transparente por ponto
ZOOM_CARTAO = 0.035                   # empurrão lento: 3,5% ao longo do cartão


def instantes_dos_pontos(cena: Cena, dur: float) -> list[float]:
    """Quando cada ponto do cartão aparece: na palavra-gatilho da narração
    (posição no texto × duração da fala — a voz sintética fala em ritmo quase
    constante) ou, sem gatilho, espaçados por igual."""
    n = len(cena.pontos)
    if cena.gatilhos and len(cena.gatilhos) == n:
        return [max(0.5, dur * max(0, cena.narracao.find(g)) / len(cena.narracao)) for g in cena.gatilhos]
    return [0.5 + k * (dur * 0.8) / max(1, n) for k in range(n)]


def montar(cena: Cena, arte: Path, audio: Path, dur: float, cel: Path | None, pan: Path | None,
           barra: int = 0) -> Path:
    """Uma cena em 1920×1080 com a narração; a imagem congela no fim se a voz for mais longa."""
    out = TRAB / "cenas" / f"{cena.id}.mp4"; out.parent.mkdir(parents=True, exist_ok=True)
    total = dur + 0.9
    base = ["-loop", "1", "-framerate", "30", "-t", f"{total:.2f}", "-i", str(arte)]
    if cena.tipo == "cartao":
        # Cartão parado é imagem congelada (a esteira de QA reprovou 26 s sem
        # mudar um pixel): os pontos entram quando a voz chega neles, e o
        # quadro todo se aproxima devagar. O zoom roda em 4K e desce para
        # 1080p — em 1080p o zoompan arredonda para pixel inteiro e treme.
        camadas = CAMADAS.get(cena.id, [])
        entradas = list(base)
        for c in camadas:
            entradas += ["-loop", "1", "-framerate", "30", "-t", f"{total:.2f}", "-i", str(c)]
        entradas += ["-i", str(audio)]
        filtro, ultimo = "[0:v]format=rgba[b0]", "[b0]"
        for k, t in enumerate(instantes_dos_pontos(cena, dur)[:len(camadas)]):
            filtro += (f";[{k + 1}:v]format=rgba,fade=t=in:st={t:.2f}:d=0.5:alpha=1[p{k}]"
                       f";{ultimo}[p{k}]overlay=0:0[b{k + 1}]")
            ultimo = f"[b{k + 1}]"
        quadros = round(total * 30)
        filtro += (f";{ultimo}scale=3840:2160:flags=lanczos,"
                   f"zoompan=z='1+{ZOOM_CARTAO}*on/{quadros}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
                   f":d=1:s=1920x1080:fps=30,"
                   f"drawbox=x=0:y={A - 6}:w={max(1, barra)}:h=6:color=0x2EC4D0:t=fill,"
                   f"fade=t=in:st=0:d=0.4,format=yuv420p[v]")
        # apad: o áudio precisa ter a MESMA duração da cena, senão a emenda
        # com -c copy desalinha som e imagem das cenas seguintes.
        filtro += f";[{len(camadas) + 1}:a]apad[a]"
        ff(*entradas, "-filter_complex", filtro, "-map", "[v]", "-map", "[a]",
           "-c:v", "libx264", "-crf", "18", "-r", "30", "-c:a", "aac", "-b:a", "160k", "-t", f"{total:.2f}", str(out))
        return out
    px = 172 if cena.tipo == "celular" else 82
    # trim: descarta o segundo morto antes da ação (os gravadores levam ~1 s para pegar).
    # fps ANTES do trim: o screenrecord só manda quadro quando a tela muda — com a
    # tela parada, o único quadro é o do instante 0, o trim o jogava fora e a cena
    # pulava direto para depois do primeiro toque (a lista de telas sumia do "inicio").
    cel_f = (f"[1:v]fps=30,trim=start={PRE_ROLL},setpts=PTS-STARTPTS,scale=-2:976,"
             f"tpad=stop_mode=clone:stop_duration={total:.2f}[cel]")
    filtro = f"{cel_f};[0:v][cel]overlay={px}:52:shortest=0[b]"
    entradas = [*base, "-i", str(cel)]
    ultimo = "[b]"
    if pan:
        entradas += ["-i", str(pan)]
        filtro += (f";[2:v]fps=30,trim=start={PRE_ROLL},setpts=PTS-STARTPTS,"
                   # cabe na área entre o título (y 170) e as etiquetas (y 1000)
                   f"scale=1240:800:force_original_aspect_ratio=decrease:flags=lanczos,"
                   f"tpad=stop_mode=clone:stop_duration={total:.2f}[pan];[b][pan]overlay=620:170[b2]")
        ultimo = "[b2]"
    entradas += ["-i", str(audio)]
    n_in = sum(1 for a in entradas if a == "-i")
    filtro += f";{ultimo}format=yuv420p[v];[{n_in - 1}:a]apad[a]"
    ff(*entradas, "-filter_complex", filtro, "-map", "[v]", "-map", "[a]",
       "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-r", "30",
       "-c:a", "aac", "-b:a", "160k", "-t", f"{total:.2f}", str(out))
    return out


def emendar(arquivos: list[Path], saida: Path):
    lista = TRAB / "lista.txt"
    lista.write_text("\n".join(f"file '{a.as_posix()}'" for a in arquivos), encoding="utf-8")
    ff("-f", "concat", "-safe", "0", "-i", str(lista), "-c", "copy", "-movflags", "+faststart", str(saida))


# ── Preparação do aparelho e do simulador ────────────────────────────────────

def preparar(c: Celular):
    """Estado limpo e igual toda vez: projeto do vídeo, app reiniciado, simulador novo."""
    proj = TRAB / "projeto-video.json"
    atual = TRAB / "projeto-base.json"
    if not atual.exists():
        raise SystemExit("Falta .trabalho/projeto-base.json (o projeto de demonstração puxado do aparelho).")
    subprocess.run([PYTHON, str(AQUI / "preparar_projeto.py"), str(atual), str(proj)], check=True)
    c.adb("shell", "am", "force-stop", PACOTE)
    c.adb("push", str(proj), "/data/local/tmp/p.json")
    c.adb("shell", f"run-as {PACOTE} sh -c 'cat /data/local/tmp/p.json > app_flutter/projeto.ihm.json'")
    c.adb("shell", "settings", "put", "system", "show_touches", "1")
    c.adb("shell", "settings", "put", "secure", "stylus_handwriting_enabled", "0")

    fechar_simuladores()
    painel = subprocess.Popen([str(SIM / ".venv" / "Scripts" / "python.exe"), str(SIM / "simulador.py"), "--painel"], cwd=SIM)
    time.sleep(3)
    # -W espera a primeira tela: a partida a frio passou de 10 s com o PC
    # carregado, e o toque da cena seguinte caía na tela de abertura.
    c.adb("shell", "am", "start", "-W", "-n", f"{PACOTE}/.MainActivity")
    time.sleep(3)
    return painel


def fechar_simuladores():
    """Fecha painéis de rodadas anteriores (o filtro do taskkill por título não pegava)."""
    subprocess.run(["powershell", "-NoProfile", "-Command",
                    "Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | "
                    "Where-Object { $_.CommandLine -match 'simulador\\.py' } | "
                    "ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"], capture_output=True)


def main():
    ensaio = ENSAIO
    narrar_tudo(ROTEIRO)
    c = Celular()
    if REMONTAR:
        rodar(c, False)
        return
    painel = preparar(c)
    try:
        rodar(c, ensaio)
    finally:
        painel.terminate()


def rodar(c: Celular, ensaio: bool):
    marcas, cenas = [], []
    relogio = 0.0
    for i, cena in enumerate(ROTEIRO):
        audio, dur = narrar(cena)
        print(f"[{i + 1}/{len(ROTEIRO)}] {cena.id}: narração {dur:.1f}s", flush=True)
        if ensaio:
            if cena.acao:
                cena.acao(c)
            c.foto(f"{i + 1:02d}-{cena.id}")
            continue
        cel = pan = None
        if cena.tipo != "cartao" and REMONTAR:
            cel = TRAB / "bruto" / f"{cena.id}-celular.mp4"
            pan = TRAB / "bruto" / f"{cena.id}-painel.mp4" if cena.tipo == "dividido" else None
            if not cel.exists() or (pan and not pan.exists()):
                raise SystemExit(f"Falta a gravação da cena {cena.id}: rode sem 'remontar'.")
            dur = max(dur, duracao(cel) - 1.2)
        elif cena.tipo != "cartao":
            cel, pan = gravar(cena, c, minimo=dur)
            dur = max(dur, duracao(cel) - 1.2)
        out = montar(cena, fundo(cena, i, len(ROTEIRO)), audio, dur, cel, pan,
                     barra=int(L * (i + 1) / len(ROTEIRO)))
        marcas.append((relogio, cena.titulo))
        relogio += duracao(out)
        cenas.append(out)
    if ensaio:
        print("Ensaio feito: fotos em", TRAB / "fotos")
        return
    SAIDA.mkdir(exist_ok=True)
    final = SAIDA / "ware-iot-apresentacao.mp4"
    emendar(cenas, final)
    # arredonda ANTES de dividir (armadilha 4 da Retífica): 119,6 s virava "01:00"
    cap = "\n".join(f"{round(t) // 60:02d}:{round(t) % 60:02d}  {nome}" for t, nome in marcas)
    (SAIDA / "ware-iot-apresentacao-capitulos.txt").write_text(cap + "\n", encoding="utf-8")
    print(f"Pronto: {final} ({duracao(final):.0f}s)")


if __name__ == "__main__":
    main()
