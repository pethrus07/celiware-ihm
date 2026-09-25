"""Simulador Modbus TCP para testar o Celiware IHM sem equipamento.

Sobe um escravo Modbus TCP no PC. O app (no emulador ou no celular) conecta
nele como se fosse um CLP de verdade — mesmo caminho de rede, socket, MBAP.

Cenários:
  cortadora  Cortadora de rótulos com "programa de CLP" rodando: o mesmo mapa
             e o mesmo comportamento da máquina de demonstração interna do app
             (lib/services/demo/demo_process.dart). Ligue pelo app, veja a
             velocidade subir, a produção contar, o motor esquentar e o alarme.
  vazio      Memória zerada (10.000 posições por área). Para mapear endereços,
             treinar ou escrever valores à mão com o Modbus Poll.

Falhas, para testar o comportamento do app com rede ruim:
  --cair-a-cada N   derruba o servidor a cada N segundos por 5 s (cabo solto,
                    Wi-Fi caiu). O app deve esmaecer os valores e reconectar.

Uso (de dentro de sim/, com o ambiente isolado):
  .venv\\Scripts\\python simulador.py --cenario cortadora
  .venv\\Scripts\\python simulador.py --cenario vazio --porta 5021 --id 2
  .venv\\Scripts\\python simulador.py --cenario cortadora --cair-a-cada 30

No app, cadastre um equipamento "Na rede":
  emulador Android  IP 10.0.2.2  (é o PC visto de dentro do emulador)
  celular no Wi-Fi  IP do PC na rede (ipconfig) — libere o Python no firewall
  porta             a do --porta (padrão 5020; 502 exige administrador)

Detalhes em docs/SIMULACAO.md.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import random
import struct

from pymodbus.datastore import (
    ModbusSequentialDataBlock,
    ModbusServerContext,
    ModbusSlaveContext,
)
from pymodbus.server import ServerAsyncStop, StartAsyncTcpServer

log = logging.getLogger("simulador")

# Códigos de função usados por setValues/getValues (área da memória).
COIL, DI, HR, IR = 1, 2, 3, 4

# ── Mapa da cortadora — IGUAL ao DemoMap do app (demo_process.dart) ─────────
COIL_RUN, COIL_RESET, COIL_KNIFE, COIL_IN_CYCLE, COIL_ALARM = 0, 1, 3, 10, 11
DI_DOOR, DI_EMERGENCY, DI_PAPER = 0, 1, 2
HR_STATUS, HR_SETPOINT, HR_SPEED, HR_PRODUCTION = 0, 1, 2, 3  # produção: UINT32 em 3..4
HR_LENGTH, HR_TEMP, HR_TENSION, HR_HOURLY = 5, 6, 8, 10  # temp: FLOAT32 em 6..7; hora: 10..17
HR_ALARM_CODE, HR_STATUS_WORD = 20, 30
IR_UPTIME = 0
TEMP_ALARM, TEMP_RESET = 85.0, 80.0


def build_context(unit_id: int) -> ModbusServerContext:
    """Memória de 10.000 posições por área.

    O ModbusSlaveContext do pymodbus 3.8 soma 1 a todo endereço (pedidos da
    rede E getValues/setValues do programa). Por isso os blocos começam em 1:
    endereço 0 do protocolo = posição 1 do bloco, e o resto do arquivo usa o
    endereço do protocolo, igual ao app.
    """
    slave = ModbusSlaveContext(
        co=ModbusSequentialDataBlock(1, [0] * 10000),
        di=ModbusSequentialDataBlock(1, [0] * 10000),
        hr=ModbusSequentialDataBlock(1, [0] * 10000),
        ir=ModbusSequentialDataBlock(1, [0] * 10000),
    )
    return ModbusServerContext(slaves={unit_id: slave}, single=False)


class Cortadora:
    """O "programa do CLP" — espelho do DemoProcess do app."""

    def __init__(self, ctx: ModbusSlaveContext) -> None:
        self.ctx = ctx
        self.speed = 0.0
        self.temp = 32.0
        self.production = 18240.0
        self.hour_fraction = 0.0
        self.tension = 50.0
        self.uptime = 0.0
        self.ticks = 0

    def get(self, fc: int, addr: int, n: int = 1) -> list:
        return self.ctx.getValues(fc, addr, n)

    def set(self, fc: int, addr: int, values: list) -> None:
        self.ctx.setValues(fc, addr, values)

    def seed(self) -> None:
        self.set(HR, HR_SETPOINT, [80])
        self.set(HR, HR_LENGTH, [120])
        self.set(DI, DI_DOOR, [1, 1, 1])  # porta fechada, emergência ok, papel
        self.set(HR, HR_HOURLY, [random.randint(2300, 2900) for _ in range(7)] + [0])
        self.write_outputs(False, False, True)

    def step(self, dt: float) -> None:
        run = bool(self.get(COIL, COIL_RUN)[0])
        door = bool(self.get(DI, DI_DOOR)[0])
        alarm = self.get(HR, HR_ALARM_CODE)[0]

        if self.get(COIL, COIL_RESET)[0]:  # reset é pulso: o programa consome
            if alarm == 1 and self.temp < TEMP_RESET:
                alarm = 0
            if alarm == 2 and door:
                alarm = 0
            self.set(COIL, COIL_RESET, [0])
        if not door and run:
            alarm = 2

        in_cycle = run and door and alarm == 0
        setpoint = max(0, min(200, self.get(HR, HR_SETPOINT)[0]))
        target = float(setpoint) if in_cycle else 0.0
        ramp = 25.0 * dt
        self.speed += max(-ramp, min(ramp, target - self.speed))
        if abs(self.speed) < 0.05:
            self.speed = 0.0

        length = max(10, min(2000, self.get(HR, HR_LENGTH)[0]))
        cut = self.speed * 1000 / length / 60 * dt
        self.production += cut
        self.hour_fraction += cut
        if self.hour_fraction >= 1:
            whole = int(self.hour_fraction)
            self.hour_fraction -= whole
            last = HR_HOURLY + 7
            self.set(HR, last, [(self.get(HR, last)[0] + whole) & 0xFFFF])

        self.temp += (32 + self.speed * 0.62 - self.temp) * (dt / 45) + (random.random() - 0.5) * 0.08
        if self.temp > TEMP_ALARM:
            alarm = 1
        self.tension += ((62 if in_cycle else 48) - self.tension) * 0.05 + (random.random() - 0.5) * 1.2
        if in_cycle:
            self.uptime += dt
            self.ticks += 1

        self.set(HR, HR_ALARM_CODE, [alarm])
        self.write_outputs(in_cycle, alarm != 0, door)

    def write_outputs(self, in_cycle: bool, alarm: bool, door: bool) -> None:
        prod = int(self.production)
        temp_hi, temp_lo = struct.unpack(">HH", struct.pack(">f", self.temp))
        self.set(HR, HR_STATUS, [2 if alarm else (1 if in_cycle else 0)])
        self.set(HR, HR_SPEED, [int(round(self.speed))])
        self.set(HR, HR_PRODUCTION, [(prod >> 16) & 0xFFFF, prod & 0xFFFF])
        self.set(HR, HR_TEMP, [temp_hi, temp_lo])
        self.set(HR, HR_TENSION, [max(0, min(100, int(round(self.tension))))])
        self.set(HR, HR_STATUS_WORD, [(1 if in_cycle else 0) | (2 if alarm else 0) | (4 if door else 0)])
        self.set(IR, IR_UPTIME, [int(self.uptime // 60)])
        knife = in_cycle and self.speed > 1 and (self.ticks // 2) % 2 == 0
        self.set(COIL, COIL_IN_CYCLE, [int(in_cycle)])
        self.set(COIL, COIL_ALARM, [int(alarm)])
        self.set(COIL, COIL_KNIFE, [int(knife)])


async def run_process(proc: Cortadora, tick: float = 0.2) -> None:
    proc.seed()
    while True:
        proc.step(tick)
        await asyncio.sleep(tick)


async def serve_with_drops(ctx: ModbusServerContext, host: str, port: int, every: int) -> None:
    """Servidor que cai a cada [every] s por 5 s (0 = nunca cai)."""
    while True:
        server = asyncio.create_task(StartAsyncTcpServer(context=ctx, address=(host, port)))
        log.info("Escutando em %s:%s", host, port)
        if every <= 0:
            await server
            return
        await asyncio.sleep(every)
        log.warning("Simulando QUEDA de rede por 5 s")
        await ServerAsyncStop()
        await asyncio.sleep(5)



async def servir_terminal(args, ctx) -> None:
    """Modo terminal: servidor + programa da cortadora no mesmo laço asyncio."""
    tasks = []
    if args.cenario == "cortadora":
        tasks.append(asyncio.create_task(run_process(Cortadora(ctx[args.id]))))
        log.info("Cenário CORTADORA: coil 0 = liga · HR 1 = velocidade desejada · HR 2 = velocidade")
    else:
        log.info("Cenário VAZIO: 10.000 posições zeradas por área")
    await serve_with_drops(ctx, args.host, args.porta, args.cair_a_cada)
    for t in tasks:
        t.cancel()


def main() -> None:
    ap = argparse.ArgumentParser(description="Simulador Modbus TCP do Celiware IHM")
    ap.add_argument("--cenario", choices=["cortadora", "vazio"], default="cortadora")
    ap.add_argument("--host", default="0.0.0.0", help="0.0.0.0 = aceita conexões da rede")
    ap.add_argument("--porta", type=int, default=5020)
    ap.add_argument("--id", type=int, default=1, help="Unit ID do escravo")
    ap.add_argument("--cair-a-cada", type=int, default=0, metavar="N", help="derruba o servidor a cada N s")
    ap.add_argument("--painel", action="store_true", help="abre o painel gráfico (valores ao vivo, pedidos, botões de falha)")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    logging.getLogger("pymodbus").setLevel(logging.WARNING)

    ctx = build_context(args.id)
    if args.painel:
        # Tk na thread principal; servidor e programa da cortadora num laço
        # asyncio próprio, noutra thread (ver painel.Servidor).
        from painel import Painel, Servidor
        proc = Cortadora(ctx[args.id]) if args.cenario == "cortadora" else None
        Painel(Servidor(ctx, args.host, args.porta, proc), args.id, args.cenario).rodar()
    else:
        asyncio.run(servir_terminal(args, ctx))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass