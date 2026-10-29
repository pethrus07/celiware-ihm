# Arquitetura

Três vistas do sistema, cada uma numa notação padrão.

| Vista | Notação | Responde |
|---|---|---|
| 1. Casos de uso | UML | Quem usa e para quê |
| 2. Processo | BPMN 2.0 | Como o trabalho anda, com uma raia para cada quem executa |
| 3. Arquitetura | C4, nível 2 | De que partes o sistema é feito e com quem conversa |

## Ware IoT · a IHM da máquina no celular

App Flutter para Android, grátis na Play, que transforma o celular na IHM da máquina: o usuário cadastra o equipamento, dá nome às variáveis e monta as telas de operação sem programar. A receita da Celiware vem do hardware da loja.

### 1. Quem usa e para quê

![Casos de uso de Ware IoT](./ware-iot-1-casos-de-uso.svg)

### 2. Da instalação à máquina operando no celular

![Processo de Ware IoT](./ware-iot-2-processo.svg)

### 3. Arquitetura

![Arquitetura de Ware IoT](./ware-iot-3-arquitetura.svg)

Para editar: [ware-iot.excalidraw](./ware-iot.excalidraw), que abre em [excalidraw.com](https://excalidraw.com) ou na extensão Excalidraw do VS Code.

## De onde vêm

Os diagramas são gerados a partir do Sinapse, o vault onde o Pedro organiza notas e projetos. Mudança feita direto aqui some na próxima publicação: o lugar de mudar é a especificação no Sinapse.
