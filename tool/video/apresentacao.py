"""Vídeo de apresentação do Celiware IHM — gravado do sistema rodando de verdade.

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
Pré-requisitos: emulador ligado com o app instalado; `tool/video/preparar_projeto.py`
já tem o projeto (ele é empurrado para o aparelho no início).
Saída: tool/video/saida/celiware-ihm-apresentacao.mp4 (+ capítulos).
"""
from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import hashlib
import json
import os
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
PAINEL_TITULO = "Simulador Modbus TCP — Celiware IHM"
PACOTE = "com.celiware.ihm"
VOZ = "pt-BR-AntonioNeural"

L, A = 1920, 1080  # palco
BG = (18, 20, 24)
SURFACE = (35, 40, 48)
TEXTO, DIM, AMBAR = (233, 237, 241), (163, 173, 184), (255, 176, 32)


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


# Coordenadas do Pixel 7 (1080×2400), medidas nas capturas do ensaio.
LIGA, CONFIRMAR = (204, 948), (697, 1412)
AJUSTE = (300, 1300)
TECLA = {"1": (209, 1884), "2": (540, 1884), "0": (540, 2054)}
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
    for k in "120":
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
    c.toque(540, 1498, espera=1.6)              # Faca acionada
    c.tecla(4, espera=1.2)                      # fecha a configuração
    c.toque(*MAIS_ELEMENTO, espera=1.4)
    c.toque(*PALETA_BOTAO, espera=1.6)
    marco(c, "editor-config-botao")
    c.toque(*ESCOLHER_VARIAVEL_BOTAO, espera=1.3)
    marco(c, "editor-escolha-botao")
    c.toque(540, 1104, espera=1.6)              # Liga máquina
    c.tecla(4, espera=1.2)
    c.toque(*CONCLUIR, espera=3.0)


ESCOLHER_VARIAVEL_BOTAO = (540, 1290)
ENDERECO = (378, 1928)
SUGESTAO = (540, 2110)


def c_variavel(c: Celular):
    c.tecla(4, espera=1.0)
    c.toque(*ABA_VARIAVEIS, espera=1.6)
    c.toque(*FAB, espera=2.0)                   # Nova variável
    marco(c, "variavel-form")
    c.toque(*ENDERECO, espera=0.8)
    c.tecla(67, espera=0.3)
    c.texto("40003")
    c.tecla(4, espera=3.0)                      # "voltar" fecha o teclado (ESC não fecha o numérico)
    marco(c, "variavel-erro")                   # sem rolar: o "Lendo agora" (com o erro) fica à vista
    c.toque(*SUGESTAO, espera=4.0)


def c_rede(c: Celular):
    c.tecla(4, espera=1.0)
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
    Cena("abertura", "Celiware IHM", tipo="cartao",
         narracao="Este é o Celiware IHM: a IHM da máquina, montada e operada no celular, "
                  "conversando em Modbus TCP direto com o CLP.",
         pontos=["A IHM da máquina, no celular"]),
    Cena("inicio", "Pronto para usar", acao=c_inicio,
         narracao="O app já abre com uma demonstração pronta: uma cortadora de rótulos simulada, "
                  "com a tela de operação e o resumo do líder. Funciona sem nada na rede.",
         pontos=["Demonstração embutida", "Funciona sem CLP"]),
    Cena("operar", "Operar", acao=c_operar,
         narracao="Cada elemento da tela está ligado a uma memória do CLP. Toco em Liga e confirmo. "
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
         narracao="Montar uma tela é tão simples quanto usar. Crio uma tela nova, escolho o elemento na paleta "
                  "e ligo numa variável: ele já aparece com o valor ao vivo. "
                  "Uma lâmpada para a faca, um botão para ligar a máquina, e a tela está pronta. "
                  "Não existe botão de salvar: tudo fica gravado na hora.",
         pontos=["Arrastar e soltar", "Valor ao vivo na edição", "Salva sozinho"]),
    Cena("variavel", "Variáveis", acao=c_variavel,
         narracao="Cada variável é só um nome para uma memória. Se eu digitar o endereço como vem no manual, "
                  "quarenta mil e três, o app avisa que ele não existe no equipamento e sugere o certo. "
                  "Com um toque, já aparece o valor lido.",
         pontos=["Lendo agora, enquanto digita", "Entende a notação do manual"]),
    Cena("rede", "Rede de verdade", tipo="dividido", acao=c_rede,
         narracao="Agora, com rede de verdade. No computador, o simulador faz o papel do CLP. "
                  "O celular conecta pelo IP, e cada pedido aparece aqui do lado: "
                  "repare que as variáveis vizinhas saem num pedido só. "
                  "Ligo a máquina pelo celular, e o simulador responde.",
         pontos=["Modbus TCP real", "Leituras agrupadas"]),
    Cena("falhas", "O chão de fábrica, no celular", tipo="dividido", acao=c_falhas,
         narracao="E o que acontece na máquina aparece no celular. Abro a porta no simulador: "
                  "a máquina para e acusa alarme na hora. E se a rede cai, o app não mostra um zero falso: "
                  "mantém o último valor esmaecido, avisa, e reconecta sozinho quando a rede volta.",
         pontos=["Alarme na hora", "Queda de rede sem zero falso", "Reconecta sozinho"]),
    Cena("fecho", "Próximos passos", tipo="cartao",
         narracao="Por baixo disso tudo: cinquenta e um testes automáticos, simulador para testar sem hardware, "
                  "tutorial em cada tela e documentação técnica completa. "
                  "Próximos passos: testar na cortadora, criar o perfil Inovance e publicar na Play Store.",
         pontos=["Teste na cortadora de rótulos", "Perfil Inovance", "Publicação na Play Store"]),
]


# ── Narração ─────────────────────────────────────────────────────────────────

def duracao(arquivo: Path) -> float:
    r = subprocess.run([str(FFPROBE), "-v", "error", "-show_entries", "format=duration",
                        "-of", "default=noprint_wrappers=1:nokey=1", str(arquivo)],
                       capture_output=True, text=True, check=True)
    return float(r.stdout.strip())


def narrar(cena: Cena) -> tuple[Path, float]:
    """Texto → mp3 (edge-tts), com cache por texto+voz."""
    pasta = TRAB / "audio"; pasta.mkdir(parents=True, exist_ok=True)
    chave = hashlib.sha1(f"{VOZ}|{cena.narracao}".encode()).hexdigest()[:12]
    mp3 = pasta / f"{cena.id}-{chave}.mp3"
    if not mp3.exists():
        txt = pasta / f"{cena.id}.txt"
        txt.write_text(cena.narracao, encoding="utf-8")   # por arquivo: acento quebra linha de comando
        subprocess.run([PYTHON, "-m", "edge_tts", "--voice", VOZ, "--rate", "+4%",
                        "--file", str(txt), "--write-media", str(mp3)], check=True)
        txt.unlink()
    return mp3, duracao(mp3)


# ── Gravação ─────────────────────────────────────────────────────────────────

def janela_painel_na_frente() -> bool:
    u = ctypes.windll.user32
    h = u.FindWindowW(None, PAINEL_TITULO)
    if not h:
        return False
    HWND_TOPMOST, SWP_NOMOVE, SWP_NOSIZE = -1, 0x2, 0x1
    u.SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE)
    u.SetForegroundWindow(h)
    return True


def retangulo_painel() -> tuple[int, int, int, int]:
    """Posição e tamanho da janela do painel em pixels FÍSICOS (x, y, w, h).

    O gdigrab por título não sabe de DPI: em tela a 250% gravava a janela
    num quadro errado (conteúdo miúdo no canto, resto preto). Por isso a
    captura é da área da tela (ddagrab) com o retângulo medido aqui, com o
    processo marcado como ciente de DPI e sem a sombra da janela (DWM)."""
    u = ctypes.windll.user32
    u.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))   # PER_MONITOR_AWARE_V2
    h = u.FindWindowW(None, PAINEL_TITULO)
    r = wt.RECT()
    ctypes.windll.dwmapi.DwmGetWindowAttribute(h, 9, ctypes.byref(r), ctypes.sizeof(r))  # EXTENDED_FRAME_BOUNDS
    # A janela passa por baixo da barra de tarefas; sem cortar na área útil
    # do monitor, os ícones da barra entravam no vídeo.
    class MONITORINFO(ctypes.Structure):
        _fields_ = [("cbSize", wt.DWORD), ("rcMonitor", wt.RECT), ("rcWork", wt.RECT), ("dwFlags", wt.DWORD)]
    mi = MONITORINFO(cbSize=ctypes.sizeof(MONITORINFO))
    u.GetMonitorInfoW(u.MonitorFromWindow(h, 2), ctypes.byref(mi))
    baixo = min(r.bottom, mi.rcWork.bottom)
    w, a = (r.right - r.left) // 2 * 2, (baixo - r.top) // 2 * 2   # yuv420p pede lados pares
    return r.left, r.top, w, a


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
        janela_painel_na_frente()
        x, y, w, a = retangulo_painel()
        dda = f"ddagrab=output_idx=0:framerate=30:offset_x={x}:offset_y={y}:video_size={w}x{a},hwdownload,format=bgra"
        grab = subprocess.Popen([str(FFMPEG), "-hide_banner", "-loglevel", "error", "-y",
                                 "-f", "lavfi", "-i", dda,
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
        d.text((160, 330), "CELIWARE IHM", font=marca_f, fill=AMBAR)
        d.text((160, 380), cena.titulo, font=fonte("IBMPlexSansCondensed-Bold.ttf", 120), fill=TEXTO)
        d.rectangle([160, 540, 360, 548], fill=AMBAR)
        y = 600
        for p in cena.pontos:
            d.text((160, y), p, font=fonte("IBMPlexSans-500.ttf", 44), fill=DIM); y += 66
        icone = RAIZ / "store" / "icone-512.png"
        if icone.exists():
            ic = Image.open(icone).convert("RGB").resize((380, 380))
            m = Image.new("L", ic.size, 0); ImageDraw.Draw(m).rounded_rectangle([0, 0, 379, 379], 84, fill=255)
            img.paste(ic, (1380, 350), m)
    elif cena.tipo == "celular":
        d.rounded_rectangle([150, 30, 150 + 470, 30 + 1020], 46, fill=SURFACE)   # moldura do aparelho
        x = 760
        d.text((x, 300), "CELIWARE IHM", font=marca_f, fill=AMBAR)
        d.text((x, 345), cena.titulo, font=titulo_f, fill=TEXTO)
        y = 480
        for p in cena.pontos:
            d.ellipse([x, y + 16, x + 14, y + 30], fill=AMBAR)
            d.text((x + 34, y), p, font=ponto_f, fill=DIM); y += 64
    else:  # dividido: celular à esquerda, painel à direita
        d.rounded_rectangle([60, 30, 60 + 470, 30 + 1020], 46, fill=SURFACE)
        d.text((620, 40), "CELIWARE IHM  ·  SIMULADOR NO PC", font=marca_f, fill=AMBAR)
        d.text((620, 78), cena.titulo, font=fonte("IBMPlexSansCondensed-Bold.ttf", 60), fill=TEXTO)
        x = 620; y = 1000
        for p in cena.pontos:
            w = d.textlength(p, font=fonte("IBMPlexSans-500.ttf", 28))
            d.rounded_rectangle([x, y, x + w + 36, y + 48], 24, fill=SURFACE)
            d.text((x + 18, y + 7), p, font=fonte("IBMPlexSans-500.ttf", 28), fill=DIM)
            x += w + 56
    # progresso discreto no pé
    d.rectangle([0, A - 6, int(L * (idx + 1) / total), A], fill=AMBAR)
    arq = TRAB / "arte" / f"{cena.id}.png"; arq.parent.mkdir(parents=True, exist_ok=True)
    img.save(arq)
    return arq


# ── Montagem ─────────────────────────────────────────────────────────────────

def ff(*args):
    subprocess.run([str(FFMPEG), "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def montar(cena: Cena, arte: Path, audio: Path, dur: float, cel: Path | None, pan: Path | None) -> Path:
    """Uma cena em 1920×1080 com a narração; a imagem congela no fim se a voz for mais longa."""
    out = TRAB / "cenas" / f"{cena.id}.mp4"; out.parent.mkdir(parents=True, exist_ok=True)
    total = dur + 0.9
    base = ["-loop", "1", "-framerate", "30", "-t", f"{total:.2f}", "-i", str(arte)]
    if cena.tipo == "cartao":
        # apad: o áudio precisa ter a MESMA duração da cena, senão a emenda
        # com -c copy desalinha som e imagem das cenas seguintes.
        filtro = "[0:v]fade=t=in:st=0:d=0.4,format=yuv420p[v];[1:a]apad[a]"
        ff(*base, "-i", str(audio), "-filter_complex", filtro, "-map", "[v]", "-map", "[a]",
           "-c:v", "libx264", "-crf", "18", "-r", "30", "-c:a", "aac", "-b:a", "160k", "-t", f"{total:.2f}", str(out))
        return out
    px = 172 if cena.tipo == "celular" else 82
    # trim: descarta o segundo morto antes da ação (os gravadores levam ~1 s para pegar)
    cel_f = (f"[1:v]trim=start={PRE_ROLL},setpts=PTS-STARTPTS,fps=30,scale=-2:976,"
             f"tpad=stop_mode=clone:stop_duration={total:.2f}[cel]")
    filtro = f"{cel_f};[0:v][cel]overlay={px}:52:shortest=0[b]"
    entradas = [*base, "-i", str(cel)]
    ultimo = "[b]"
    if pan:
        entradas += ["-i", str(pan)]
        filtro += (f";[2:v]trim=start={PRE_ROLL},setpts=PTS-STARTPTS,fps=30,"
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

    subprocess.run(["taskkill", "/F", "/FI", f"WINDOWTITLE eq {PAINEL_TITULO}"], capture_output=True)
    subprocess.Popen([str(SIM / ".venv" / "Scripts" / "python.exe"), str(SIM / "simulador.py"), "--painel"], cwd=SIM)
    time.sleep(3)
    c.adb("shell", "am", "start", "-n", f"{PACOTE}/.MainActivity")
    time.sleep(6)


def main():
    ensaio = ENSAIO
    c = Celular()
    preparar(c)
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
        if cena.tipo != "cartao":
            cel, pan = gravar(cena, c, minimo=dur)
            dur = max(dur, duracao(cel) - 1.2)
        out = montar(cena, fundo(cena, i, len(ROTEIRO)), audio, dur, cel, pan)
        marcas.append((relogio, cena.titulo))
        relogio += duracao(out)
        cenas.append(out)
    if ensaio:
        print("Ensaio feito: fotos em", TRAB / "fotos")
        return
    SAIDA.mkdir(exist_ok=True)
    final = SAIDA / "celiware-ihm-apresentacao.mp4"
    emendar(cenas, final)
    # arredonda ANTES de dividir (armadilha 4 da Retífica): 119,6 s virava "01:00"
    cap = "\n".join(f"{round(t) // 60:02d}:{round(t) % 60:02d}  {nome}" for t, nome in marcas)
    (SAIDA / "celiware-ihm-apresentacao-capitulos.txt").write_text(cap + "\n", encoding="utf-8")
    print(f"Pronto: {final} ({duracao(final):.0f}s)")


if __name__ == "__main__":
    main()
