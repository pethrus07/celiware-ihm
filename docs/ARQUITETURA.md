# Ware IoT — Documentação Técnica

IHM portátil Modbus TCP · Flutter / Dart · Versão 1.0

## 1. Visão geral

O Ware IoT transforma o celular numa **IHM (interface homem-máquina) montada pelo próprio usuário**. A pessoa cadastra o equipamento (CLP, inversor, IHM, conversor) pelo IP, dá nome às memórias que interessam (as **variáveis**) e monta **telas** arrastando elementos gráficos — botões, lâmpadas, mostradores, gráficos — ligados a essas variáveis. A tela fica salva no aparelho e pode ser exportada como arquivo para outro celular.

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

**Versão 1.1** — recursos básicos de IHM que o cliente cobrou depois de ver o vídeo (áudios de 26 e 27/09/2026):

- **escala** na variável (fator e soma): o equipamento manda 752, a tela mostra 75,2 °C, e gravar 75,2 manda 752;
- **texto ASCII**: nome da máquina, receita, lote — memória inicial + tamanho, 2 letras por registrador;
- **botão com retorno**: grava numa memória e acende pela outra, com o estado "aguardando" quando a máquina não confirma;
- **troca de tela**: botão "Ir para tela" e, em qualquer mostrador, "ao tocar, abrir a tela";
- **imagem por etapa**: uma imagem por código da variável, inclusive um PDF importado (página N = código N).

Script livre (JavaScript) na variável ficou de fora de propósito: a escala linear cobre os casos de manual, e uma fórmula qualquer não tem conta inversa — o botão e o ajuste não conseguiriam gravar.

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
| PDF | Página de PDF → imagem, para a imagem por etapa (`printing`, que usa o renderizador do próprio Android). |
| Marcas por aparelho | "Tutorial já visto", aparência, preferências de voz (`shared_preferences`). |
| Voz | Avisos de alarme e narração de eventos no fone (`flutter_tts`), com fila própria em Dart (§6.9). |
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

Quando o app vai para segundo plano, `main.dart` solta todos os botões de pulso, para a varredura (rede e bateria), cala a voz (§6.9) e grava o que estiver pendente. Ao voltar, a varredura religa com as mesmas inscrições.

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
│   ├── s7/
│   │   ├── s7_address.dart           Endereço do TIA (DB1.DBW4, M10.3, IW64 = EW64).
│   │   ├── s7_codec.dart             Bytes ⇄ valor (big-endian, STRING do S7).
│   │   ├── s7_pdu.dart               TPKT/COTP/S7: montagem e leitura (funções puras).
│   │   ├── s7_error.dart             Erros tipados, inclusive por item.
│   │   ├── s7_client.dart            Cliente ISO-on-TCP (um pedido por vez, PDU, reconexão).
│   │   └── s7_test_server.dart       CLP S7 em Dart (testes de integração).
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

O app usa o endereço do protocolo, **base 0**. Manuais costumam usar a notação clássica com prefixo da área e base 1: "40001" = holding register 0, "30001" = input register 0, "10001" = entrada discreta 0. O cadastro de variável reconhece esse formato e sugere a conversão com um toque ("Parece a notação de manual: 40003 é o endereço 2"); hexadecimal de manual de inversor (`0x2000`, `2000h`) também é aceito. Perfis de fabricante ("M100", "D200") entram aqui no futuro, como tradução nome → endereço.

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

Variável com escala: o codec desfaz a conta antes de montar os registradores — bruto = (valor − soma) ÷ fator. Em registrador inteiro, valor que não cai num passo da escala é recusado ("aceita passos de 0,1"), com tolerância para o erro de ponto flutuante (75,2 ÷ 0,1 = 751,9999…). As mensagens de faixa usam a unidade da tela ("aceita de 0,0 a 6553,5"), nunca o número cru. Texto é só leitura nesta versão.

### 4.12. Escala e texto

**Escala.** Muitos equipamentos mandam número sem vírgula e o manual diz "divida por 10". A conta é da variável, não do elemento: valor = bruto × `scale` + `offset`. Assim o medidor, a barra, o gráfico, as faixas de alarme e os limites do ajuste trabalham todos na unidade de engenharia, e a mesma variável aparece igual em qualquer elemento. As casas decimais saem da escala quando ninguém pediu (÷ 10 → 1 casa; sem isso, 75,2 apareceria arredondado para 75). O painel "Lendo agora" mostra os dois números — "75,2 °C" e "vem 752 do equipamento" — que é a prova de que a conta está certa.

**Texto.** `length` registradores seguidos, 2 letras em cada (byte alto primeiro; com a ordem "bytes trocados", o baixo). Para no primeiro byte zero — o resto do campo costuma vir zerado — e corta espaços do fim. Byte fora do ASCII visível aparece como "?" em vez de sumir calado. É um valor só, não uma lista: vai no mostrador.

### 4.11. Botão de pulso

`press` grava 1 e `release` grava 0. Se a soltura falhar (rede caiu com o dedo no botão), a variável entra numa fila e o runtime tenta gravar 0 a cada segundo até conseguir. Todos os botões são soltos ao fechar a tela, quando o elemento sai da árvore e quando o app vai para segundo plano. Pulso não pede confirmação: "tem certeza?" quebraria o gesto de segurar.

### 4.13. Botão com retorno

Padrão de IHM de mercado: "comando liga" numa memória, "motor ligado" em outra. Com `feedbackTagId`, o comando decide o que o toque faz (liga/desliga inverte o **comando**) e o retorno decide se o botão acende. Comando ligado sem retorno aparece como **aguardando** — borda grossa na cor do botão e ampulheta: a máquina recebeu a ordem e ainda não partiu. Passados **5 s** (`ButtonElement.feedbackTimeout`) sem confirmação, vira **SEM RETORNO** na cor de atenção: a máquina não vai partir (porta aberta, intertravamento, desarme) — a ampulheta para sempre parecia app travado. Confirmou ou o operador desligou, volta ao normal. Sem variável de retorno configurada, o botão acende pela própria variável do comando, como na 1.0.

Por que o toque segue o comando e não o retorno: se seguisse o retorno, com a máquina travada o operador tocaria "desligar" e o app gravaria "ligar" de novo no comando que já estava ligado — o botão nunca desligaria.

### 4.14. Rede local no Android

A rede da máquina quase nunca tem internet. Com os dados móveis ligados, o Android elege o 4G como rede padrão e todo socket sem vínculo sai por ele: o pedido para `192.168.1.10` vai para a operadora e morre em tempo esgotado (comportamento do `NetworkRanker`/`RouteController` do AOSP). Foi o caso do primeiro cliente que "não conectava".

Antes de cada conexão, `ModbusClientTcp` chama `beforeConnect` → `LocalNetwork.prepare(host)` (`lib/services/net/`). Se o IP é privado e cai na faixa de uma rede Wi-Fi/cabo conectada, o canal `celiware/rede` (`RedeLocal.kt`) vincula o **processo** a essa rede (`bindProcessToNetwork`) e pede ao sistema que a mantenha de pé (`requestNetwork` sem exigir internet). Todo socket criado depois, inclusive o do Dart, sai por ela; compartilhar, imprimir e abrir links rodam em outros processos e não são afetados. Equipamento fora de rede local (VPN, 4G) não mexe no vínculo. Se a rede vinculada cai, o vínculo é desfeito e a próxima reconexão escolhe de novo.

O "Testar conexão" usa a mesma informação: mostra por onde a conexão sai ("Wi-Fi 192.168.1.23/24 · sem internet") e, quando falha, diz o que achou ("O celular está em 192.168.0.x e o equipamento em 192.168.1.10: são redes diferentes" ou "não está em nenhum Wi-Fi"). Fora do Android tudo isso é inofensivo e calado.

`targetSdk` está **fixo em 36** no `build.gradle.kts`: com alvo 37 o Android exige a permissão `ACCESS_LOCAL_NETWORK` e, sem pedi-la, toda conexão com CLP falha. Subir o alvo só numa versão que já peça essa permissão.
### 4.15. Modbus RTU/ASCII (gateway serial)

Muito inversor e CLP pequeno só fala Modbus **RTU** pela RS-485. Atrás de um conversor RS-485 → Ethernet que repassa os bytes sem converter, o app fala RTU (ou ASCII) "cru" pelo TCP: equipamento do tipo `modbusRtuTcp`, escolhido em **Na rede → Mais opções → Protocolo**. As funções Modbus são as mesmas (vêm de `ModbusClient`); muda só o envelope (`ModbusFrames`: CRC16 no RTU, LRC no ASCII) e como se acha o fim da resposta — pelo código da função, porque serial não tem cabeçalho de tamanho e o silêncio de 3,5 caracteres da norma não é confiável atrás de USB e de gateways. `ModbusClientSerial` roda sobre um `ByteLink` (TCP hoje; USB-OTG é o próximo), um pedido por vez, com opção de descartar o eco de adaptadores que devolvem o que foi enviado. Resposta de outro escravo é ignorada; CRC/LRC errado vira "resposta inválida".

Testes: `ModbusSerialTcpServer` (escravo RTU/ASCII em Dart, por socket real) e o simulador Python com `--framer rtu|ascii`.

### 4.16. Siemens S7 (núcleo)

O S7 "clássico" (PUT/GET) em Dart puro, em `lib/core/s7/`. Sem Snap7, que é LGPL e pede compilar código nativo para quatro ABIs. Por enquanto é só a camada de protocolo: o `S7Driver`, o cadastro do equipamento (rack/slot) e o campo de endereço vêm depois.

- **Endereço** (`s7_address.dart`). Aceita `DB1.DBX0.0`, `DB1.DBB2`, `DB1.DBW4`, `DB1.DBD8`, `M10.3`, `MB`/`MW`/`MD`, `I`/`E` e `Q`/`A`. O mnemônico alemão e o internacional dão o mesmo endereço; o texto canônico é o internacional. Também aceita o `%` do TIA e a faixa `P#DB1.DBX10.0 BYTE 22`, usada para STRING e blocos de bytes. O tamanho sugere o tipo, e o erro vem curto, em português: "DB1.DBX0.8: o bit vai de 0 a 7".
- **Conexão** (`s7_client.dart`). Sequência: TCP na porta 102 → COTP CR/CC, com o TSAP calculado de rack/slot (300 = 0/2, 400 = 0/3, 1200/1500 = 0/1) → Setup Communication. O cliente pede PDU de 960 e o CLP responde com o que aceita (240, 480 ou 960). Tem o mesmo `beforeConnect` do Modbus (4.14). Um pedido por vez, com a resposta casada pela referência da PDU; depois de uma queda, o próximo pedido reconecta sozinho.
- **Vários itens por pedido.** A lista de endereços vira o menor número de pedidos que cabe na PDU negociada, contando o pedido (12 + 12 por item) e a resposta (14 + 4 + dado por item, com o byte de enchimento), com no máximo 20 itens. Item maior que a PDU é lido em pedaços e remontado. Com PDU 240, um pedido leva até 19 itens ou 222 bytes. Bit é lido e gravado com transporte BIT: só aquele bit muda no CLP, sem ler, modificar e regravar o byte.
- **Codec** (`s7_codec.dart`). Sempre big-endian: BOOL, BYTE, WORD, INT, DWORD, DINT, REAL e STRING (2 bytes de cabeçalho com capacidade e tamanho).
- **Erros** (`s7_error.dart`, todos `CommError`):
  - **conexão**: `S7Refusal.port` quando a porta recusa; `rackSlot` quando o CLP recusa a conexão ISO ("confira rack e slot");
  - **tempo esgotado**, **protocolo** e **pedido fora do limite**;
  - **pedido recusado inteiro** (`S7RequestRefused`): no 1200/1500 é o sintoma do PUT/GET desligado, e a mensagem diz o que fazer: "o CLP recusou: habilite PUT/GET e desligue o acesso otimizado do DB";
  - **erro por item** (`S7ItemError`: DB inexistente, fora do DB, acesso negado): vem dentro do resultado da leitura, e o driver marca só a variável errada.
- **Limites.** Não fala S7CommPlus (DB otimizado, acesso simbólico, S7-1500 com proteção total), nem temporizador e contador. Escrita dividida em vários pedidos não é atômica.

Testes: o `S7TestServer` é um CLP de mentira em Dart que respeita a PDU como um real (passou dela, volta erro 0x8500). Houve também uma conferência manual contra o servidor do python-snap7 3.2.1. Esse servidor difere de uma CPU real em três pontos:
- lê bit devolvendo o byte inteiro (o cliente aceita as duas formas);
- grava bit sobrescrevendo o byte inteiro;
- só atende um item por pedido de escrita.

### 4.17. Protocolo cru (Arduino)

Arduino, ESP, balança e leitor não seguem norma: cada um manda a sua linha (`T=25.3;P=1\n`, `25.3,1,OK\n`, STX…ETX com BCC) ou o seu pacote binário, por TCP, UDP ou serial. Em vez de um driver por equipamento, um **perfil declarativo** (`MessageProfile`, em `lib/core/rawlink/`) vai no arquivo do projeto e um interpretador genérico o segue:

| Pergunta | Opções |
|---|---|
| Onde a mensagem termina | fim de linha configurável · tamanho fixo (cabeçalho opcional para ressincronizar) · marcadores de início/fim · prefixo de tamanho (bytes depois do tamanho = valor + ajuste) |
| Se ela confere | nenhum, XOR, soma 8 bits ou CRC16 Modbus; cru ou em hexadecimal; no fim do corpo (com separador, como o `*` do NMEA) ou depois do marcador de fim (BCC) |
| Como tirar os campos | `chave=valor` · CSV por posição (com aspas) · regex com grupos nomeados · binário por deslocamento, tipo (u8…f32) e as mesmas quatro ordens de bytes do Modbus |
| Quem fala primeiro | streaming (o equipamento manda) ou polling (pedido a cada N ms) |
| Comandos | texto `SET {campo}={valor}\n` (`{valor:2}`, `{cs}`) ou binário `AA {valor:u16} {cs}` |

`MessageParser` só conhece bytes — é o mesmo código no cliente e na futura prévia do editor. Junta mensagem partida, separa as grudadas, descarta lixo antes do início, limita o buffer (mensagem sem fim passa de `maxFrameBytes` e é descartada, inclusive o rabo dela) e, num binário com checksum errado, escorrega byte a byte até voltar a conferir. Mensagens com problema também saem (`FrameProblem`), para a prévia mostrar "checksum errado" em vez de nada. Campo vazio não vira valor; texto só vira número quando o campo inteiro é um número (`25.3C` continua texto — unidade grudada se tira com regex). `RawClient` roda sobre `ByteLink` (`TcpByteLink`, `UdpByteLink`): guarda o valor mais recente de cada chave com o horário, faz o polling sozinho, envia comandos e acusa equipamento mudo pela validade do perfil (`staleAfterMs`). Em UDP o fim do datagrama fecha a mensagem (ESP costuma mandar sem `\n`). Falhas são `RawLinkError`, um `CommError` como os do Modbus.

Falta: o driver no motor (`raw_driver`, variável apontando para a chave do campo), a tela do perfil com prévia ao vivo (RW-3) e a serial por USB-OTG. Testes: `FakeArduinoServer` (Dart, TCP e UDP) e `sim/arduino_falso.py` (SIMULACAO §7).

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
| dataType | bool, uint16, int16, uint32, int32, float32, string. |
| byteOrder | abcd, cdab, badc, dcba. |
| bitIndex | Para liga/desliga dentro de registrador: bit 0 a 15. |
| length | Quantos valores seguidos. Maior que 1 = lista ("memória inicial + tamanho"). Em texto, quantos registradores (2 letras cada). |
| writable | Pode ser alterada pela tela (nunca em área só-leitura; nunca em texto nesta versão). |
| unit, decimals | Apresentação: "°C", 1 casa decimal. |
| scale, offset | Escala linear: valor = bruto × scale + offset (padrão 1 e 0; só vão para o arquivo quando diferentes). |
| alarms | Alarmes da variável: lista de {id, kind (above · below · on · off), limit, priority (high · medium · low), message}. Só vai para o arquivo quando há algum; `normalized()` descarta o que não casa com o tipo. |
| narrations | Narrações por voz (§6.9): lista de {id, kind (equals · above · below), value, text}. Só vai para o arquivo quando há alguma; `normalized()` descarta as sem texto e as que não casam com o tipo (liga/desliga só "valer 1/0"; texto e lista não falam). |

`Tag.normalized()` corrige combinações impossíveis vindas de edição ou de arquivo antigo (área de bit força liga/desliga; área só-leitura e texto tiram a escrita; escala zero volta a 1).

### 5.3. Tela e elemento

A tela é uma grade de **6 colunas de células quadradas**; a célula mede largura ÷ colunas, então a mesma tela fica proporcional em celular e tablet. Num aparelho de 390 dp a célula tem ~60 dp, acima do mínimo de toque de 48 dp. A célula tem **dois tetos**: 96 dp e 1/4,5 da altura útil. Sem eles, no tablet e no celular deitado a célula crescia com a largura e só cabiam dois elementos gigantes (achado do QA de 27/09); agora a grade fica centralizada, do tamanho de um celular em pé 1,5× maior, e o celular deitado mostra ~4,5 linhas. Cada elemento tem posição e tamanho em células e um mapa `props` com a configuração do tipo.

| Tipo | Propriedades |
|---|---|
| button | tagId, label, mode (toggle · momentary · set · reset · value · screen), value, color, feedbackTagId (retorno), goTo (modo screen) |
| lamp | tagId, label, onText, offText, color |
| value | tagId, label |
| input | tagId, label, min, max |
| multistate | tagId, label, states: lista de {value, text, color} |
| bar | tagId, label, min, max, color |
| gauge | tagId, label, min, max, warn, alarm |
| trend | tagIds (até 3), label, windowSec, min, max (vazios = escala automática; valem para o eixo da esquerda). Unidades diferentes ganham eixo à direita, com o mesmo número de passos e números na cor da curva. |
| barChart | tagId (variável lista), label |
| label | text, size (s · m · l), align (left · center) |
| image | data (PNG em base64, reduzido a 900 px), fit (contain · cover), source (fixed · byValue), tagId + images: lista de {value, data} (modo byValue, reduzidas a 1200 px) |

Em qualquer elemento menos botão e ajuste de valor, `goTo` é a tela que abre ao tocar (nos dois o toque já grava; o botão tem o próprio modo "Ir para tela"). Trocar de tela **substitui** a atual, como numa IHM de painel: só a tela à vista é lida e o "voltar" leva à lista de telas.

A imagem por etapa é o "multiestado de imagem" das IHMs de mercado: o CLP põe o número da etapa numa memória e a tela mostra como fazer aquela etapa. Um PDF importado vira uma imagem por página (desenhada pelo próprio Android, pacote `printing`), com código = número da página, até 40 páginas. As imagens moram dentro do arquivo do projeto, como a imagem fixa: exportar leva tudo junto. O editor mostra quanto o conjunto pesa ("12 imagens · 3,4 MB no projeto"). Código sem imagem mostra a imagem fixa, se houver, ou "SEM IMAGEM PARA O CÓDIGO n" — nunca uma área em branco que parece defeito.

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

Botão: seis modos, entre eles **Ir para tela** (escolhe a tela; o rótulo vira o nome dela) e, nos modos liga/desliga, **Retorno da máquina** — por padrão "Mesma variável do comando", tocar escolhe outra. Imagem: **Fixa** ou **Muda com a variável**; no segundo, a variável da etapa e a lista código → imagem, com "Acrescentar imagens" (várias de uma vez) e "Importar PDF". Demais elementos: **Ao tocar, abrir a tela** (Nada ou uma das telas), só quando o projeto tem mais de uma tela.

![Editor com elemento selecionado](imagens/editor.png)
![Configuração do elemento](imagens/configurar-elemento.png)

### 6.5. Equipamentos

Lista com nome, endereço e selo de comunicação. Cadastro com quatro coisas à vista: onde está (rede ou demonstração), nome, IP e **Testar conexão**. Porta, ID, tempo-limite e ritmo ficam em "Mais opções" (o resumo "Porta 502 · ID 1" aparece fechado). O teste responde na hora; quando falha, mostra o que conferir, na ordem em que os problemas costumam acontecer (mesmo Wi-Fi, IP, Modbus ligado no equipamento, porta/ID). Quando o equipamento **recusa** a conexão (o IP respondeu na hora, mas nada escuta na porta — errno 111 no Android, 10061 no Windows), a mensagem vira "o equipamento recusou a conexão nesta porta" e só sobram as duas conferências que fazem sentido: porta e Modbus ligado. "Mais opções" rola a tela sozinho ao abrir, nos dois formulários.

### 6.6. Variáveis

Lista agrupada por equipamento: nome, endereço e o valor ao vivo. O cadastro cabe numa tela: equipamento (só aparece se houver mais de um), nome, o que é (liga/desliga, número inteiro, número com vírgula), onde fica (lê e grava / só leitura), endereço com − / + e "pode ser alterada pela tela". Escala, unidade, decimais, lista, formatos raros (INT16, 32 bits, texto), ordem de bytes e observação ficam em "Mais opções", que abre sozinho quando algum deles está em uso; fechado, o resumo mostra o que está valendo ("÷ 10 · °C · 1 decimais"). A escala tem atalhos — Sem escala, ÷ 10, ÷ 100, ÷ 1000, × 10 — e "Outra", que abre fator e soma. Escolher ÷ 100 já acerta as casas decimais para 2. Texto mostra à vista o tamanho em registradores ("8 = até 16 letras"). No topo, **Lendo agora do equipamento**: o endereço digitado é lido a cada segundo, pela mesma conexão da varredura. O painel fica **preso no topo** enquanto o formulário rola — é a resposta de cada campo mexido, inclusive da escala lá embaixo. Variável nova já vem com o equipamento da tela em montagem ou, fora do editor, com o último cadastrado.

**Nada se perde calado** (etapa 4, EM-1 a EM-12). Voltar com alteração pendente — inclusive alarme recém-configurado — pergunta "Descartar alterações?" (Salvar · Descartar · Continuar editando); sem alteração, sai direto. Trocar o tipo avisa na hora os alarmes que deixam de valer (ficam guardados até o Salvar; voltando ao tipo, voltam) e os elementos que deixam de funcionar ("Usada em: Cortadora — operação (Medidor)"); se "Onde fica" muda junto, o campo acende por 2 s, e o "só leitura" se mantém. Sair de Texto devolve "Pode ser alterada pela tela" e o tamanho. O "Lendo agora" sugere com um toque **Inteiro com sinal** (sem sinal acima de 32767) e **palavras trocadas (CDAB)** quando um valor de 32 bits vem absurdo (NaN, acima de 10⁹, abaixo de 10⁻⁶), sem repetir ordem que já falhou. Endereço acima de 65535 tem erro próprio; hexadecimal (`0x2000`, `2000h`) é aceito e mostra "= 8192", e **Mais opções → Endereço em hexadecimal** dá o teclado com A–F. Bit de palavra pode vir de registrador de entrada (só leitura, FC04). Erro de validação abre "Mais opções" se preciso e rola até o campo. Decimais viram − / + (0 a 6) e a unidade ganha atalhos (°C, %, bar, rpm, m/min, A, V, Hz). Com 4 ou mais equipamentos, a escolha vira uma linha que abre a lista (busca a partir de 8). O bloco de endereço mora em `address_field.dart` (`AddressInput` + `AddressField`): é ali que entra a "Memória do CLP" dos perfis de fabricante.

Na escolha de variável do editor, a lista é **agrupada por equipamento** (os que a tela já usa primeiro) e ganha **busca** por nome ou endereço, sem acento, a partir de 8 variáveis compatíveis.

![Endereço inexistente + notação de manual](imagens/notacao-manual.png)
![Endereço corrigido, lendo ao vivo](imagens/variavel-lendo-agora.png)
![Testar conexão: o que conferir](imagens/testar-conexao.png)

### 6.7. Mais

Projeto: renomear, **enviar** (folha de compartilhar do Android: WhatsApp, e-mail, Drive — o caso comum, projeto indo para outro celular), salvar em arquivo, importar, restaurar a demonstração, começar do zero. Tutoriais: cada trilha com o botão de reproduzir, e "Rever todos". Vídeos: aparecem quando houver link (vídeo não mora dentro do app). Sobre e licenças.

### 6.8. Alarmes

Seguem a ANSI/ISA-18.2 (resumo em `docs/PESQUISA-UI-UX.md` §1.2). O alarme **mora na variável** — configurado no cadastro dela, viaja no arquivo do projeto e some junto se a variável for apagada.

**Configurar.** No cadastro de variável, a linha **Alarmes** (resumo "Acima de 85,0 °C · …" e as formas das prioridades) abre o editor: *Quando* (acima de / abaixo de para número; quando ligar / quando desligar para liga-desliga), *Limite* na unidade da tela (já com escala), *Prioridade* em três cartões com a forma de verdade e uma frase ("Agir agora", "Agir logo", "Ficar atento") e *Mensagem para o operador* (vazia = gerada: "Temperatura do motor acima de 85,0 °C"). Texto e lista não alarmam.

**Prioridades — cor + forma + número** (cor sozinha falha para daltônico e para visão periférica):

| Prioridade | Cor (reservada) | Forma | Uso |
|---|---|---|---|
| 1 · Alta | vermelho | losango | Agir agora. |
| 2 · Média | laranja (só alarme usa) | triângulo | Agir logo. |
| 3 · Baixa | amarelo | quadrado | Ficar atento. |

**Estados** (ISA-18.2 §11.3.2): *não reconhecido* — a forma **pisca** a 1 Hz (nunca o texto); *reconhecido* — fixo; *voltou ao normal* — a condição sumiu antes de alguém ver, e o alarme fica na lista até ser reconhecido (senão passaria batido). Reconhecido + normalizado sai da lista.

**Contra alarme tagarela** (EEMUA 191): a condição precisa durar **1 s** para disparar, e a volta tem **banda morta de 1% do limite** (acima de 85 só normaliza abaixo de 84,15).

**Onde aparece.** (1) **Faixa fixa no topo do app**, acima de todas as telas, com o alarme que pede ação (o não reconhecido mais grave), o estado e a hora — sem o valor do disparo, que congelado desmentia o elemento da tela; celular deitado, a faixa cabe numa linha; o número "+2" de outros; toque abre a lista; o celular vibra quando um novo entra (som não funciona no chão de fábrica — ISA-18.2 §11.3.4); com fone, a voz fala (§6.9). Tudo reconhecido, a faixa fica discreta, mas à vista enquanto a condição existir. (2) **No próprio elemento** da tela: borda na cor e a forma no canto — o alarme aparece onde o valor está. (3) Na **lista de variáveis**: sino (tem alarme) ou a forma (em alarme agora). (4) **Página Alarmes** (faixa ou sino da lista de telas): aba *Ativos* — o mais grave em cima; cada cartão com mensagem, valor de **agora** e limite, prioridade/estado, "desde 19:21 · há 3 min" e o botão **Reconhecer** (um a um; "Reconhecer todos" com confirmação quando há mais de um); aba *Histórico* — por dia, hora com segundos, Ativou / Reconhecido / Normalizou.

**Demonstração.** A cortadora já vem com as três prioridades: motor acima de 75 °C (baixa) e de 85 °C (alta), porta aberta (alta), pouca tensão no papel (baixa) e **máquina parada por alarme** (média — é consequência; a causa sobe como alta). A 150 m/min o motor passa de 85 °C em ~40 s, a máquina desarma e o RESET (segurar) rearma. que tem alarmes vira alarme próprio (média): sem leitura, os outros alarmes não merecem confiança. Os alarmes da variável ficam como estão até a leitura voltar.

**Vigiado em qualquer tela.** O `AlarmEngine` (`lib/services/alarms/`) mantém inscritas no runtime as variáveis com alarme enquanto o app está aberto — o equipamento continua sendo lido mesmo sem tela aberta. O histórico (últimos 300 eventos) fica em `historico-alarmes.json`, ao lado do projeto; é do aparelho, não vai na exportação. O piscar usa um timer de 500 ms que só corre com alarme não reconhecido (2 quadros/s, nunca animação contínua).

**Limite desta versão:** com o app em segundo plano a leitura para (bateria), então **não há alarme com o app fechado** nem notificação do Android. Resolver isso pede um serviço em primeiro plano (notificação fixa "vigiando a cortadora") — fica como próximo passo, a decidir.

### 6.9. Voz e narração

Avisos por voz no fone (`docs/REQUISITOS-ETAPA4.md` §9.1, VZ-1 a VZ-6), em `lib/services/voice/`. A voz **nunca é a única indicação**: faixa e vibração continuam iguais, com ou sem voz, com ou sem fone.

**Fila por prioridade.** O `VoiceAnnouncer` escuta o `AlarmEngine` e tem fila própria em Dart — o `flutter_tts` só fala e para (no Windows nem tem fila). Alarme novo entra pela prioridade; mesma prioridade, ordem de chegada; **alta interrompe** média, baixa e narração, e a fala cortada volta para a frente da sua prioridade. A urgência vai na frente: "Alarme urgente: Porta aberta", "Alarme: …", "Atenção: …". O motor fica atrás da interface `SpeechEngine` — os testes usam um falso.

**Quanto fala.** Padrão: alta repete a cada 30 s enquanto ativa e não reconhecida; média fala uma vez; baixa não fala. Cada prioridade e o intervalo são configuráveis. A repetição conta do fim da fala; voltou ao normal sem reconhecimento, não repete mais.

**Silenciar ≠ Reconhecer** (OPC UA Part 9 §5.8.7). `AlarmEngine.silence` marca o alarme (`AlarmEntry.silenced`) e grava **Silenciado** no histórico; ele continua piscando, na faixa e pedindo reconhecimento. O botão só aparece onde a voz insiste (prioridade em "Repete"): discreto ao lado de Reconhecer no cartão, só o ícone na faixa. Reconhecer ou silenciar cala na hora, mesmo no meio da frase. O histórico grava o tipo pelo nome: a 1.3.2 lê "silenced" como "Ativou" sem quebrar; daqui em diante, tipo desconhecido (versão mais nova) é pulado em vez de virar "Ativou".

**Só com fone** (ligado por padrão). Antes de cada fala, o canal `celiware/voz` (`SaidaDeAudio.kt`) consulta `AudioManager.getDevices(GET_DEVICES_OUTPUTS)`: fone com fio, Bluetooth A2DP/SCO/LE, USB, aparelho auditivo. Sem fone a fala é pulada, mas a repetição segue — fala quando o fone voltar. Onde a plataforma não informa, a opção nem aparece e a voz não é calada por palpite. A2DP inclui caixa de som e rádio de carro: o Android não distingue.

**Android.** A fala usa o atributo de navegação (como o GPS: abaixa a música e sai no fone), pede foco de áudio transitório "abaixando os outros" e tem 300 ms de silêncio antes (o Bluetooth come a primeira sílaba). Tempo-limite folgado em cada fala: se o motor der erro no meio, a fila segue. Android 11+: `<queries>` com `android.intent.action.TTS_SERVICE` no manifesto, senão o app não enxerga o motor de voz.

**Voz pt-BR (VZ-6).** Com a voz ligada, ao abrir o app, ao abrir a folha e ao voltar para o app, `FlutterTtsEngine.check` confere: sem motor, sem português do Brasil, ou voz não baixada para uso offline. O problema aparece com nome — "Falta a voz em português (Brasil) em 'Serviços de fala do Google'" — na linha Mais → Voz e avisos e na folha, com **Abrir ajustes de voz** (`com.android.settings.TTS_SETTINGS`; se o fabricante esconder, instalar dados de voz; por fim, ajustes gerais).

**Narração de eventos (VZ-5).** No cadastro de variável, a linha recolhida **Narração por voz** (como a de Alarmes) abre o editor: *Valer X*, *Passar de X* ou *Ficar abaixo de X* → *Falar "texto"* (até 80 letras); liga/desliga: *Ao ligar* / *Ao desligar*. É o item 12 do cliente: variável de estado com um texto por valor ("1 → A máquina está iniciando", "2 → Montagem"); se um indicador de estado já mostra a variável, o editor oferece "Usar os textos do indicador". Fala só na **passagem** — nem na primeira leitura, nem na volta da comunicação (não dá para saber quando mudou) —, depois de todo alarme e no máximo uma vez por evento a cada N s (10 s). O `EventNarrator` mantém essas variáveis inscritas no runtime enquanto a narração está ligada, como o `AlarmEngine`. A demonstração narra "A cortadora parou" e "A cortadora está em ciclo".

**Preferências do aparelho** (`shared_preferences`, chave `voz`; não vão no projeto), em **Mais → Voz e avisos**: ligar, só com fone, volume, velocidade (devagar · normal · rápida) e **Falar um exemplo** (fala mesmo sem fone — é a pessoa pedindo). Em Mais opções: quanto fala cada prioridade, o intervalo da repetição, a narração e o limite por evento.

**Segundo plano: sem voz.** A varredura para (§2.4), então não há alarme novo nem o que falar. `main.dart` chama `VoiceAnnouncer.pause` (para a fala, descarta narração da fila, guarda o alarme) e `resume` (alarme que ainda pede reconhecimento fala ao voltar). Voz com o app fechado pede o serviço em primeiro plano (REQUISITOS-ETAPA4 §9.6) — fora desta entrega.

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

Trilhas: primeiros passos, operar uma tela, montar uma tela, cadastrar equipamento, criar variável. As três do caminho principal (primeiros passos, operar, montar) aparecem sozinhas na primeira visita; equipamento e variável só pelo "?" ou por Mais → Tutoriais — no QA, com as cinco automáticas, o primeiro minuto do app era uma fila de tutoriais. O realce nunca passa da borda da tela (o "?" no canto tinha o contorno cortado). O balão se posiciona onde cabe (abaixo, acima ou sobre o rodapé) e nunca sob a barra de status; o passo de lista realça o primeiro item, não a lista inteira.

## 8. Identidade visual

"Pegada industrial", seguindo a ISA-101 (IHM de alto desempenho) e a pesquisa de 27/09/2026 (`docs/PESQUISA-UI-UX.md`): **fundo neutro, cor só quando comunica estado ou interação**. O que tem cor é o que merece o olhar do operador.

**Dois temas, os mesmos nomes de cor** (`IndPalette.escuro` e `IndPalette.claro` em `lib/core/theme/app_theme.dart`). O código pede "cartão", "texto secundário", "alarme" — nunca um hex — e cada tema decide o tom. Em Mais → Aparência: **Auto** (segue o claro/escuro do celular; padrão), **Claro** ou **Escuro**, guardado por aparelho (o tablet preso na máquina quer luz fixa). Claro lê melhor de dia e no sol (NN/g, FAA HFDS §5.3.8); escuro serve para noite e sala fechada. A troca redesenha a árvore inteira no lugar — a pessoa continua na mesma tela; pintores de gráfico comparam `Ind.revision`.

| Token | Escuro | Claro | Uso |
|---|---|---|---|
| `well` | #0A0C0F | #DADDE2 | Face rebaixada do instrumento: arco do medidor, trilho da barra, poço da lâmpada, fundo do gráfico. |
| `bg` | #0E1014 | #E4E6EA | Fundo da tela. |
| `surface` | #171A1F | #F7F8FA | Cartão. |
| `surfaceHigh` / `surfaceHigher` | #20242B / #2A2F37 | #EBEDF0 / #DDE0E5 | Controle sobre o cartão / pressionado. |
| `raised` | #1C2026 | #FFFFFF | Folha, diálogo. |
| `accent` | #2EC4D0 | #00808C | **Interação**: ação principal, seleção, foco, tutorial. Verde-água — o âmbar antigo colidia com amarelo/laranja de alarme. |
| `ok` · `alarm` · `warn` · `info` | #2FBF71 · #F2555A · #F5C518 · #4C9EFF | #1F9D57 · #D9363C · #F2B705 · #2F7FE0 | Estado. Cada um tem **versão de texto** (`Ind.textFor`): amarelo de preencher não se lê como texto no claro. |
| `series` | #78A9FF · #A56EFF · #FF7EB6 | #2F6FE0 · #8A4FE0 · #D9468C | Curvas e barras de gráfico — nunca cor de estado (curva verde parecia "ok"). |

**Relevo sem enfeite.** No escuro, profundidade vem de luminosidade em camadas, não de sombra (Material dark, Linear, Grafana). Todo cartão tem borda de 1 px quase invisível, sombra em duas camadas e **brilho de 1 px no topo** que some até 40% da altura (`CardEdge`) — "luz vindo de cima". Nada de vidro/desfoque (custa 7–47 ms por quadro no Android), degradê de fundo ou 3D.

**Elementos.** Lâmpada é LED num poço: apagada = poço vazio; acesa = núcleo com reflexo de lente e halo. Estilo **alto desempenho** (padrão): ligado = brilho + palavra, cor só no anormal (vermelho/amarelo continuam coloridos); estilo **painel clássico** (IEC 60073): acende na cor escolhida. Botão é tátil: degradê leve, faixa de LED no alto (apagada na cor a 35%, acesa quando ligado), afunda 1,5 px ao tocar, texto legível sobre qualquer cor. Medidor: arco rebaixado, régua de marcas, faixas de atenção/alarme **por fora** do arco, preenchimento neutro que só ganha cor dentro de uma faixa. Barra: trilho rebaixado, régua e **ponteiro** na ponta (a ISA-101 prefere ponteiro a barra). Indicador de estado: ícone por cor (marcha, alarme, atenção, informação, parado) + tinta de 14% no cartão. Tendência: área em degradê sob a 1ª curva e ponto no valor atual. Gráfico de barras: hora em curso cheia, anteriores esmaecidas.

Espaçamento por tokens (`Ind.space` 16, `Ind.spaceLarge` 28, `Ind.page` 20 de margem), cantos de 16 px (peça interna 10, concêntrica). A borda de estado aparece só quando comunica algo (cor de interação = falta configurar, vermelho = erro).

Tipografia IBM Plex (licença OFL): Sans para texto e rótulos (caixa alta com espaçamento), Sans Condensed SemiBold com **dígitos tabulares** para números (não "dançam" quando o valor muda e cabem mais dígitos que na mono), Condensed para títulos e textos lidos do equipamento, Mono só em eixos. Com a fonte do sistema grande (130%), a barra de abas segura a escala em 115%; o resto do app acompanha.

**Desempenho medido** (emulador Pixel 7, SurfaceFlinger): rolagem a 60 quadros/s sem quadro lento; partida a frio 1,1–2 s; 72 MB de memória. Tela parada desenha só quando um valor muda: a barra anima apenas em mudança de mais de 3%, a lâmpada troca na hora e cada elemento tem a própria camada (`RepaintBoundary`) — a operação com a máquina em ciclo caiu de 38 para 12 quadros/s. A cor de estado é salva no projeto pelo nome, então o tom pode ser ajustado sem quebrar arquivos.

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

Desde a etapa 4 o motor é dividido em dois. A `DeviceSession` é dona do laço, da espera crescente depois de uma queda e da saúde da conexão — vale para todo protocolo. O que é de protocolo mora num **driver** (`lib/services/runtime/drivers/`), atrás do contrato `DeviceDriver`: `connect`, `scan` (lê as variáveis em uso e publica no `TagStore`), `readOnce`, `write`, `ping` e `tagsChanged`. Falha de comunicação sai como `CommError` (`lib/core/comm/`), que a sessão trata igual para todos: "sem comunicação" com o último valor esmaecido. Falha de uma variável só (endereço inexistente, pedido fora do limite) o driver resolve publicando a qualidade daquela variável.

`ModbusDriver` é o primeiro: agrupamento (`ScanPlanner`), isolamento do endereço errado, codec e escrita. Para Modbus sobre outro meio (RTU por serial ou gateway) basta outro transporte com a interface de `ModbusClient`. Protocolo diferente (MQTT, Siemens S7, OPC UA) é um driver novo, escolhido em `DeviceDriver.forDevice` pelo tipo do equipamento. `test/runtime/device_driver_test.dart` mostra o contrato com um driver de mentira. Plano completo dos protocolos: `docs/REQUISITOS-ETAPA4.md` §8.

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
| `test/core/modbus_client_tcp_test.dart` | Cliente TCP real × escravo Dart por socket: leitura/escrita, endereço inexistente, 50 pedidos paralelos, timeout, queda e reconexão, desconexão manual, IP morto, porta fechada = "recusou nesta porta". |
| `test/runtime/tag_codec_test.dart` | 4 ordens de 32 bits, float, sinal, bit em registrador, listas, faixa, vírgula brasileira, formatação; escala ida e volta (÷ 10, deslocamento 4–20 mA, lista), passo e faixa na unidade da tela, casas implícitas, JSON; texto ASCII (zero final, bytes trocados, caractere inválido, só leitura). |
| `test/core/local_network_test.dart` | Faixa de IP, rede privada, diagnóstico do teste de conexão ("redes diferentes", "sem Wi-Fi"), rótulo da rede e leitura do mapa vindo do Android. |
| `test/core/modbus_serial_test.dart` | CRC16 e LRC com vetores conhecidos, fim de quadro pelo código da função; RTU e ASCII sobre TCP por socket real: leitura e escrita, endereço inexistente, adaptador com eco, CRC corrompido, ID errado = sem resposta, porta fechada = recusou. |
| `test/core/s7_test.dart` | Siemens S7. Endereços (alemão/inglês, `%`, `P#`, erros) e codecs. Vetores de referência: COTP CR, Setup Communication, Read/Write Var. Por socket real contra o `S7TestServer`: vários itens num pedido, divisão por itens e por PDU, item maior que a PDU, bit com transporte BIT, REAL/STRING, item com erro sem derrubar os outros, PUT/GET desligado, tempo esgotado, resposta atrasada descartada, pedidos em paralelo, resposta picada (TCP e COTP), queda e reconexão, porta fechada, rack/slot errados. |
| `test/core/rawlink_test.dart` | Protocolo cru: os quatro tipos de delimitação, mensagem partida e grudada, lixo, buffer cheio, ressincronização do binário; checksum com vetores conhecidos (CRC16, NMEA), certo/errado, BCC depois do ETX; campos chave=valor, CSV, regex e binário nas quatro ordens; comandos de texto e binários; JSON do perfil ida e volta; cliente contra o Arduino falso por TCP e UDP (streaming, polling, comando, silêncio, queda, porta fechada). |
| `test/runtime/rtu_device_test.dart` | Equipamento atrás de gateway RS-485 pelo caminho de produção (fábrica → driver → sessão): testar, ler na varredura e gravar em RTU e ASCII; envelope no arquivo do projeto. |
| `test/runtime/device_driver_test.dart` | Contrato do driver com um driver de mentira (não Modbus): a sessão publica, grava e trata queda igual. |
| `test/runtime/scan_planner_test.dart` | Agrupamento, buracos, limite de 125, áreas separadas, isolamento. |
| `test/runtime/voice_announcer_test.dart` | Fila de voz com motor falso e relógio controlado (`fake_async` + `clock`): prioridade, ordem de chegada, alta interrompendo no meio da frase, repetição a cada 30 s, reconhecer/silenciar calando, só com fone, narração com limite por evento, segundo plano, voz pt-BR ausente com nome; `AlarmEngine.silence`; narração na Tag (JSON ida e volta, arquivo antigo, descarte); histórico com "Silenciado" lido pela 1.3.2. |
| `test/widgets/voice_test.dart` | No app: alarme alto fala e repete; Silenciar (faixa e cartão) cala sem reconhecer e entra no histórico; folha Voz e avisos (exemplo, desligar, velocidade, quem repete, gravado no aparelho); falta de voz pt-BR com o nome do motor; linha de narração no cadastro de variável. |
| `test/runtime/alarm_logic_test.dart` | Condição com banda morta (acima/abaixo), liga/desliga, valor inválido, mensagem padrão com unidade, alarmes no JSON, descarte de alarme incompatível com o tipo, prioridades. |
| `test/runtime/hmi_runtime_test.dart` | Inscrição, isolamento do endereço errado, escrita, queda com último valor, soltura insistente do pulso, variável apagada, bit de registrador de entrada (FC04, só leitura). |
| `test/widgets/tag_form_test.dart` | Cadastro de variável, EM-1 a EM-12: descartar alterações, aviso de alarmes e de elementos ao trocar o tipo, realce de "Onde fica", volta de Texto, sugestões de sinal e de CDAB no "Lendo agora", endereço acima de 65535, hexadecimal, bit de registrador de entrada, rolar até o erro, decimais e unidade, escolha entre muitos equipamentos; leitura de endereço, sugestões e usos da variável como funções puras. |
| `test/widgets/app_flow_test.dart` | Primeira abertura, valores ao vivo, botão com confirmação ligando a máquina, tela só acompanhamento, editor com paleta, escolha de variável e configuração; escala e texto na tela do líder, troca de tela pelo botão e pelo mostrador, botão com retorno aguardando com a porta aberta; celular deitado com célula no teto e grade centralizada; busca de variável sem acento; troca de aparência no meio do uso; alarme ponta a ponta (não dispara antes de 1 s, faixa no topo, marca no elemento, reconhecer, normalizar, histórico) e alarme que normaliza sem ninguém ver continuando na faixa. |
| `test/widgets/trend_axis_test.dart` | Eixo da direita do gráfico de tendência: cobre os dados, mesmo número de passos, passo redondo, sem eixo negativo para grandeza positiva (inclusive valor constante 0). |
| `test/widgets/tour_test.dart` | Tutorial aparece na primeira visita, "já vi" com versão na chave, rearme por versão nova, "voltar" fecha o tutorial e não a página. |

Os testes de widget rodam no relógio simulado do Flutter: varredura, demonstração e animações avançam por passos, sem depender da velocidade da máquina. Toque que não acerta o alvo é falha, não aviso (`hitTestWarningShouldBeFatal`). Eles já pegaram seis defeitos reais antes do aparelho: quatro transbordos de layout (cartão de tela, legenda do gráfico, lâmpada estreita em dois tamanhos), leitura publicando depois do encerramento e toque sem retorno em tela só acompanhamento.

## 14. Próximos passos

- **Etapa 3 — Play Store:** conta de desenvolvedor da Celiware, chave de upload, ficha da loja. Roteiro em `docs/PUBLICACAO.md`.
- **Perfil Inovance:** tradução de nomes de memória em endereço (10.2), validada no equipamento real.
- **Teste de campo:** cortadora de rótulos do cliente (mapa Modbus já preparado no CLP).
- **Ideias registradas:** variável calculada/script (só se aparecer caso que a escala linear não cobre), texto gravável pela tela, backup e comparação de parâmetros de inversor, conversores RS-485/CANopen, Siemens, licenciamento.
- **Referência de recursos:** levantar no editor de IHM da Inovance (e no WinCC da Siemens) o que ainda falta de "básico de IHM", para não descobrir as faltas uma a uma.
- **Alarme com o app fechado:** serviço em primeiro plano + notificação do Android (hoje os alarmes e a voz só valem com o app aberto). Também "adiar" (shelve) um alarme com motivo e prazo.
- **Próximas fases do visual:** faixa de status no topo da operação, miniatura real das telas, tablet com barra lateral, comando em 3 fases visíveis.
