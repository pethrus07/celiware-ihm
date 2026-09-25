# Celiware IHM — Documentação Técnica

IHM portátil Modbus TCP · Flutter / Dart · Versão 1.0

## 1. Visão geral

O Celiware IHM transforma o celular numa **IHM (interface homem-máquina) montada pelo próprio usuário**. A pessoa cadastra o equipamento (CLP, inversor, IHM, conversor) pelo IP, dá nome às memórias que interessam (as **variáveis**) e monta **telas** arrastando elementos gráficos — botões, lâmpadas, mostradores, gráficos — ligados a essas variáveis. A tela fica salva no aparelho e pode ser exportada como arquivo para outro celular.

O app nasce **genérico**: fala Modbus TCP com qualquer equipamento. Perfis de fabricante (começando pela Inovance) entram depois, sem mudar o resto do sistema, porque entre marcas o protocolo é o mesmo — muda só onde cada área de memória começa.

### 1.1. Para quem e para quê

| Quem | O que faz com o app |
|---|---|
| Integrador / programador de CLP | Deixa o mapa de memória pronto no CLP, monta as telas no celular e entrega o arquivo do projeto ao cliente. |
| Dono ou líder de produção | Importa o projeto e acompanha as máquinas no celular; monta uma "tela de líder" com 1–2 dados de cada máquina. |
| Operador | Opera a máquina pela tela montada: liga, desliga, ajusta parâmetros. |
| Máquina sem IHM | Ganha uma IHM sem comprar hardware: basta o CLP falar Modbus TCP na rede. |

### 1.2. Escopo da versão 1.0

Combinado na reunião de 24/09/2026 (Pedro × cliente):

- IHM personalizada no celular, sobre Modbus TCP;
- variáveis intermediárias: elementos de tela apontam para variáveis, nunca para endereço cru;
- telas nomeadas, salvas no aparelho, com elementos de vários equipamentos na mesma tela;
- um tema visual só; os elementos variam por função;
- genérico primeiro; perfis de fabricante depois;
- entrega em etapas: (1) refatoração + UX/UI, (2) funcionalidade nova + testes, (3) Play Store — separada, por ter prazo imprevisível.

Fora da versão 1.0, registrado como ideia: conversões/script de variável calculada, backup e comparação de parâmetros de inversor, conversores RS-485/CANopen, Siemens, licenciamento.

### 1.3. Princípios que guiaram o projeto

- **Fácil e visual antes de tudo.** Escolhas em cartões, valor lido ao vivo enquanto se configura, tutorial em cada tela, nenhum jargão sem tradução.
- **Menos à vista, mais respiro.** Cada tela mostra só o que a maioria usa; o resto fica em "Mais opções", já com o resumo do que está configurado. Espaçamento generoso e sem bordas decorativas — a separação vem do tom do fundo.
- **Nada de "Salvar".** Toda edição é gravada na hora. Quem monta tela no chão de fábrica não pode perder trabalho.
- **Só se lê o que está na tela.** A varredura de um equipamento inclui apenas as variáveis dos elementos abertos agora — menos tráfego na rede da fábrica, menos bateria.
- **Segurança ao escrever.** Confirmação antes de gravar, tela "só acompanhamento", limites no ajuste de valor, botão de pulso que nunca fica preso.
- **Estado real, não imaginado.** O botão acende quando o equipamento confirma que ligou; na queda de comunicação a tela mostra o último valor esmaecido, nunca um zero falso.
- **Erro com nome.** "Endereço inexistente", "sem resposta", "sem conexão" são coisas diferentes e aparecem diferentes.

### 1.4. Pilha tecnológica

| Camada | Tecnologia |
|---|---|
| Linguagem / framework | Dart 3.13 e Flutter 3.47 (Material 3, tema escuro próprio). |
| Comunicação industrial | Modbus TCP/IP sobre socket TCP cru, sem biblioteca Modbus externa. |
| Persistência | JSON num arquivo na pasta privada do app (`path_provider`). |
| Arquivos | Exportar/importar projeto e escolher imagem (`file_picker`). |
| Marcas por aparelho | "Tutorial já visto" (`shared_preferences`). |
| Logs | `logging`. |
| Estado | `ValueNotifier` / `ChangeNotifier` / `InheritedNotifier` — sem biblioteca de estado. |
| Simulação | Simulador interno em Dart + simulador externo em Python (pymodbus 3.8.6). |

## 2. Arquitetura

### 2.1. Camadas

| Camada | Pasta | Responsabilidade |
|---|---|---|
| Aplicação | `lib/app` | Controlador do projeto, injeção de dependência, dados fixos do app. |
| Núcleo | `lib/core` | Pilha Modbus, tema visual, utilitários. Não conhece telas nem projeto. |
| Modelos | `lib/models` | Tipos imutáveis: equipamento, variável, tela, projeto. Não conhecem rede nem disco. |
| Serviços | `lib/services` | Motor de execução (varredura, codec, escrita), demonstração, armazenamento. |
| Telas | `lib/screens` | Páginas do app. Dependem de modelos e serviços, nunca da pilha Modbus direto. |
| Widgets | `lib/widgets` | Elementos de IHM, tutorial, componentes comuns. |

### 2.2. Fluxo de dados ponta a ponta

Leitura:

```
CLP ──Modbus TCP──> ModbusClientTcp ──> DeviceSession (varredura agrupada)
    ──> TagCodec (registradores → valor) ──> TagStore (um ValueNotifier por variável)
    ──> TagBuilder ──> elemento da tela (só ele redesenha)
```

Escrita:

```
toque no elemento ──> WriteActions (só leitura? confirmação?) ──> HmiRuntime.write
    ──> DeviceSession.write ──> TagCodec (valor → registradores) ──> ModbusClientTcp ──> CLP
    ──> a sessão acorda e relê: o elemento mostra o valor confirmado pelo equipamento
```

### 2.3. As três peças centrais

- **ProjectController** (`lib/app/project_controller.dart`) — dono do projeto aberto. Toda edição passa por ele: troca o `Project` imutável, avisa as telas, repassa ao runtime e grava no disco (com 400 ms de atraso para juntar várias edições seguidas numa gravação).
- **HmiRuntime** (`lib/services/runtime/hmi_runtime.dart`) — dono das conexões e das leituras. As telas pedem para acompanhar variáveis (`subscribe`), observam valores (`watch`) e pedem escritas (`write`, `press`/`release`). Mantém uma `DeviceSession` por equipamento em uso.
- **AppScope** (`lib/app/app_scope.dart`) — injeção de dependência pela árvore de widgets. Qualquer tela obtém controlador e runtime com `AppScope.of(context)`; `AppScope.watch(context)` reconstrói a tela quando o projeto muda. Por ser por árvore (e não estático global), os testes de widget montam o app com runtime e pasta de teste próprios.

### 2.4. Ciclo de vida

Quando o app vai para segundo plano, `main.dart` solta todos os botões de pulso, para a varredura (rede e bateria) e grava o que estiver pendente. Ao voltar, a varredura religa com as mesmas inscrições.

## 3. Estrutura de pastas

```
lib/
├── main.dart                         Entrada: monta runtime + controlador; ciclo de vida.
├── app/
│   ├── app_info.dart                 Nome, versão, link de vídeos.
│   ├── app_scope.dart                Injeção de dependência (InheritedNotifier).
│   └── project_controller.dart       Edições do projeto + gravação automática.
├── core/
│   ├── modbus/
│   │   ├── modbus_pdu.dart           Montagem/leitura de PDUs (funções puras) e limites.
│   │   ├── modbus_exception.dart     Erros tipados, com mensagem para o operador.
│   │   ├── modbus_client.dart        Cliente base: fn01…fn16 implementadas uma vez.
│   │   ├── modbus_client_tcp.dart    Transporte TCP (MBAP, um pedido por vez, reconexão).
│   │   ├── modbus_client_simulated.dart  Transporte para a máquina de demonstração.
│   │   ├── modbus_memory.dart        Memória Modbus em RAM + lógica de escravo.
│   │   └── modbus_tcp_server.dart    Escravo TCP em Dart (testes de integração).
│   ├── theme/app_theme.dart          Tokens de cor, tipografia, tema Material.
│   └── utils/                        ids, validação de IP, redução de imagem.
├── models/
│   ├── device.dart                   Equipamento.
│   ├── tag.dart                      Variável (tipo, área, endereço, ordem de bytes).
│   ├── hmi_screen.dart               Tela e elemento posicionado na grade.
│   └── project.dart                  Projeto inteiro (unidade de arquivo).
├── services/
│   ├── runtime/
│   │   ├── hmi_runtime.dart          Motor: inscrições, sessões, escrita, teste de conexão.
│   │   ├── device_session.dart       Varredura de um equipamento, falhas, reconexão.
│   │   ├── scan_planner.dart         Agrupa variáveis vizinhas em leituras únicas.
│   │   ├── tag_codec.dart            Registradores ⇄ valor; formatação pt-BR.
│   │   └── tag_store.dart            Última leitura por variável + histórico curto.
│   ├── demo/
│   │   ├── demo_process.dart         "Programa do CLP" da cortadora simulada.
│   │   └── demo_project.dart         Projeto de demonstração (duas telas).
│   └── storage/project_repository.dart   Arquivo do projeto, gravação atômica, formato.
├── screens/
│   ├── shell.dart                    Barra inferior (4 abas).
│   ├── screens_page.dart             Lista de telas com planta em miniatura.
│   ├── screen_run_page.dart          Tela em operação.
│   ├── editor/                       Editor, paleta, configuração de elemento.
│   ├── devices/                      Lista e cadastro de equipamento (Testar conexão).
│   ├── tags/                         Lista e cadastro de variável (Lendo agora).
│   ├── more_page.dart                Projeto, tutoriais, sobre.
│   └── tours.dart                    Textos de todas as trilhas de tutorial.
└── widgets/
    ├── hmi/
    │   ├── element_catalog.dart      Ficha de cada tipo de elemento + chaves de props.
    │   ├── hmi_canvas.dart           Grade da tela: operação e edição.
    │   ├── hmi_frame.dart            Moldura comum + estados de problema.
    │   ├── live_tags.dart            "Estas variáveis ao vivo enquanto eu estiver na tela."
    │   ├── write_actions.dart        Regras de escrita + teclado numérico grande.
    │   └── elements/                 Renderizadores (controle, indicador, gráfico, estático).
    ├── tour/tour.dart                Motor de tutorial (realce, balão, "já vi").
    └── common/common.dart            Estado vazio, selo de conexão, cartões de escolha...

sim/            Simulador Modbus TCP externo (Python) — ver SIMULACAO.md.
test/           Testes: protocolo, TCP real, codec, planejador, runtime, fluxos de tela.
tool/           Gerador de ícone e da documentação em Word.
store/          Material da Play Store (ícone 512).
```

## 4. Comunicação Modbus

### 4.1. De onde vem o código

A "raiz de toda comunicação Modbus" é a classe `ModbusClientTcp` escrita pelo cliente no InoRobot (repositório `jotaerre-ia/InoRobot`, jan/2026). Ela foi reorganizada no `machine_monitor` e evoluiu aqui. Os nomes das funções foram mantidos (`fn01ReadCoils`, `fn03ReadHoldingRegisters`, `fn06WriteSingleRegister`…) para quem já conhece aquela classe. As mudanças estão na seção 12.

### 4.2. Transporte: MBAP e um pedido por vez

Cada PDU vai embrulhada no cabeçalho MBAP de 7 bytes:

| Campo | Bytes | Função |
|---|---|---|
| Transaction ID | 2 | Numera a transação; a resposta repete o número. |
| Protocol ID | 2 | Sempre 0. |
| Length | 2 | Bytes que seguem (Unit ID + PDU). |
| Unit ID | 1 | Endereço do escravo (1 na maioria; em conversor RS-485→TCP, o equipamento da linha). |
| PDU | variável | Código da função + dados. |

O cliente envia **um pedido por vez**: o próximo só sai quando o anterior respondeu ou estourou o tempo-limite. A norma permite pedidos simultâneos, mas muitos CLPs de entrada e conversores descartam ou embaralham. O custo de latência é compensado pelo agrupamento de leituras (4.6). Cabeçalho impossível (protocolo ≠ 0, tamanho absurdo) descarta o buffer; resposta atrasada de um pedido que já estourou o tempo é descartada pelo Transaction ID.

### 4.3. Funções e limites

| Código | Função | Uso |
|---|---|---|
| 01 / 02 | Ler coils / entradas discretas | Variáveis liga/desliga. |
| 03 / 04 | Ler holding / input registers | Números, listas, bits de registrador. |
| 05 / 06 | Escrever 1 coil / 1 registrador | Botões, ajuste de valor 16 bits. |
| 15 / 16 | Escrever vários coils / registradores | Valores de 32 bits (FC16). |

Limites verificados antes de ir à rede: 2000 bits e 125 registradores por leitura; 1968 bits e 123 registradores por escrita; endereços de 0 a 65535.

### 4.4. Erros tipados

A versão anterior devolvia lista vazia em qualquer falha. Agora cada falha é uma exceção com mensagem para o operador:

| Exceção | Quando | Na tela |
|---|---|---|
| `ModbusExceptionResponse` | O equipamento respondeu recusando (bit 0x80). Código 0x02 = endereço inexistente. | Borda vermelha + motivo no elemento. |
| `ModbusTimeout` | Sem resposta no tempo-limite. | Valor esmaecido + ícone de sem conexão. |
| `ModbusConnectionError` | Socket não abre ou caiu. | Idem, e o selo do equipamento fica vermelho. |
| `ModbusProtocolError` | Resposta não bate com o pedido. | Resposta inválida do equipamento. |
| `ModbusRequestError` | Pedido fora dos limites do protocolo. | Erro de configuração na variável. |

### 4.5. Ordem de bytes

A norma só define a ordem dentro de um registrador (big-endian). Para 32 bits cada fabricante escolhe. A ordem é propriedade **de cada variável** (no mesmo equipamento, um INT16 e um FLOAT32 podem precisar de ordens diferentes). Com os bytes do valor numerados A (mais significativo) a D:

| Ordem | Registrador 1 | Registrador 2 | Observação |
|---|---|---|---|
| ABCD | A B | C D | Padrão big-endian. |
| CDAB | C D | A B | Muito comum em CLP (word swap). |
| BADC | B A | D C | Bytes trocados. |
| DCBA | D C | B A | Little-endian completo. |

Toda a lógica mora em `TagCodec` e é coberta por teste com o valor 0x11223344 nas quatro ordens.

### 4.6. Endereçamento e a notação de manual

O app usa o endereço do protocolo, **base 0**. Manuais costumam usar a notação clássica com prefixo da área e base 1: "40001" = holding register 0, "30001" = input register 0, "10001" = entrada discreta 0. O cadastro de variável reconhece esse formato e sugere a conversão com um toque ("Parece a notação de manual: 40003 é o endereço 2"). Perfis de fabricante ("M100", "D200") entram aqui no futuro, como tradução nome → endereço.

### 4.7. Agrupamento de leituras

O `ScanPlanner` recebe as variáveis em uso de um equipamento e devolve o menor número de leituras possível: variáveis da mesma área com endereços próximos viram um pedido, mesmo com um buraco pequeno entre elas (até 8 registradores ou 32 bits), sem passar dos limites do protocolo. É o "não refazer requisição para o mesmo número" da reunião, levado ao nível do protocolo: 20 variáveis vizinhas = 1 pedido.

### 4.8. Endereço errado não apaga a tela

Se um bloco agrupado recebe "endereço inexistente", as variáveis daquele bloco passam a ser lidas uma a uma no ciclo seguinte. Só a variável errada fica marcada; as outras continuam normais. Quando o usuário corrige o endereço, ela volta ao agrupamento.

### 4.9. Queda e reconexão

Sem resposta ou sem conexão, todas as variáveis do equipamento ficam "comunicação perdida" mantendo o último valor, e a sessão tenta de novo com espera crescente — 1, 2, 4, 8, 10 segundos — para não martelar uma rede que caiu. O próximo pedido reabre o socket sozinho. Desconexão pedida (sair da tela) não reconecta.

### 4.10. Escrita

| Variável | Como grava |
|---|---|
| Coil | FC05. |
| Registrador 16 bits | Codec → FC06. |
| Registrador 32 bits / float | Codec → FC16 (dois registradores). |
| Bit dentro de registrador | Leitura-modificação-escrita: FC03 lê a palavra, o codec muda o bit, FC06 grava. |

Cuidado com bit dentro de registrador: se o programa do CLP mudar outro bit da mesma palavra entre a leitura e a escrita, essa mudança se perde. Para comando crítico, prefira coil.

### 4.11. Botão de pulso

`press` grava 1 e `release` grava 0. Se a soltura falhar (rede caiu com o dedo no botão), a variável entra numa fila e o runtime tenta gravar 0 a cada segundo até conseguir. Todos os botões são soltos ao fechar a tela, quando o elemento sai da árvore e quando o app vai para segundo plano. Pulso não pede confirmação: "tem certeza?" quebraria o gesto de segurar.

## 5. Modelo de dados

### 5.1. Equipamento (`Device`)

| Campo | Significado |
|---|---|
| kind | `modbusTcp` (rede) ou `demo` (máquina simulada no aparelho). |
| host, port, unitId | IP ou nome, porta (502), ID do escravo (1). |
| timeoutMs | Tempo máximo por resposta (1500 ms). |
| pollMs | Intervalo entre varreduras (500 ms). |

### 5.2. Variável (`Tag`)

| Campo | Significado |
|---|---|
| area | coil, discreteInput, holdingRegister, inputRegister. |
| address | Endereço base 0. |
| dataType | bool, uint16, int16, uint32, int32, float32. |
| byteOrder | abcd, cdab, badc, dcba. |
| bitIndex | Para liga/desliga dentro de registrador: bit 0 a 15. |
| length | Quantos valores seguidos. Maior que 1 = lista ("memória inicial + tamanho"). |
| writable | Pode ser alterada pela tela (nunca em área só-leitura). |
| unit, decimals | Apresentação: "°C", 1 casa decimal. |

`Tag.normalized()` corrige combinações impossíveis vindas de edição ou de arquivo antigo (área de bit força liga/desliga; área só-leitura tira a escrita).

### 5.3. Tela e elemento

A tela é uma grade de **6 colunas de células quadradas**; a célula mede largura ÷ colunas, então a mesma tela fica proporcional em celular e tablet. Num aparelho de 390 dp a célula tem ~60 dp, acima do mínimo de toque de 48 dp. Cada elemento tem posição e tamanho em células e um mapa `props` com a configuração do tipo.

| Tipo | Propriedades |
|---|---|
| button | tagId, label, mode (toggle · momentary · set · reset · value), value, color |
| lamp | tagId, label, onText, offText, color |
| value | tagId, label |
| input | tagId, label, min, max |
| multistate | tagId, label, states: lista de {value, text, color} |
| bar | tagId, label, min, max, color |
| gauge | tagId, label, min, max, warn, alarm |
| trend | tagIds (até 3), label, windowSec, min, max (vazios = escala automática) |
| barChart | tagId (variável lista), label |
| label | text, size (s · m · l), align (left · center) |
| image | data (PNG em base64, reduzido a 900 px), fit (contain · cover) |

`color` é o nome de uma cor de estado (green, red, amber, blue, neutral). Tipos e chaves desconhecidos — arquivo de uma versão mais nova — são preservados ao salvar, nunca apagados.

### 5.4. Arquivo do projeto

O projeto inteiro é um JSON (`projeto.ihm.json` na pasta privada; `nome-data.ihm.json` ao exportar). O mesmo formato serve para os dois casos.

```
{
  "format": "celiware-ihm",
  "schemaVersion": 1,
  "name": "Demonstração",
  "devices": [ { "id": "...", "name": "...", "kind": "modbusTcp", "host": "192.168.0.10", ... } ],
  "tags":    [ { "id": "...", "deviceId": "...", "area": "holdingRegister", "address": 2, ... } ],
  "screens": [ { "id": "...", "name": "...", "columns": 6, "elements": [ ... ] } ]
}
```

A gravação é atômica (grava `.tmp` e renomeia): se a bateria acabar no meio, sobra o arquivo anterior inteiro. Arquivo ilegível é guardado como cópia `.corrompido-…` em vez de apagado. Arquivo de versão mais nova é recusado com mensagem pedindo para atualizar o app.

## 6. Funcionalidades por tela

### 6.1. Telas (início)

Cartões com a planta da tela em miniatura (um bloco por elemento, com o ícone do tipo), o nome e uma linha discreta: número de elementos e um olho quando a tela é só de acompanhamento. Menu: editar, renomear, duplicar, apagar. Botão "Nova tela" pede o nome e abre o editor.

![Lista de telas](imagens/telas.png)
![Tutorial de primeiros passos](imagens/tutorial.png)

### 6.2. Tela em operação

Os elementos com valores ao vivo; faixa com o selo de cada equipamento (Online · tempo da varredura, ou o motivo da falha). Elementos de uma linha só mostram o rótulo ao lado do valor; os maiores, em cima. Lápis abre o editor. Ao sair, a leitura daqueles equipamentos para e os botões de pulso são soltos.

![Tela em operação, máquina em ciclo](imagens/operacao.png)
![Tendência e produção por hora](imagens/graficos.png)

### 6.3. Editor

Grade pontilhada; "+ Elemento" abre a paleta (ícone, nome e uma frase curta). O elemento entra no primeiro espaço livre — ou na célula vazia tocada antes — e a configuração abre sozinha. Tocar seleciona (borda âmbar); arrastar o selecionado move; a bolinha do canto redimensiona; tudo encaixa na grade e nada sobrepõe. Barra inferior: sem seleção, "+ Elemento" e as regras da tela (nome, só acompanhamento, confirmar antes de gravar, apagar); com seleção, Configurar, Duplicar, Tirar e +. O topo fica só com nome, ajuda e Concluir. Os valores aparecem ao vivo durante a edição, mas nada reage a toque.

### 6.4. Configuração de elemento

Prévia ao vivo no topo, na proporção real. A variável aparece numa linha só; tocar abre uma folha com as variáveis compatíveis (cada uma com o valor atual) e "Criar variável" sem sair do editor. Campos só do que faz sentido para o tipo (modo do botão, cores de estado, limites, estados do indicador, janela do gráfico, texto, imagem). Aviso quando a variável escolhida é só leitura num elemento que grava.

![Editor com elemento selecionado](imagens/editor.png)
![Configuração do elemento](imagens/configurar-elemento.png)

### 6.5. Equipamentos

Lista com nome, endereço e selo de comunicação. Cadastro com quatro coisas à vista: onde está (rede ou demonstração), nome, IP e **Testar conexão**. Porta, ID, tempo-limite e ritmo ficam em "Mais opções" (o resumo "Porta 502 · ID 1" aparece fechado). O teste responde na hora; quando falha, mostra o que conferir, na ordem em que os problemas costumam acontecer (mesmo Wi-Fi, IP, Modbus ligado no equipamento, porta/ID).

### 6.6. Variáveis

Lista agrupada por equipamento: nome, endereço e o valor ao vivo. O cadastro cabe numa tela: equipamento (só aparece se houver mais de um), nome, o que é (liga/desliga, número inteiro, número com vírgula), onde fica (lê e grava / só leitura), endereço com − / + e "pode ser alterada pela tela". Unidade, decimais, lista, formatos raros (INT16, 32 bits), ordem de bytes e observação ficam em "Mais opções", que abre sozinho quando algum deles está em uso. No topo, **Lendo agora do equipamento**: o endereço digitado é lido a cada segundo, pela mesma conexão da varredura.

![Endereço inexistente + notação de manual](imagens/notacao-manual.png)
![Endereço corrigido, lendo ao vivo](imagens/variavel-lendo-agora.png)
![Testar conexão: o que conferir](imagens/testar-conexao.png)

### 6.7. Mais

Projeto: renomear, exportar, importar, restaurar a demonstração, começar do zero. Tutoriais: cada trilha com o botão de reproduzir, e "Rever todos". Vídeos: aparecem quando houver link (vídeo não mora dentro do app). Sobre e licenças.

## 7. Tutoriais dentro do app

Método do onboarding da Retífica (`sinapse/07-FONTES/onboarding-dentro-do-sistema.md`), portado para Flutter em `lib/widgets/tour/tour.dart`, com os textos centralizados em `lib/screens/tours.dart`.

| Regra da Retífica | Como ficou aqui |
|---|---|
| Realce sem biblioteca | Camada escura com recorte (Path evenOdd) no retângulo do alvo + contorno âmbar. |
| Passo essencial não depende de dado na tela | `essential: true` aparece centralizado sem alvo; não essencial sem alvo é pulado. |
| Overlay não pode sobreviver e travar o app | O tour vive dentro da página (`TourHost`) e morre com ela; nenhuma camada global. |
| Rearme por versão na chave | `tour:v{versão}:{id}` no `shared_preferences`; subir a versão reapresenta a trilha. |
| Ajuda sempre no topo | "?" no topo de toda página; a barra inferior tem só 4 abas. |
| Testes dispensam o tour | Os testes de widget marcam as trilhas como vistas antes de montar o app. |

Trilhas: primeiros passos, operar uma tela, montar uma tela, cadastrar equipamento, criar variável. Cada uma aparece sozinha na primeira visita da página e pelo "?" a qualquer momento. O balão se posiciona onde cabe (abaixo, acima ou sobre o rodapé) e nunca sob a barra de status; o passo de lista realça o primeiro item, não a lista inteira.

## 8. Identidade visual

"Pegada industrial", seguindo a filosofia da ISA-101 (IHM de alto desempenho): **fundo neutro, cor só quando comunica estado**. O que tem cor é o que merece o olhar do operador.

| Token | Uso |
|---|---|
| Grafite (bg, surface) | Fundo e cartões. |
| Âmbar #FFB020 | Marca: ação principal, seleção no editor, foco, tutorial. |
| Verde #2FBF71 | Normal / ligado. |
| Vermelho #E5484D | Alarme / parada / erro. |
| Amarelo #F5C518 | Atenção. |
| Azul #3E9BFF | Informação, barras e curvas. |

Espaçamento por tokens (`Ind.space` 16, `Ind.spaceLarge` 28, `Ind.page` 20 de margem), cantos de 16 px, cartões e campos sem borda: a borda aparece só quando comunica algo (âmbar = falta configurar, vermelho = erro, âmbar grosso = selecionado no editor).

Tipografia IBM Plex (licença OFL): Sans para texto, Sans Condensed para títulos e rótulos de elemento (estilo placa de painel), Mono para números — dígitos de largura fixa não "pulam" quando o valor muda. Tudo em `lib/core/theme/app_theme.dart`; a cor de estado é salva no projeto pelo nome, então o tom pode ser ajustado sem quebrar arquivos.

## 9. Padrões de projeto

| Padrão | Onde |
|---|---|
| Template method | `ModbusClient` implementa as funções; cada transporte só implementa `transact`. |
| Strategy | Transporte TCP real × simulado, escolhido por tipo de equipamento. |
| Observer | `ValueNotifier` por variável no `TagStore`; `TagBuilder` redesenha só o elemento afetado. |
| Injeção de dependência | `AppScope` (InheritedNotifier) entrega controlador e runtime. |
| Objeto imutável + copyWith | Device, Tag, HmiScreen, HmiElement, Project. |
| Contagem de referência | Inscrições por variável decidem o que é varrido. |
| Função pura | `ModbusPdu`, `ScanPlanner`, `TagCodec` — testáveis sem rede. |
| Catálogo único | `ElementCatalog` é o único lugar que interpreta `HmiElement.props`. |
| Gravação atômica | `ProjectRepository.save`. |

## 10. Manutenção e extensão

### 10.1. Acrescentar um tipo de elemento

1. Valor novo em `ElementType` (`lib/models/hmi_screen.dart`).
2. Ficha em `ElementCatalog.all` e propriedades iniciais em `defaultProps` (`lib/widgets/hmi/element_catalog.dart`); documente as chaves na tabela do catálogo.
3. Renderizador em `lib/widgets/hmi/elements/`, usando `HmiFrame` + `TagBuilder` (a moldura já trata os estados de problema) e `WriteActions` se gravar.
4. Caso novo no `switch` de `HmiElementView` e campos na `ElementConfigSheet`.

### 10.2. Acrescentar um perfil de fabricante (ex.: Inovance)

O protocolo não muda; muda onde cada área começa. Plano: campo `profile` em `Device`, e no cadastro de variável um campo "memória do CLP" ("M100", "D200") traduzido em área + endereço pelo perfil. O restante do app continua recebendo `Tag` com endereço Modbus — nada mais muda.

### 10.3. Acrescentar outro protocolo

Implementar um transporte com a mesma interface de `ModbusClient` só serve para Modbus sobre outro meio (ex.: RTU por gateway). Protocolo diferente (OPC-UA, S7) pede uma sessão própria no nível da `DeviceSession`, com o mesmo contrato: publicar `TagReading` no `TagStore` e aceitar `write`.

### 10.4. Mudar o formato do arquivo

Mudança compatível (campo novo com valor padrão): só o `fromJson`. Mudança incompatível: subir `Project.schemaVersion` e migrar o formato antigo em `ProjectRepository.decode` antes do `fromJson`.

### 10.5. Mudar um tutorial

Textos em `lib/screens/tours.dart`. Mudou a trilha de verdade: suba o `version` dela — reaparece para todos. Todo passo responde "e se a tela estiver vazia?".

### 10.6. Rodar e testar

```
flutter pub get
flutter run                 app no emulador/celular (abre com a demonstração)
flutter test                testes (protocolo, TCP real, codec, runtime, telas)
flutter analyze             análise estática (deve dar "No issues found")
python tool/gerar_icone.py  regera os ícones
node tool/gerar_docx.js     regera este documento em Word
```

## 11. Código crítico explicado

### 11.1. Um pedido por vez (`ModbusClientTcp.transact`)

O ciclo inteiro — montar MBAP, enviar, esperar a resposta com o mesmo Transaction ID ou o tempo-limite — roda dentro de uma trava FIFO assíncrona. A recepção monta frames a partir do campo Length do MBAP; resposta de TID diferente do pendente é descartada (era de um pedido que já estourou o tempo).

### 11.2. Agrupamento (`ScanPlanner.plan`)

Por área, ordena as variáveis pelo endereço e vai estendendo o bloco enquanto a próxima variável começa até `maxGap` posições depois do fim atual e o bloco continua dentro do limite do protocolo. Variáveis isoladas (endereço suspeito) ganham bloco próprio.

### 11.3. Laço de varredura (`DeviceSession._loop`)

Cada `start()` ganha um número de geração; um laço antigo que ainda esteja no meio de uma leitura percebe que foi substituído e termina — sem isso, fechar e reabrir a tela rápido deixaria dois laços varrendo juntos. O laço dorme sem variável em uso e acorda na hora por `wake()` (escrita, variável nova).

### 11.4. 32 bits (`TagCodec._word32`)

Primeiro desfaz a troca de bytes de cada registrador (se a ordem troca bytes), depois a troca de palavras (se troca palavras), e monta `(w0 << 16) | w1`. A escrita faz o inverso, na ordem inversa. O float passa por `ByteData`.

### 11.5. Realce do tutorial (`_HolePainter`)

Pinta um retângulo escuro na tela inteira menos (`PathOperation.difference`) o retângulo arredondado do alvo, e contorna o buraco em âmbar. O alvo é medido com `localToGlobal` relativo ao `TourHost` depois do quadro, e o alvo fora da tela é trazido com `Scrollable.ensureVisible`.

## 12. Correções em relação à base anterior

| Problema na base (machine_monitor / InoRobot) | Correção |
|---|---|
| Falha de leitura devolvia lista vazia — endereço errado, rede fora e resposta corrompida eram iguais. | Exceções tipadas; cada caso tem visual e mensagem próprios. |
| `_applyEndianness` do InoRobot trocava registradores vizinhos de lugar em vez dos bytes. | Ordem de bytes por variável, no codec, com as 4 ordens testadas. |
| Flag global `isLittleEndian` trocava bytes de todo registrador. | Removida; registradores voltam crus (big-endian, como a norma). |
| Vários pedidos pendentes no mesmo socket. | Um pedido por vez + agrupamento de leituras. |
| Leituras contínuas FC02/FC04 removidas no machine_monitor. | FC01–FC04 disponíveis. |
| Singleton por equipamento (InoRobot). | Uma sessão por equipamento, criada sob demanda. |
| Permissão INTERNET só no manifesto de debug — o app de loja não conectaria. | Permissão no manifesto principal. |
| `applicationId` `com.example.*` (recusado pela Play Store). | `com.celiware.ihm`. |
| Release assinado com chave de debug. | Assinatura por `key.properties` fora do git; debug só como alternativa local. |
| Mapas de memória fixos no código (monitor, TEX). | Variáveis e telas configuradas pelo usuário, salvas em arquivo. |

## 13. Testes

| Arquivo | O que cobre |
|---|---|
| `test/core/modbus_pdu_test.dart` | Montagem de pedidos, limites, respostas de exceção, lógica do escravo. |
| `test/core/modbus_client_tcp_test.dart` | Cliente TCP real × escravo Dart por socket: leitura/escrita, endereço inexistente, 50 pedidos paralelos, timeout, queda e reconexão, desconexão manual, IP morto. |
| `test/runtime/tag_codec_test.dart` | 4 ordens de 32 bits, float, sinal, bit em registrador, listas, faixa, vírgula brasileira, formatação. |
| `test/runtime/scan_planner_test.dart` | Agrupamento, buracos, limite de 125, áreas separadas, isolamento. |
| `test/runtime/hmi_runtime_test.dart` | Inscrição, isolamento do endereço errado, escrita, queda com último valor, soltura insistente do pulso, variável apagada. |
| `test/widgets/app_flow_test.dart` | Primeira abertura, valores ao vivo, botão com confirmação ligando a máquina, tela só acompanhamento, editor com paleta, escolha de variável e configuração. |
| `test/widgets/tour_test.dart` | Tutorial aparece na primeira visita, "já vi" com versão na chave, rearme por versão nova, "voltar" fecha o tutorial e não a página. |

Os testes de widget rodam no relógio simulado do Flutter: varredura, demonstração e animações avançam por passos, sem depender da velocidade da máquina. Toque que não acerta o alvo é falha, não aviso (`hitTestWarningShouldBeFatal`). Eles já pegaram seis defeitos reais antes do aparelho: quatro transbordos de layout (cartão de tela, legenda do gráfico, lâmpada estreita em dois tamanhos), leitura publicando depois do encerramento e toque sem retorno em tela só acompanhamento.

## 14. Próximos passos

- **Etapa 3 — Play Store:** conta de desenvolvedor da Celiware, chave de upload, ficha da loja. Roteiro em `docs/PUBLICACAO.md`.
- **Perfil Inovance:** tradução de nomes de memória em endereço (10.2), validada no equipamento real.
- **Teste de campo:** cortadora de rótulos do cliente (mapa Modbus já preparado no CLP).
- **Ideias registradas:** variável calculada/script, backup e comparação de parâmetros de inversor, conversores RS-485/CANopen, Siemens, licenciamento.
