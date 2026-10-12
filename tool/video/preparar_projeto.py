"""Monta o projeto do vídeo: a demonstração interna + a mesma cortadora NA REDE.

Parte do projeto de demonstração que o app gerou (puxado do aparelho) e
acrescenta:
  • o equipamento "Cortadora (rede)" em 10.0.2.2:5020 — o PC visto de dentro
    do emulador, onde roda o simulador (sim/simulador.py --painel);
  • uma cópia das variáveis apontando para ele;
  • a tela "Cortadora na rede", enxuta, para caber ao lado do simulador.

Uso: python preparar_projeto.py entrada.json saida.json
"""
import json
import sys

REDE = "rede_cortadora"

entrada, saida = sys.argv[1], sys.argv[2]
p = json.load(open(entrada, encoding="utf-8"))

p["name"] = "Demonstração"
p["devices"] = [d for d in p["devices"] if d["id"] != REDE] + [{
    "id": REDE, "name": "Cortadora (rede)", "kind": "modbusTcp",
    "host": "10.0.2.2", "port": 5020, "unitId": 1, "timeoutMs": 1500, "pollMs": 300,
}]

# Só as da cortadora: a calculada da demonstração (equipamento virtual
# "calculos") não tem endereço para copiar para a rede.
demo_tags = [t for t in p["tags"] if t["deviceId"] not in (REDE, "calculos")]
novas = {t["id"]: "rede_" + t["id"] for t in demo_tags}
p["tags"] = demo_tags + [dict(t, id=novas[t["id"]], deviceId=REDE) for t in demo_tags]

def remapear(e):
    e = json.loads(json.dumps(e))
    e["id"] = "rede_" + e["id"]
    pr = e.get("props", {})
    if "tagId" in pr:
        pr["tagId"] = novas.get(pr["tagId"], pr["tagId"])
    if "tagIds" in pr:
        pr["tagIds"] = [novas.get(x, x) for x in pr["tagIds"]]
    return e

op = next(s for s in p["screens"] if s["id"] == "demo_tela_operacao")
# Só a parte de cima (estado, comando, ajuste, motor, porta): é o que cabe ao
# lado do simulador no quadro dividido.
topo = [remapear(e) for e in op["elements"] if e["y"] < 9]
p["screens"] = [s for s in p["screens"] if s["id"] != "rede_tela"] + [{
    "id": "rede_tela", "name": "Cortadora na rede", "columns": 6,
    "readOnly": False, "confirmWrites": True, "elements": topo,
}]

json.dump(p, open(saida, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(f"{len(p['devices'])} equipamentos · {len(p['tags'])} variáveis · {len(p['screens'])} telas")
