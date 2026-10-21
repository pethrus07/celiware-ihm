"""Equipamento HTTP falso para testar o Ware IoT sem ESP32 nem gateway.

Imita um ESP32/gateway com API REST: responde JSON com valores que mudam e
aceita comandos por POST, PUT e GET. Python puro (http.server), sem nenhuma
dependência — não precisa do .venv do sim/.

  GET  /api/status          JSON: data.temperatura, data.umidade, data.bomba,
                            data.setpoint, itens[0].valor (peças), producao (lista de 8)
  GET  /api/temperatura     só o número ("25.3"), para o seletor vazio
  GET  /texto               "T=25.3C;U=61%" (texto puro, para a expressão regular)
  POST /api/consulta        corpo {"canal": N} → {"canal": N, "valor": ...}
  POST /api/bomba           corpo {"ligar": 1}, ou só 1/0, true/false, ON/OFF
  PUT  /api/setpoint        corpo 55, ou {"setpoint": 55}
  GET  /api/set?bomba=1     o mesmo pela URL (também ?setpoint=55)

Bomba ligada, a temperatura sobe devagar até o setpoint; desligada, volta a
~25 °C. As peças contam com a bomba ligada.

Uso (Python 3.8+):
  python sim/http_falso.py                          porta 8080, sem senha
  python sim/http_falso.py --porta 8081
  python sim/http_falso.py --usuario admin --senha 1234     exige Basic
  python sim/http_falso.py --token abc123                   exige "Authorization: abc123"
  python sim/http_falso.py --token abc123 --cabecalho X-API-Key
  python sim/http_falso.py --lento 3000             demora 3 s para responder (tempo esgotado)

No emulador do Android o computador é 10.0.2.2: no app, Endereço do
equipamento = http://10.0.2.2:8080. Detalhes em docs/SIMULACAO.md §8.
"""

from __future__ import annotations

import argparse
import base64
import json
import logging
import math
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

log = logging.getLogger("http_falso")


class Maquina:
    """O "loop()" do equipamento: estado, física simples e os comandos."""

    def __init__(self) -> None:
        self.trava = threading.Lock()
        self.temp = 25.0
        self.umidade = 60.0
        self.bomba = True
        self.setpoint = 45
        self.pecas = 0
        self.producao = [0] * 8
        self._ultimo = time.monotonic()
        self._acumulado = 0.0

    def passo(self) -> None:
        agora = time.monotonic()
        dt = agora - self._ultimo
        self._ultimo = agora
        alvo = float(self.setpoint) if self.bomba else 25.0
        self.temp += (alvo - self.temp) * min(1.0, dt / 30) + (random.random() - 0.5) * 0.1
        self.umidade = 60 + 5 * math.sin(agora / 20) + (random.random() - 0.5)
        if self.bomba:
            self._acumulado += dt * 2  # duas peças por segundo
            novas = int(self._acumulado)
            self._acumulado -= novas
            self.pecas += novas
            self.producao[int(agora / 15) % 8] += novas

    def status(self) -> dict:
        with self.trava:
            self.passo()
            return {
                "data": {
                    "temperatura": round(self.temp, 1),
                    "umidade": round(self.umidade),
                    "bomba": self.bomba,
                    "setpoint": self.setpoint,
                },
                "itens": [{"nome": "pecas", "valor": self.pecas}],
                "producao": list(self.producao),
            }

    def ligar(self, valor: object) -> None:
        with self.trava:
            self.bomba = liga(valor)

    def mudar_setpoint(self, valor: object) -> None:
        with self.trava:
            self.setpoint = int(float(str(valor).replace(",", ".")))


def liga(valor: object) -> bool:
    if isinstance(valor, bool):
        return valor
    if isinstance(valor, (int, float)):
        return valor != 0
    texto = str(valor).strip().lower()
    if texto in ("1", "true", "on", "liga", "ligado"):
        return True
    if texto in ("0", "false", "off", "desliga", "desligado"):
        return False
    raise ValueError(f"não é liga/desliga: {valor!r}")


def corpo_valor(texto: str, chave: str) -> object:
    """O valor de um comando: {"chave": v} ou só v."""
    texto = texto.strip()
    try:
        dado = json.loads(texto)
    except ValueError:
        return texto
    if isinstance(dado, dict):
        if chave not in dado:
            raise ValueError(f'faltou "{chave}" no JSON')
        return dado[chave]
    return dado


def fazer_handler(maquina: Maquina, args: argparse.Namespace):
    class Handler(BaseHTTPRequestHandler):
        server_version = "ESP32-falso/1.0"

        def log_message(self, fmt: str, *a) -> None:  # noqa: N802 (nome da biblioteca)
            log.info("%s %s", self.address_string(), fmt % a)

        # ── respostas ────────────────────────────────────────────────────

        def responder(self, codigo: int, corpo: object, tipo: str = "application/json") -> None:
            if args.lento:
                time.sleep(args.lento / 1000)
            dados = (json.dumps(corpo) if tipo == "application/json" else str(corpo)).encode("utf-8")
            self.send_response(codigo)
            self.send_header("Content-Type", f"{tipo}; charset=utf-8")
            self.send_header("Content-Length", str(len(dados)))
            if codigo == 401:
                self.send_header("WWW-Authenticate", 'Basic realm="esp32-falso"')
            self.end_headers()
            self.wfile.write(dados)

        def autorizado(self) -> bool:
            if args.usuario is not None:
                esperado = "Basic " + base64.b64encode(f"{args.usuario}:{args.senha or ''}".encode()).decode()
                if self.headers.get("Authorization") != esperado:
                    self.responder(401, {"erro": "usuário ou senha"})
                    return False
            if args.token is not None and self.headers.get(args.cabecalho) != args.token:
                self.responder(403, {"erro": "token"})
                return False
            return True

        def ler_corpo(self) -> str:
            n = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(n).decode("utf-8", "replace") if n else ""

        # ── rotas ────────────────────────────────────────────────────────

        def do_GET(self) -> None:  # noqa: N802
            if not self.autorizado():
                return
            url = urlparse(self.path)
            st = maquina.status()
            if url.path in ("/", "/api", "/api/"):
                self.responder(200, {"nome": "ESP32 falso", "rotas": ["/api/status", "/api/temperatura", "/texto"]})
            elif url.path == "/api/status":
                self.responder(200, st)
            elif url.path == "/api/temperatura":
                self.responder(200, st["data"]["temperatura"], "text/plain")
            elif url.path == "/texto":
                d = st["data"]
                self.responder(200, f"T={d['temperatura']:.1f}C;U={d['umidade']}%", "text/plain")
            elif url.path == "/api/set":
                q = parse_qs(url.query)
                try:
                    if "bomba" in q:
                        maquina.ligar(q["bomba"][0])
                    if "setpoint" in q:
                        maquina.mudar_setpoint(q["setpoint"][0])
                except ValueError as e:
                    self.responder(400, {"erro": str(e)})
                    return
                self.responder(200, maquina.status()["data"])
            else:
                self.responder(404, {"erro": "caminho não existe"})

        def do_POST(self) -> None:  # noqa: N802
            if not self.autorizado():
                return
            corpo = self.ler_corpo()
            caminho = urlparse(self.path).path
            try:
                if caminho == "/api/bomba":
                    maquina.ligar(corpo_valor(corpo, "ligar"))
                    self.responder(200, {"ok": True, "bomba": maquina.bomba})
                elif caminho == "/api/consulta":
                    canal = int(corpo_valor(corpo, "canal"))
                    self.responder(200, {"canal": canal, "valor": round(maquina.status()["data"]["temperatura"] + canal, 1)})
                else:
                    self.responder(404, {"erro": "caminho não existe"})
            except (ValueError, TypeError) as e:
                self.responder(400, {"erro": str(e)})

        def do_PUT(self) -> None:  # noqa: N802
            if not self.autorizado():
                return
            corpo = self.ler_corpo()
            if urlparse(self.path).path != "/api/setpoint":
                self.responder(404, {"erro": "caminho não existe"})
                return
            try:
                maquina.mudar_setpoint(corpo_valor(corpo, "setpoint"))
            except (ValueError, TypeError) as e:
                self.responder(400, {"erro": str(e)})
                return
            self.responder(200, {"ok": True, "setpoint": maquina.setpoint})

    return Handler


def main() -> None:
    p = argparse.ArgumentParser(description="Equipamento HTTP falso (ESP32 com API REST) para o Ware IoT.")
    p.add_argument("--porta", type=int, default=8080)
    p.add_argument("--usuario", help="exige Basic com este usuário")
    p.add_argument("--senha", help="senha do Basic")
    p.add_argument("--token", help="exige este token no cabeçalho")
    p.add_argument("--cabecalho", default="Authorization", help="cabeçalho do token (padrão Authorization)")
    p.add_argument("--lento", type=int, default=0, help="atraso em ms antes de cada resposta")
    args = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    servidor = ThreadingHTTPServer(("0.0.0.0", args.porta), fazer_handler(Maquina(), args))
    log.info("ESP32 falso em http://0.0.0.0:%d  (no emulador: http://10.0.2.2:%d)", args.porta, args.porta)
    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        servidor.server_close()


if __name__ == "__main__":
    main()
