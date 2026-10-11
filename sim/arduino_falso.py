"""Arduino falso para testar o protocolo cru do Ware IoT sem placa.

Imita um sketch comum de Arduino/ESP: manda a temperatura de um tanque e o
estado da bomba numa linha de texto, e aceita comando para a bomba.

  T=<temperatura>;P=<0/1>\\n   a cada --intervalo ms (0 = só quando pedirem)
  ?\\n                         responde a linha na hora (modo polling do app)
  SET P=<0/1>\\n               liga/desliga a bomba e responde a linha nova
  SET T=<número>\\n            força a temperatura (testar alarme)

Bomba ligada: a água esquenta devagar até ~60 °C; desligada, esfria até
~25 °C. Um ruído pequeno faz o gráfico se mexer.

Uso (Python 3.8+, sem nenhuma dependência — não precisa do .venv do sim/):
  python arduino_falso.py                     TCP na porta 5030, uma linha por segundo
  python arduino_falso.py --porta 5031 --intervalo 250
  python arduino_falso.py --intervalo 0       só responde a "?" (polling)
  python arduino_falso.py --udp               UDP: responde e transmite para quem falou por último
  python arduino_falso.py --udp --destino 192.168.0.20:5030
                                              UDP: transmite para o celular desde o início
  python arduino_falso.py --baguncar          TCP: parte mensagens ao meio e manda lixo às vezes

Perfil no app: fim de linha \\n, campos chave=valor (pares com ";", atribuição
com "="), comando "SET {campo}={valor}\\n". Detalhes em docs/SIMULACAO.md.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import random
import re

log = logging.getLogger("arduino_falso")

SET = re.compile(r"^SET\s+(\w+)\s*=\s*(\S+)$", re.IGNORECASE)


class Sketch:
    """O "loop()" do Arduino: estado, física simples e os comandos."""

    def __init__(self) -> None:
        self.temp = 25.0
        self.bomba = 1

    def passo(self, dt: float) -> None:
        alvo = 60.0 if self.bomba else 25.0
        self.temp += (alvo - self.temp) * (dt / 40) + (random.random() - 0.5) * 0.1

    def linha(self) -> bytes:
        return f"T={self.temp:.1f};P={self.bomba}\n".encode("ascii")

    def comando(self, texto: str) -> bytes | None:
        """Resposta ao que chegou, ou None (linha vazia ou desconhecida)."""
        texto = texto.strip()
        if not texto:
            return None
        if texto == "?":
            return self.linha()
        m = SET.match(texto)
        if not m:
            log.info("ignorado: %r", texto)
            return None
        chave, valor = m.group(1).upper(), m.group(2)
        try:
            numero = float(valor.replace(",", "."))
        except ValueError:
            log.warning("valor não numérico: %r", texto)
            return None
        if chave == "P":
            self.bomba = 1 if numero else 0
        elif chave == "T":
            self.temp = numero
        else:
            log.info("campo desconhecido: %r", texto)
            return None
        log.info("comando: %s=%s", chave, valor)
        return self.linha()


async def fisica(sketch: Sketch, dt: float = 0.2) -> None:
    """O processo continua mesmo sem ninguém conectado, como na placa."""
    while True:
        sketch.passo(dt)
        await asyncio.sleep(dt)


# ── TCP ──────────────────────────────────────────────────────────────────────


class ServidorTcp:
    def __init__(self, sketch: Sketch, baguncar: bool) -> None:
        self.sketch = sketch
        self.baguncar = baguncar
        self.clientes: set[asyncio.StreamWriter] = set()

    async def enviar(self, writer: asyncio.StreamWriter, dados: bytes) -> None:
        try:
            if self.baguncar and random.random() < 0.15:
                writer.write(b"\x00\xff\xfe")  # ruído na linha, como o da placa ao ligar
            if self.baguncar and random.random() < 0.3:
                meio = len(dados) // 2  # mensagem partida: o app tem de juntar
                writer.write(dados[:meio])
                await writer.drain()
                await asyncio.sleep(0.05)
                dados = dados[meio:]
            writer.write(dados)
            await writer.drain()
        except (ConnectionError, OSError):
            self.clientes.discard(writer)

    async def atender(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        quem = writer.get_extra_info("peername")
        log.info("app conectado: %s", quem)
        self.clientes.add(writer)
        try:
            while True:
                linha = await reader.readline()
                if not linha:
                    break
                resposta = self.sketch.comando(linha.decode("utf-8", "replace"))
                if resposta:
                    await self.enviar(writer, resposta)
        except (ConnectionError, OSError):
            pass
        finally:
            self.clientes.discard(writer)
            writer.close()
            log.info("app saiu: %s", quem)

    async def transmitir(self) -> None:
        dados = self.sketch.linha()
        for w in list(self.clientes):
            await self.enviar(w, dados)


# ── UDP ──────────────────────────────────────────────────────────────────────


class ServidorUdp(asyncio.DatagramProtocol):
    """Como o WiFiUDP do sketch: responde a quem mandou e passa a transmitir
    para ele. Cada pacote é uma mensagem."""

    def __init__(self, sketch: Sketch, destino: tuple[str, int] | None) -> None:
        self.sketch = sketch
        self.destino = destino
        self.transport: asyncio.DatagramTransport | None = None

    def connection_made(self, transport) -> None:
        self.transport = transport

    def datagram_received(self, data: bytes, addr) -> None:
        if self.destino != addr:
            log.info("app em %s:%s", *addr[:2])
        self.destino = addr
        for linha in data.decode("utf-8", "replace").split("\n"):
            resposta = self.sketch.comando(linha)
            if resposta and self.transport:
                self.transport.sendto(resposta, addr)

    def error_received(self, exc) -> None:
        # ICMP "porta inacessível" (app fechou): continua transmitindo.
        log.debug("UDP: %s", exc)

    async def transmitir(self) -> None:
        if self.destino and self.transport:
            self.transport.sendto(self.sketch.linha(), self.destino)


async def rodar(args) -> None:
    sketch = Sketch()
    tarefas = [asyncio.create_task(fisica(sketch))]
    if args.udp:
        destino = None
        if args.destino:
            ip, _, porta = args.destino.rpartition(":")
            destino = (ip, int(porta))
        loop = asyncio.get_running_loop()
        _, servidor = await loop.create_datagram_endpoint(
            lambda: ServidorUdp(sketch, destino), local_addr=(args.host, args.porta)
        )
        log.info("UDP em %s:%s%s", args.host, args.porta, f" → transmitindo para {args.destino}" if destino else "")
    else:
        servidor = ServidorTcp(sketch, args.baguncar)
        tcp = await asyncio.start_server(servidor.atender, args.host, args.porta)
        tarefas.append(asyncio.create_task(tcp.serve_forever()))
        log.info("TCP em %s:%s%s", args.host, args.porta, " (bagunçando)" if args.baguncar else "")
    if args.intervalo <= 0:
        log.info("Só responde a '?' (polling)")
    try:
        while True:
            if args.intervalo > 0:
                await asyncio.sleep(args.intervalo / 1000)
                await servidor.transmitir()
            else:
                await asyncio.sleep(3600)
    finally:
        for t in tarefas:
            t.cancel()


def main() -> None:
    ap = argparse.ArgumentParser(description="Arduino falso do Ware IoT (protocolo cru)")
    ap.add_argument("--host", default="0.0.0.0", help="0.0.0.0 = aceita conexões da rede")
    ap.add_argument("--porta", type=int, default=5030)
    ap.add_argument("--intervalo", type=int, default=1000, metavar="MS", help="transmite a cada MS ms; 0 = só responde a '?'")
    ap.add_argument("--udp", action="store_true", help="UDP em vez de TCP")
    ap.add_argument("--destino", metavar="IP:PORTA", help="UDP: para onde transmitir antes de o app falar")
    ap.add_argument("--baguncar", action="store_true", help="TCP: parte mensagens ao meio e manda lixo de vez em quando")
    args = ap.parse_args()
    if args.baguncar and args.udp:
        ap.error("--baguncar é só para TCP: em UDP cada pacote já é uma mensagem inteira")

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")
    asyncio.run(rodar(args))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
