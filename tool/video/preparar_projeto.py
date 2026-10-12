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

# Só as da cortadora ganham cópia na rede: a calculada da demonstração
# (equipamento virtual "calculos") não tem endereço — fica como está.
originais = [t for t in p["tags"] if t["deviceId"] != REDE and not t["id"].startswith("rede_")]
demo_tags = [t for t in originais if t["deviceId"] != "calculos"]
novas = {t["id"]: "rede_" + t["id"] for t in demo_tags}
p["tags"] = originais + [dict(t, id=novas[t["id"]], deviceId=REDE) for t in demo_tags]

def remapear(e):
    # Toda referência a variável, não só tagId/tagIds: o botão Liga tem também
    # feedbackTagId (o retorno de "em ciclo"), que ficava lendo a demonstração
    # interna — a tela da rede mostrava dois "Online" e o botão acendia pela
    # máquina errada.
    e = json.loads(json.dumps(e))
    e["id"] = "rede_" + e["id"]
    for k, v in e.get("props", {}).items():
        if isinstance(v, str) and v in novas:
            e["props"][k] = novas[v]
        elif isinstance(v, list):
            e["props"][k] = [novas.get(x, x) if isinstance(x, str) else x for x in v]
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
