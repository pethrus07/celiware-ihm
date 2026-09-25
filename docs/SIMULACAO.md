# Simulação — testar sem equipamento

Quatro formas de testar o app sem CLP, da mais simples à mais realista.

| Forma | Serve para | Rede de verdade? |
|---|---|---|
| Máquina de demonstração (dentro do app) | Mostrar o app, testar telas, gravar vídeo. | Não — a memória mora no celular. |
| Simulador Python (`sim/simulador.py`) | Testar o caminho real: socket, MBAP, queda de rede, Wi-Fi. | Sim. |
| Modbus Slave / ModbusTool (programas no PC) | Mexer em valores à mão, imitar um mapa de memória qualquer. | Sim. |
| Escravo Dart (`ModbusTcpServer`) | Testes automatizados (`flutter test`). | Sim, local. |

## 1. Máquina de demonstração

Já vem no app: equipamento "Cortadora de rótulos", tipo **Demonstração**. Tem um "programa de CLP" rodando (`lib/services/demo/demo_process.dart`): ligar faz a velocidade subir em rampa até o setpoint, a produção contar conforme o comprimento do rótulo, o motor esquentar; acima de 85 °C dispara o alarme de sobretemperatura e a máquina para; o reset só limpa depois que esfria abaixo de 80 °C.

Para recomeçar do zero: Mais → Restaurar a demonstração.

## 2. Simulador Python (rede de verdade)

### 2.1. Preparar (uma vez)

```
cd sim
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
```

O `requirements.txt` trava o pymodbus em 3.8.6: da 3.9 em diante a API de memória está sendo trocada e o simulador quebraria.

### 2.2. Rodar

```
.venv\Scripts\python simulador.py --cenario cortadora
.venv\Scripts\python simulador.py --cenario vazio --porta 5021 --id 2
.venv\Scripts\python simulador.py --cenario cortadora --cair-a-cada 30
```

| Opção | Efeito |
|---|---|
| `--cenario cortadora` | Mesmo mapa e comportamento da demonstração interna (tabela abaixo). |
| `--cenario vazio` | 10.000 posições zeradas por área, para mapear ou escrever à mão. |
| `--porta N` | Porta TCP (padrão 5020; a 502 exige administrador no Windows). |
| `--id N` | Unit ID do escravo (padrão 1). |
| `--cair-a-cada N` | Derruba o servidor a cada N segundos por 5 s — o app deve esmaecer os valores e reconectar sozinho. |
| `--painel` | Abre a janela do simulador (abaixo) em vez de rodar só no terminal. |

### 2.2.1. Painel visual (`--painel`)

```
.venv\Scripts\python simulador.py --painel
```

Uma janela "Simulador Modbus TCP — Celiware IHM" mostra, ao vivo, o que o CLP simulado tem na memória e o que o app está pedindo:

| Parte | O que mostra |
|---|---|
| Cabeçalho | Porta e ID em escuta; selo **app conectado** quando há cliente; contador de pedidos atendidos. |
| 8 cartões | Liga máquina, status, velocidade, ajuste, produção, motor, porta e alarme — cada um com a área e o endereço (`COIL 0`, `HR 6..7`…), para conferir o cadastro das variáveis. |
| Botões | **Abrir/Fechar porta** (a máquina para e acusa alarme), **Superaquecer motor** e **Derrubar rede (6 s)** (fecha o servidor e sobe de novo). |
| Pedidos do app | Log de cada pedido Modbus recebido — mostra o agrupamento: variáveis vizinhas saem num pedido só (`HR 0..20`). |

Os mesmos três botões podem ser acionados por script: grave `porta`, `superaquecer` ou `cair` no arquivo `sim/.comando` (o painel lê e apaga). É assim que o vídeo de apresentação aciona as falhas no tempo certo.

### 2.3. Ligar o app no simulador

Cadastre um equipamento **Na rede**:

| Onde está o app | IP | Porta |
|---|---|---|
| Emulador Android no mesmo PC | `10.0.2.2` (é o PC visto de dentro do emulador) | a do `--porta` |
| Celular no mesmo Wi-Fi do PC | IP do PC na rede (`ipconfig`, "Endereço IPv4") | a do `--porta` |

No celular, o Windows pergunta se libera o Python no firewall na primeira conexão — libere para rede privada. Use **Testar conexão** no cadastro; depois crie variáveis com o painel "Lendo agora" conferindo cada endereço.

### 2.4. Mapa da cortadora

| Área | Endereço | Variável | Tipo |
|---|---|---|---|
| Coil | 0 | Liga máquina (comando) | liga/desliga, grava |
| Coil | 1 | Reset de alarme (pulso) | liga/desliga, grava |
| Coil | 3 | Faca acionada | liga/desliga |
| Coil | 10 | Em ciclo | liga/desliga |
| Coil | 11 | Alarme ativo | liga/desliga |
| Entrada discreta | 0 | Porta fechada | liga/desliga |
| Entrada discreta | 2 | Papel presente | liga/desliga |
| Holding | 0 | Status (0 parada · 1 em ciclo · 2 alarme) | UINT16 |
| Holding | 1 | Velocidade desejada (m/min) | UINT16, grava |
| Holding | 2 | Velocidade (m/min) | UINT16 |
| Holding | 3–4 | Rótulos cortados | UINT32 ABCD |
| Holding | 5 | Comprimento do rótulo (mm) | UINT16, grava |
| Holding | 6–7 | Temperatura do motor (°C) | FLOAT32 ABCD |
| Holding | 8 | Tensão do papel (%) | UINT16 |
| Holding | 10–17 | Produção por hora (8 valores) | UINT16, lista |
| Holding | 20 | Código do alarme (0 · 1 sobretemperatura · 2 porta) | UINT16 |
| Holding | 30 | Palavra de status: bit 0 em ciclo · bit 1 alarme · bit 2 porta | bits |
| Input | 0 | Minutos em ciclo | UINT16 |

## 3. Modbus Slave, Modbus Poll e ModbusTool

Instalados no PC (winget). **Modbus Slave** faz o papel de CLP: crie uma janela de holding registers, digite valores e veja o app ler. **Modbus Poll** faz o papel de mestre: útil para conferir o simulador Python sem o app. São da Witte Software, pagos; sem licença rodam em avaliação. O **ModbusTool** (ClassicDIY) é livre e faz os dois papéis.

## 4. Testar no celular sem cabo (depuração por Wi-Fi)

Android 11 ou mais novo, celular e PC no mesmo Wi-Fi:

1. No celular: Configurações → Sobre o telefone → toque 7× em "Número da versão" (liga as opções do desenvolvedor).
2. Opções do desenvolvedor → **Depuração por Wi-Fi** → ligar → "Parear dispositivo com código de pareamento". Aparecem um IP:porta e um código de 6 dígitos.
3. No PC: `adb pair IP:PORTA` e digite o código. Depois `adb connect IP:PORTA_DA_TELA_PRINCIPAL` (a porta mostrada na tela da Depuração por Wi-Fi, que é diferente da de pareamento).
4. `flutter devices` mostra o celular; `flutter run` instala.

## 5. Testes automatizados

`flutter test` sobe o escravo Dart (`lib/core/modbus/modbus_tcp_server.dart`) numa porta local e testa o cliente TCP de produção por socket de verdade — sem Python, em qualquer máquina. Ganchos: `responseDelay` (provoca timeout), `dropNextRequests` (ignora pedidos) e `closeAllClients` (derruba a conexão).

## 6. Vídeo de apresentação (gerado)

`tool/video/apresentacao.py` grava o app no emulador e o painel do simulador, narra com voz sintética e monta um vídeo 1920×1080 de ~2 min 40 s com 10 cenas. Nada é editado à mão: mudou o app, gera de novo.

**Precisa:** emulador `IHM_Pixel` ligado com o app instalado; ffmpeg e edge-tts no PC; `tool/video/.trabalho/projeto-base.json` (o projeto de demonstração puxado do aparelho). O script monta o projeto do vídeo com `preparar_projeto.py` (acrescenta a "Cortadora (rede)" em `10.0.2.2:5020` e a tela "Cortadora na rede"), envia ao app, liga os toques visíveis e abre o painel.

```
python tool/video/apresentacao.py ensaio   # só roda as ações e tira fotos de conferência
python tool/video/apresentacao.py          # grava, narra e monta
```

Saída em `tool/video/saida/` (fora do git): o `.mp4` e um `.txt` de capítulos. A narração dita a duração de cada cena.

Armadilhas já resolvidas no script:

- **Captura do painel com DPI alto.** O `gdigrab` por título não conhece a escala do Windows (250% neste notebook) e gravava a janela miúda num canto. A captura é pela área da tela (`ddagrab`), com o retângulo medido em pixels físicos e cortado na área útil do monitor (senão entra a barra de tarefas).
- **Coordenadas de toque** são do Pixel 7 (1080×2400) e medidas nas fotos do ensaio; mudou layout, rode `ensaio` antes.
- **Teclado numérico** fecha com a tecla voltar (`keyevent 4`), não com ESC.
- **Capítulos** arredondam antes de dividir (119,6 s virava "01:00").
