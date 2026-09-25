"""Painel gráfico do simulador — o "CLP" visível na tela do PC.

Mostra, ao vivo, o que está na memória do escravo Modbus e cada pedido que o
app faz, e tem botões para provocar as situações de chão de fábrica:

  • Abrir/fechar a porta   → o programa da cortadora para e acusa alarme;
  • Superaquecer o motor   → dispara o alarme de sobretemperatura;
  • Derrubar a rede (6 s)  → o servidor sai do ar e volta sozinho.

Serve para demonstrar e para testar o app com os olhos: o que o celular grava
aparece aqui; o que muda aqui aparece no celular.

Os mesmos comandos podem vir de fora, escrevendo uma palavra no arquivo
`sim/.comando` (porta · superaquecer · cair). É assim que o roteiro do vídeo
de apresentação aperta os botões no instante certo, sem mouse.

Uso: .venv\\Scripts\\python simulador.py --painel
"""

from __future__ import annotations

import asyncio
import collections
import struct
import threading
import time
import tkinter as tk
from pathlib import Path

from pymodbus.server import ServerAsyncStop, StartAsyncTcpServer

# Cores do app (lib/core/theme/app_theme.dart), para o painel parecer da família.
BG, SURFACE, SURFACE_HIGH = "#121418", "#1B1F25", "#232830"
TEXT, DIM, MUTED = "#E9EDF1", "#A3ADB8", "#6B7682"
AMBER, OK, ALARM, INFO, OFF = "#FFB020", "#2FBF71", "#E5484D", "#3E9BFF", "#3A414B"

FONT = "Segoe UI"
MONO = "Consolas"

COIL, DI, HR, IR = 1, 2, 3, 4
TITULO_JANELA = "Simulador Modbus TCP — Celiware IHM"
ARQUIVO_COMANDO = Path(__file__).with_name(".comando")

NOMES_FC = {1: "lê coils", 2: "lê entradas", 3: "lê registradores", 4: "lê input reg.",
            5: "grava coil", 6: "grava registrador", 15: "grava coils", 16: "grava registradores"}


class Servidor:
    """Servidor Modbus num laço asyncio próprio, numa thread — o Tk manda na principal."""

    def __init__(self, ctx, host: str, port: int, proc=None):
        self.ctx, self.host, self.port, self.proc = ctx, host, port, proc
        self.loop = asyncio.new_event_loop()
        self.clientes = 0
        self.no_ar = False
        self.log: collections.deque[tuple[float, bool, str]] = collections.deque(maxlen=14)
        self.pedidos = 0

    # ── ganchos do pymodbus ──────────────────────────────────────────────────
    def _trace_connect(self, conectou: bool) -> None:
        self.clientes = max(0, self.clientes + (1 if conectou else -1))

    def _trace_pdu(self, enviando: bool, pdu):
        if not enviando:  # só o pedido que chega
            self.pedidos += 1
            fc = getattr(pdu, "function_code", 0)
            addr = getattr(pdu, "address", 0)
            area = {1: "COIL", 2: "DI", 3: "HR", 4: "IR", 5: "COIL", 6: "HR", 15: "COIL", 16: "HR"}.get(fc, "?")
            escrita = fc in (5, 6, 15, 16)
            if escrita:
                bits = getattr(pdu, "bits", None) or []
                regs = getattr(pdu, "registers", None) or []
                if fc == 5:
                    valor = "LIGA" if (bits and bits[0]) else "DESLIGA"
                else:
                    valor = ", ".join(str(r) for r in regs[:4])
                texto = f"{NOMES_FC.get(fc, fc)}  {area} {addr} = {valor}"
            else:
                n = getattr(pdu, "count", 1)
                fim = addr + max(n, 1) - 1
                texto = f"{NOMES_FC.get(fc, fc)}  {area} {addr}" + (f"..{fim}" if n > 1 else "")
            self.log.appendleft((time.time(), escrita, texto))
        return pdu

    # ── ciclo de vida ────────────────────────────────────────────────────────
    def iniciar(self) -> None:
        threading.Thread(target=self._rodar, daemon=True).start()

    def _rodar(self) -> None:
        asyncio.set_event_loop(self.loop)
        if self.proc is not None:
            self.loop.create_task(self._processo())
        self.loop.create_task(self._servir())
        self.loop.run_forever()

    async def _processo(self) -> None:
        self.proc.seed()
        while True:
            self.proc.step(0.2)
            await asyncio.sleep(0.2)

    async def _servir(self) -> None:
        self.no_ar = True
        await StartAsyncTcpServer(context=self.ctx, address=(self.host, self.port),
                                  trace_pdu=self._trace_pdu, trace_connect=self._trace_connect)

    def derrubar(self, segundos: float = 6) -> None:
        """Simula queda de rede: tira o servidor do ar e volta depois."""
        async def ciclo():
            self.no_ar = False
            await ServerAsyncStop()
            self.clientes = 0
            await asyncio.sleep(segundos)
            self.loop.create_task(self._servir())
        asyncio.run_coroutine_threadsafe(ciclo(), self.loop)


class Painel:
    def __init__(self, servidor: Servidor, unit: int, cenario: str):
        self.s, self.unit, self.cenario = servidor, unit, cenario
        self.root = tk.Tk()
        self.root.title(TITULO_JANELA)
        self.root.configure(bg=BG)
        # Tamanho em unidades lógicas: o Tk multiplica pela escala do Windows
        # (250% num notebook 4K), então pedir pouco aqui ainda dá janela grande.
        self.root.geometry("1000x780+30+20")
        self.root.minsize(860, 700)
        self.cards: dict[str, tuple[tk.Label, tk.Label, tk.Canvas | None]] = {}
        self._montar()

    # ── leitura da memória ───────────────────────────────────────────────────
    def _v(self, fc: int, addr: int, n: int = 1):
        return self.s.ctx[self.unit].getValues(fc, addr, n)

    def _set(self, fc: int, addr: int, values):
        self.s.ctx[self.unit].setValues(fc, addr, values)

    # ── layout ───────────────────────────────────────────────────────────────
    def _montar(self) -> None:
        topo = tk.Frame(self.root, bg=BG)
        topo.pack(fill="x", padx=32, pady=(28, 8))
        tk.Label(topo, text="SIMULADOR MODBUS TCP", font=(FONT, 11, "bold"), fg=AMBER, bg=BG).pack(anchor="w")
        tk.Label(topo, text="Cortadora de rótulos" if self.cenario == "cortadora" else "Memória livre",
                 font=(FONT, 26, "bold"), fg=TEXT, bg=BG).pack(anchor="w")
        linha = tk.Frame(topo, bg=BG)
        linha.pack(anchor="w", pady=(6, 0))
        tk.Label(linha, text=f"Escutando {self.s.host}:{self.s.port} · ID {self.unit}",
                 font=(FONT, 12), fg=MUTED, bg=BG).pack(side="left")
        self.status = tk.Label(linha, text="", font=(FONT, 11, "bold"), padx=12, pady=3)
        self.status.pack(side="left", padx=16)

        grade = tk.Frame(self.root, bg=BG)
        grade.pack(fill="x", padx=24, pady=8)
        itens = [
            ("liga", "Liga máquina", "COIL 0"), ("status", "Status", "HR 0"),
            ("vel", "Velocidade", "HR 2"), ("sp", "Ajuste de velocidade", "HR 1"),
            ("prod", "Produção", "HR 3..4"), ("temp", "Motor", "HR 6..7"),
            ("porta", "Porta", "DI 0"), ("alarme", "Alarme", "HR 20"),
        ]
        for i, (chave, nome, endereco) in enumerate(itens):
            card = tk.Frame(grade, bg=SURFACE, padx=18, pady=14)
            card.grid(row=i // 4, column=i % 4, sticky="nsew", padx=8, pady=8)
            grade.columnconfigure(i % 4, weight=1)
            cab = tk.Frame(card, bg=SURFACE)
            cab.pack(fill="x")
            tk.Label(cab, text=nome.upper(), font=(FONT, 9, "bold"), fg=MUTED, bg=SURFACE).pack(side="left")
            tk.Label(cab, text=endereco, font=(MONO, 9), fg=AMBER, bg=SURFACE).pack(side="right")
            valor = tk.Label(card, text="—", font=(MONO, 24, "bold"), fg=TEXT, bg=SURFACE, anchor="w")
            valor.pack(fill="x", pady=(10, 0))
            self.cards[chave] = (valor, card, None)

        botoes = tk.Frame(self.root, bg=BG)
        botoes.pack(fill="x", padx=32, pady=(14, 6))
        self.b_porta = self._botao(botoes, "Abrir porta", self.acao_porta)
        self._botao(botoes, "Superaquecer motor", self.acao_quente)
        self.b_rede = self._botao(botoes, "Derrubar rede (6 s)", self.acao_cair, cor=ALARM)

        tk.Label(self.root, text="PEDIDOS DO APP", font=(FONT, 10, "bold"), fg=MUTED, bg=BG).pack(anchor="w", padx=32, pady=(18, 6))
        self.contador = tk.Label(self.root, text="", font=(FONT, 10), fg=MUTED, bg=BG)
        self.contador.place(relx=1.0, x=-32, y=0, anchor="ne")
        self.logbox = tk.Frame(self.root, bg=SURFACE, padx=18, pady=12)
        self.logbox.pack(fill="both", expand=True, padx=32, pady=(0, 28))
        self.linhas = [tk.Label(self.logbox, text="", font=(MONO, 12), fg=DIM, bg=SURFACE, anchor="w")
                       for _ in range(12)]
        for l in self.linhas:
            l.pack(fill="x")

    def _botao(self, pai, texto, cmd, cor=AMBER):
        b = tk.Label(pai, text=texto, font=(FONT, 12, "bold"), fg="#1A1300" if cor == AMBER else "white",
                     bg=cor, padx=20, pady=12, cursor="hand2")
        b.pack(side="left", padx=(0, 12))
        b.bind("<Button-1>", lambda _e: cmd())
        b._cor = cor  # type: ignore[attr-defined]
        return b

    def _piscar(self, botao):
        """Realce breve no botão acionado — no vídeo, mostra o "clique"."""
        botao.configure(bg=TEXT)
        self.root.after(350, lambda: botao.configure(bg=botao._cor))  # type: ignore[attr-defined]

    # ── ações ────────────────────────────────────────────────────────────────
    def acao_porta(self):
        fechada = bool(self._v(DI, 0)[0])
        self._set(DI, 0, [0 if fechada else 1])
        self._piscar(self.b_porta)

    def acao_quente(self):
        if self.s.proc is not None:
            self.s.proc.temp = 90.0

    def acao_cair(self):
        if self.s.no_ar:
            self._piscar(self.b_rede)
            self.s.derrubar(6)

    # ── laço de atualização ──────────────────────────────────────────────────
    def _atualizar(self):
        try:
            self._comando_externo()
            self._pintar()
        finally:
            self.root.after(150, self._atualizar)

    def _comando_externo(self):
        if ARQUIVO_COMANDO.exists():
            cmd = ARQUIVO_COMANDO.read_text(encoding="utf-8").strip()
            ARQUIVO_COMANDO.unlink(missing_ok=True)
            {"porta": self.acao_porta, "superaquecer": self.acao_quente, "cair": self.acao_cair}.get(cmd, lambda: None)()

    def _pintar(self):
        if not self.s.no_ar:
            self.status.configure(text="REDE FORA DO AR", fg="white", bg=ALARM)
        elif self.s.clientes > 0:
            self.status.configure(text=f"● app conectado", fg=BG, bg=OK)
        else:
            self.status.configure(text="aguardando o app", fg=DIM, bg=SURFACE_HIGH)

        liga = bool(self._v(COIL, 0)[0])
        st = self._v(HR, 0)[0]
        prod_hi, prod_lo = self._v(HR, 3, 2)
        t_hi, t_lo = self._v(HR, 6, 2)
        temp = struct.unpack(">f", struct.pack(">HH", t_hi, t_lo))[0]
        porta = bool(self._v(DI, 0)[0])
        alarme = self._v(HR, 20)[0]

        self._card("liga", "LIGADA" if liga else "DESLIGADA", OK if liga else DIM)
        self._card("status", {0: "PARADA", 1: "EM CICLO", 2: "ALARME"}.get(st, str(st)),
                   {1: OK, 2: ALARM}.get(st, TEXT))
        self._card("vel", f"{self._v(HR, 2)[0]} m/min")
        self._card("sp", f"{self._v(HR, 1)[0]} m/min", AMBER)
        self._card("prod", f"{(prod_hi << 16) | prod_lo}")
        self._card("temp", f"{temp:.1f} °C".replace(".", ","), ALARM if temp >= 85 else (AMBER if temp >= 75 else TEXT))
        self._card("porta", "FECHADA" if porta else "ABERTA", OK if porta else ALARM)
        self._card("alarme", {0: "nenhum", 1: "TEMPERATURA", 2: "PORTA"}.get(alarme, str(alarme)), ALARM if alarme else DIM)
        self.b_porta.configure(text="Fechar porta" if not porta else "Abrir porta")

        agora = time.time()
        itens = list(self.s.log)
        for i, l in enumerate(self.linhas):
            if i < len(itens):
                t, escrita, texto = itens[i]
                hora = time.strftime("%H:%M:%S", time.localtime(t))
                l.configure(text=f"{hora}   {'▶' if escrita else '·'} {texto}",
                            fg=AMBER if escrita else (DIM if agora - t < 2 else MUTED))
            else:
                l.configure(text="")
        self.contador.configure(text=f"{self.s.pedidos} pedidos atendidos")

    def _card(self, chave, texto, cor=TEXT):
        valor, _, _ = self.cards[chave]
        valor.configure(text=texto, fg=cor)

    def rodar(self):
        ARQUIVO_COMANDO.unlink(missing_ok=True)
        self.s.iniciar()
        self.root.after(300, self._atualizar)
        self.root.mainloop()
