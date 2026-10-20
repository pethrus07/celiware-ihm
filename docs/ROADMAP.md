# Roadmap — Ware IoT

O que já está entregue, o que falta e o que ficou de fora de propósito.
A documentação técnica do que existe está em `ARQUITETURA.md`; este arquivo é
só a lista de trabalho.

## Versão estável atual: 1.3.2

Tag `v1.3.2`. É a versão para apresentar e instalar
(`celiware-ihm-1.3.2-arm64.apk`, celulares Android de 2017 para cá). A próxima já sai com o nome **Ware IoT**.

**Prévia 1.4.0 (11/10, sem tag; build 11 em 12/10):** a etapa 4 construída até
aqui, para teste interno (`ware-iot-1.4.0-previa-4-arm64.apk`, com câmeras,
cabo USB-OTG, OPC UA, as duas rodadas de QA visual, os modelos de tela, o
elemento OEE e a procura de equipamentos na rede). Não é entrega: a etapa 4 sai
numa entrega só, quando fechar (ver "Forma" abaixo). Estado item a item na
tabela da etapa 4.

| Versão | O que trouxe |
|---|---|
| 1.0 | Modbus TCP próprio, variáveis intermediárias, 11 elementos, editor em grade, demonstração embutida, tutoriais, simulador Python. |
| 1.1 | Escala (fator + soma), texto ASCII, botão com retorno, "Ir para tela", imagem por etapa e PDF em páginas (os 7 áudios do cliente). |
| 1.1.1 | Correções do QA ponta a ponta: tablet/paisagem, bateria (quadros parados), acessibilidade, busca de variável, APK de 19 MB. |
| 1.2.0 | Sistema visual novo pela pesquisa de UI/UX: tema Claro/Escuro/Auto, interação verde-água, lâmpada alto desempenho, elementos redesenhados. |
| 1.3.0 | Alarmes ISA-18.2: prioridade por cor + forma + número, faixa no topo, marca no elemento, lista, histórico, editor na variável, falta de comunicação como alarme. |
| 1.3.1 | QA do APK instalado: botão com retorno vira "SEM RETORNO" após 5 s; faixa sem valor congelado e em uma linha com o celular deitado; tutorial explica cores e alarmes; "ligado" sem verde na lista de variáveis; alarme "Máquina parada" (média) na demonstração; tirado o "Vídeos · Em breve"; textos. |
| 1.3.2 | Conexão amarrada à rede local: com Wi-Fi da máquina sem internet e dados móveis ligados, o app vincula as conexões ao Wi-Fi (`RedeLocal.kt`); teste de conexão mostra a rede usada e avisa faixa de IP diferente ou celular fora do Wi-Fi; `targetSdk` fixo em 36. |

## Etapa 4 — escopo fechado em 11/10/2026

Reunião de 3h com o cliente em 05/10 (ata `2026-10-05_alinhamento`
no Atas). A lista dele chegou em 11/10: uma conversa no ChatGPT que cresceu até
205 itens (parecia 159; o ChatGPT continuou numerando de 160 a 205) e virou uma
plataforma de três aplicações (celular, servidor Windows, nuvem). A própria
lista admite que os itens 1–16 são provisórios e que 72–86 repetem 57–71.

- **Valor:** R$ [valor], como a etapa anterior. R$ [valor] até 20/10; R$ [valor] na
  publicação na Play Store (R$ [valor] desta + R$ [valor] guardados da etapa 3).
- **Forma:** uma entrega com escopo fechado, depois quantas rodadas de teste
  forem precisas. Sem versões incrementais no meio (a 1.3.2 abaixo é exceção:
  corrige a etapa anterior).
- **Produto:** app gratuito por agora; a receita vem do hardware (conversores
  RS-485/232 → Wi-Fi, roteador 4G com VPN, repetidores), vendido na loja
  Shopify com link no site. Marca "Powered by Celiware".

**Regra de corte (decisão do Pedro, 11/10):** entra o que vive **dentro do
app**. Fica fora tudo o que é externo ao sistema — servidor, nuvem, contas,
licenças, biometria — e os idiomas. Argumento ao cliente: o que dificulta a
aprovação na Play Store é recusado (conta e login obrigam exclusão de conta e
formulário de segurança de dados; biometria é dado sensível; servidor e nuvem
pedem política de privacidade e infraestrutura paga), e nada disso cabe num
upgrade de R$ [valor].

### Entra

**Requisitos detalhados, horas e fontes:** `docs/REQUISITOS-ETAPA4.md`. **Conferência item a item da lista do cliente (205 itens):** `docs/RASTREABILIDADE-LISTA-CLIENTE.md` — os 16 itens que estavam para decidir foram decididos em 12/10 (8 feitos, 8 para depois com o motivo). (levantamento de 11/10/2026: [estimativa interna] no total, mais da metade em protocolos).

| # | Item | Da lista dele / da reunião | Estado (13/10) |
|---|---|---|---|
| 0 | **Correção de conexão (1.3.2):** conectar sempre pelo Wi-Fi quando o equipamento tem IP de rede local, mesmo com dados móveis ligados; teste de conexão avisa "fora do Wi-Fi" e "faixa de IP diferente" | cliente do cliente não conectou (28/09) | **Feito (1.3.2).** Falta a prova em celular real com Wi-Fi sem internet + 4G. |
| 1 | Publicação na Play Store | reunião | **Lado técnico pronto (12/10):** `.aab` de loja com portões (sem chave de upload não sai), alvo 36, 16 KB, privacidade no app, ficha pt-BR, gráfico de recursos, 8 capturas de celular e 5 de tablet, formulários (`docs/loja/`). D-U-N-S em mãos (13/10: **[D-U-N-S]**). Falta o que é do dono, na ordem da seção "Publicação na Play Store" abaixo: domínio e site no ar, conta de organização (reunião com o cliente), chave de upload. |
| 2 | Site do produto: o que é, telas, recursos, como conectar, download, tutoriais | 44, 47 · reunião | **Feito** em `site/` (7 páginas, Lighthouse 99–100), com o link "Quero aprender automação" para o Instituto (item 184) e os protocolos novos marcados como ainda sem teste em equipamento real (12/10). Visual refeito em 13/10 (palco escuro com brilho, prints maiores) e **lotes 1 e 2 de conversão feitos em 13/10** (seção "Site — conversão"; Lighthouse 95–99 / 100 / 100 / 100). **No ar desde 14/10 em https://wareiot.com.br** (e-mail celiwareautomacao@gmail.com, "Loja" leva à loja Shopify da Celiware). Escondidos até o link existir: botões dos três produtos (a loja ainda não os tem), WhatsApp e vídeo completo (`site/README.md`). |
| 3 | ~~Versão para Windows do próprio app~~ — **adiada em 11/10/2026** (decisão do Pedro) | parte cliente do 89 · reunião | `windows/` existe; `.exe` nunca gerado |
| 4 | Grade maior e mais variáveis por tela | reunião | **Feito:** grade fina 6 ↔ 12 colunas, mover e redimensionar sem arrastar, Tabela de valores (até 30 variáveis), ≥ 40 variáveis numa tela de celular (GR-1 a GR-10). |
| 5 | Correções no "editar memória" | 2, 11 · reunião | **Feito:** nada se perde calado, sugestões de sinal e CDAB, hexadecimal, bit de registrador de entrada (EM-1 a EM-12). |
| 6 | Tela de tablet | reunião | **Feito:** trilho a partir de 600 dp, lista + detalhe, formulários estreitos, painel do editor, estado ao girar, capturas em `docs/imagens/tablet/` (TB-1 a TB-7). |
| 7 | Importar memórias por faixa (M0–M1000, D0–D3000, X, Y) | reunião | **Feito:** Criar várias por faixa na notação do fabricante ou CSV, com prévia, leituras por ciclo e conflitos (IF-1 a IF-5). |
| 8 | Mapas de memória prontos das marcas parceiras (Inovance, INVT…) | reunião | **Feito:** Inovance H3U/H5U, INVT IVC1/IVC3, WEG TPW04, Delta DVP, inversores MD500/GD20; campo "Memória do CLP" (MP-1 a MP-6). Validar em bancada (H3U primeiro). |
| 9 | Protocolos: Siemens S7, OPC UA, MQTT, Modbus RTU/ASCII (serial e USB-OTG), TCP/UDP/serial com interpretador de mensagens (Arduino) | 15, 16, 60, 64 · reunião | **Feitos:** base de drivers, Modbus RTU/ASCII por gateway e por **cabo USB-OTG**, MQTT, Siemens S7, **OPC UA** (cliente próprio, modo None: usuário e senha, ler, gravar, navegar), TCP/UDP cru com perfil e prévia (Arduino, também pelo cabo). Fora: OPC UA Sign/SignAndEncrypt e Subscription. **Nenhum testado em equipamento real** (USB só com porta simulada; OPC UA contra o asyncua). |
| 10 | Avisos por voz no fone e narração de eventos | 10, 12 · reunião | **Feito:** alarmes falados no fone com fila por prioridade, silenciar ≠ reconhecer, narração por valor (VZ-1 a VZ-6). Conferir a voz no celular (timbre é julgamento humano). |
| 11 | Lógica entre máquinas (intertravamento) e cálculos | 13, 14 · reunião | **Feito:** variáveis calculadas (contas com variáveis de qualquer equipamento, taxa de contador) e regras "quando… durar… gravar" no modo propor (LG-1 a LG-7). Nunca função de segurança. |
| 12 | Câmeras IP (RTSP) vinculadas à máquina, abertas por botão | 70, 71 | **Feito (12/10):** câmera ligada à máquina, aberta por um Botão no modo "Abrir câmera", estado e atraso à vista, reconexão, foto pela URL HTTP, senha no cofre do Android (CM-1 a CM-5; ONVIF de fora). Testado no emulador com câmera falsa (~0,9 s); falta câmera de verdade. |
| 13 | Receitas: criar, salvar, comparar com a ativa, aplicar com confirmação | 96, 114–118 | **Feito:** tipos e receitas, ler da máquina, comparar, aplicar com confirmação e relatório de falha parcial, condição, transferir, versões, histórico (RC-1 a RC-7). |
| 14 | Registro periódico de variáveis, gráfico do registro e exportação CSV | 17, 63, 158, 159 | **Feito:** grupos de registro em SQLite, histórico com zoom e lacunas, CSV para Excel pt-BR (RG-1 a RG-6). Só com o app aberto. |

### Já existe (1.3.1) — conta como entregue

Cadastro de equipamentos (5), variáveis e edição (2, 11), memória padronizada
(6, 19), indicadores e elementos (7, 23), navegação entre telas (9),
diagnóstico e teste de conexão (20, 26), alarmes e histórico (21, 22), modo de
simulação (27), exportar/importar projeto (39), tutoriais de primeiro uso (53),
aviso de dado desatualizado (142), vibração no alarme (157). Em parte:
compartilhar projeto (18), duplicar (29), tela só de acompanhamento (32),
várias máquinas numa tela (61).

### Fica fora

- **Externo ao sistema:** login e contas (1), permissões e auditoria em
  servidor (30, 31), API, painel web, nuvem, sincronização, atualização remota
  (34–38), servidor Windows central e projetos no servidor (89, 91), nuvem RT
  (90), acesso remoto e sessões (103, 104), controle centralizado de comandos
  (155, 156).
- **Comercial e licenças:** planos e licenças (50, 51 — contradiz "app
  gratuito"), marketplace (43), gateway de hardware próprio (49), loja (48, é
  do cliente), banner (59), vídeos (46 — decidido em 27/09).
- **Biometria:** reconhecimento facial (69).
- **Idiomas:** app e site trilíngues (87, 88).
- **Sem data (49 itens, cada um com o motivo na rastreabilidade):** os
  módulos locais de gestão (painéis por perfil, turnos, metas, paradas,
  manutenção, peças, relatórios — 24, 93–154), alarme com o app fechado (92,
  depois da 1ª publicação), HTTP (56, 169, 173 — quando houver equipamento que
  fale HTTP), padrões WARE (163, 164 — a Celiware define), vários projetos (9)
  e áudio gravado (10). Não pedem nada externo, mas cada um é um módulo. O
  OEE (8) entrou: feito em 12/10. Vários projetos (9) entrou na versão
  seguinte, como planta (20/10, seção acima).

**Do lado do cliente:** ~~nome comercial~~ — **definido em 11/10/2026: Ware IoT** (app, site e tudo o mais; "WARE" já era o nome dos padrões de dados da Celiware); marca e domínio; lista do hardware
e cadastro na Shopify; uma peça de cada para os testes; testes nas máquinas
reais com as marcas parceiras.

**Respostas que ficaram da reunião (enviadas a ele):**
- O Windows 11 não roda APK direto (o subsistema Android foi encerrado em 2025);
  no PC, só com emulador. Por isso o item 6.
- Para presentear o app, o Google Play tem códigos promocionais gratuitos.
- Público (leigo ou técnico): em aberto, decidir junto da lista dele.
- Nomes com `.com.br` livre em 06/10: MáquinaNaMão, IHM no Bolso,
  MonitoraMáquina, LigaMáquina, PainelNaMão, MáquinaConectada, ConectaPLC.
  "Conecta Fácil" já é registrado. **Decidido em 11/10: Ware IoT.**

## Próxima versão — planta, projetos e barra de cinco áreas (20/10/2026)

Reunião com o cliente em 19–20/10/2026 (ata: decisões D2, D6, D7 e D10).
Construída no branch `feat/projetos-e-barra`, **sem subir a versão** e sem
juntar ao `main` enquanto a 1.4.0 (12) está em revisão na Play. Detalhe técnico
em `ARQUITETURA.md` §5.4.1, §6.1 e §6.7.

| # | Item | Estado |
|---|---|---|
| 1 | **Planta > Projetos** (D6, D10): o arquivo de hoje vira a planta, cada máquina um projeto isolado (equipamentos, variáveis, telas, regras, registros, receitas, câmeras). Migração automática: o projeto de quem atualizar vira o primeiro da planta, com históricos e registros. | **Feito** (testado também no emulador, com arquivo da 1.4.0 plantado). |
| 2 | Primeira aba **Projetos**: lista de projetos; dentro, as telas. Novo projeto (em branco, demonstração, de um arquivo), renomear, duplicar, enviar, salvar, apagar com confirmação. "Começar do zero" e "Importar" nunca mais substituem nada. | **Feito** |
| 3 | Exportar **a planta inteira** (um JSON com a lista de projetos, `schemaVersion` 2) ou **um projeto** (formato de sempre, abre na 1.4.0) (D7). Importar projeto soma; importar planta: somar ou substituir; "Nova planta" e substituir pedem confirmação forte e guardam a cópia da planta atual em `copias/`. | **Feito** |
| 4 | **Regras da planta** (item 226 da lista nova): usam variáveis de qualquer projeto para interligar máquinas, em Ferramentas → Regras → "Da planta"; só no modo "propor" por padrão, nunca segurança (NR-12). O motor lê só as variáveis que as regras ligadas citam. | **Feito**; não testado com duas máquinas de verdade. |
| 5 | **Barra com cinco áreas**: Projetos · Equipamentos · Variáveis · Ferramentas · Alarmes (Registros primeiro e em destaque em Ferramentas). Ajustes (aparência, tutoriais, sobre, privacidade) na engrenagem do topo de Projetos. Trilho do tablet com as mesmas cinco. | **Feito** |
| 7 | **Atualização pela Play** (D2): flexível ao abrir; imediata quando a versão for publicada com prioridade ≥ 4; sem internet ou fora da Play, nada (`PUBLICACAO.md` §12). Commit separado, para descartar se não for agora. | **Feito**; só dá para ver funcionando com a versão seguinte já na Play (teste interno). |
| 6 | Tutorial de início (v2), Regras (v2) e textos sem "Mais →"; site (`tutoriais.html`, `privacidade.html`) atualizado, **não publicado**. | **Feito** |

**Antes de enviar esta versão à Play** (quando a 1.4.0 for aprovada):

- Subir a versão (`pubspec.yaml` e `AppInfo.version`) e escrever as notas.
- Refazer as capturas da loja: a barra e a primeira tela mudaram (`docs/loja/ficha.md`).
- Atualizar `docs/loja/acesso-ao-app.txt` (hoje diz "Mais → Receitas" e
  "Mais → Restaurar a demonstração"; agora é Ferramentas → Receitas e
  Projetos → Novo projeto → Demonstração) e o "Mais → Sobre → Privacidade"
  de `docs/loja/formularios.md`. Ficaram como estão porque descrevem a versão
  em revisão.
- Publicar o site só junto com a versão nova (os textos já falam da navegação nova).
- Conferir a ficha de Segurança dos dados com a biblioteca da Play de
  atualização (ver `PUBLICACAO.md` §12).

**Para o Pedro confirmar:** o app abre dentro do último projeto (e não na
lista); rótulos da barra na Plex Condensed (encolhem até 9 sp no celular de
320 dp); as regras de antes ficaram no projeto migrado (e não na planta);
histórico de uma regra da planta vai para o histórico do projeto aberto na hora.

**Sem data (registrado na reunião):** projetos de plantas diferentes no mesmo
aparelho (hoje é uma planta por aparelho, trocada por arquivo); mover um
projeto de uma planta para outra sem passar por arquivo.

## Próximo — visual e operação

Na ordem em que convém fazer. Cada item é uma versão pequena, testada no
emulador antes de seguir.

1. **Faixa de status na tela em operação.** Uma linha fixa no topo com o
   estado da máquina (rodando / parada / sem comunicação), o equipamento e
   a hora da última leitura. Hoje essa informação está espalhada. Resolve
   junto o **pulo da tela** quando a faixa de alarme aparece (tudo desce
   ~70 dp e o toque seguinte cai no lugar errado — hoje amortecido porque
   todo comando pede confirmação): o espaço da faixa passa a ser reservado.
   **Pulo da tela resolvido em 12/10:** o espaço da faixa é reservado em toda
   tela (56 dp em pé, 48 deitado; "Sem alarmes" em cinza quando não há nada),
   e a pergunta de regra mora na mesma faixa. Falta a outra metade do item:
   estado da máquina, equipamento e hora da última leitura nessa linha.
2. ~~**Miniatura real das telas.**~~ **Feito (etapa 4):** cada cartão da
   lista de telas mostra a planta da tela, com os blocos de cada elemento.
3. ~~**Tablet com barra lateral e duas colunas.**~~ **Feito (etapa 4, item 6):**
   trilho a partir de 600 dp e lista + detalhe.
4. **Comando em 3 fases visíveis.** Tocar → "enviando" → confirmado pelo
   equipamento (ou falhou, com o motivo). O botão com retorno já faz parte
   disso (aguardando → acende quando a máquina confirma → "SEM RETORNO");
   falta estender a todo comando e deixar as três fases à vista.

## Achados do QA de 27/09 que ficaram para depois

Pequenos, nenhum atrapalha a apresentação.

- ~~Gráfico de tendência com série parada em 0 desenha eixo 0 – 1 com
  decimais.~~ **Feito (12/10, `d11b30c`):** série constante ganha faixa
  redonda e nunca eixo negativo.
- ~~Gráfico de barras "Produção por hora" rotula o eixo com 1…8.~~ **Feito
  (12/10, `d11b30c`):** embaixo de cada barra, a hora real (ou 1…n, se a
  lista não for por hora).
- Alarme que voltou ao normal mostra "desde 20:07" — é a hora do disparo;
  "disparou 20:07" leria melhor.
- Tela em operação desenha ~14 quadros/s com a máquina parada (valores e
  gráfico ao vivo). Aceitável; cabe revisar a cadência do gráfico quando
  ninguém está olhando para ele.
- Na demonstração, depois do RESET a máquina volta a rodar sozinha porque o
  comando LIGA continuou ligado. É a lógica do CLP simulado, não do app —
  máquina real decide isso no próprio CLP.

## Alarmes — o que falta

- **Alarme com o app fechado** (item 92 da lista). Hoje o alarme só vale com
  o app aberto. Exige serviço em primeiro plano do Android com notificação
  permanente (e mais bateria), e a Play pede declaração com vídeo. Decidido em
  12/10: depois da 1ª publicação.
- **Adiar (shelve)** um alarme com motivo e prazo, para manutenção planejada.
- **Exportar o histórico** de alarmes (CSV) junto com o projeto.

## Publicação na Play Store — enviada para revisão em 15/10/2026

**Em revisão no Google desde 15/10** (produção, Brasil, 1.4.0 versão 12) e já
disponível no teste interno (link de convite). Detalhe em `PUBLICACAO.md` §0.
Quando aprovar: cobrar os R$ [valor] da publicação; o selo e o QR do site passam
a funcionar sozinhos (já apontam para a página da loja); os clientes do teste
interno só recebem a atualização.

Roteiro completo em `PUBLICACAO.md`; ficha, imagens e formulários prontos em `docs/loja/`.

Na ordem (combinado em 13/10):

1. ~~**D-U-N-S**~~ ✅ **[D-U-N-S]**, Celiware Solucoes Tecnologicas Ltda.
2. ~~**Domínio do site do app**~~ ✅ **wareiot.com.br no ar (14/10)**, com a
   política em `https://wareiot.com.br/privacidade`.
3. ~~**Conta de desenvolvedor de organização**~~ ✅ **criada e verificada (14/10)**, numa reunião com o cliente (código
   por SMS no celular dele, RG ou CNH do representante, cartão internacional
   para os US$ 25, endereço igual ao da D&B). Pela conta Google da Celiware; o
   site da organização é o que já está no ar, `www.celiwareautomacao.com.br`, e
   o e-mail de contato fica nesse domínio.
4. **Chave de upload** (credencial permanente — criar junto e guardar no cofre).
5. `.aab`, ficha e formulários no Console; **teste interno** com o cliente antes
   de abrir ao público. **Decidido em 14/10:** o teste interno é também o
   acesso antecipado dos clientes (link de convite, até 100 e-mails); o APK
   para baixar no site foi descartado (reinstalação obrigatória depois e aviso
   de "fonte desconhecida"). Próxima sessão começa por `PUBLICACAO.md` §0. Quem tem o APK do WhatsApp precisa exportar o projeto,
   desinstalar e instalar pela loja (a assinatura muda).

## Site — conversão (pesquisa de 13/10/2026)

O visual já foi refeito em 12–13/10: palco escuro com brilho verde-água no
topo de cada página, na galeria, nas chamadas finais e no rodapé; faixas
tingidas no lugar do cinza sobre cinza; prints maiores; herói com dois
celulares. O que vem agora saiu da leitura de 64 páginas e 13 fontes
(`docs/pesquisa-etapa4/8-site-conversao.md`). Regra: nada inventado — sem
número de usuário, logo ou depoimento que não exista.

**Lote 1 — sem depender de ninguém**

1. **Fatos colados no botão:** "Android 7 ou mais novo · Grátis · Sem
   cadastro" e "Sem CLP por perto? Já vem uma máquina de demonstração"
   (Datacake, Things; NN/g 2016, transparência antecipada). **Feito em 13/10** (topo do início; os três fatos também nas chamadas finais).
2. **Chamada final na página inicial:** repete o título, com o selo e o QR
   (todas as melhores; hoje a página termina nas perguntas). **Feito em 13/10.**
3. **QR para quem abre no computador**, só a partir de 760 px, com
   `utm_content=qr` (Linear Mobile, Raycast, Arc). **Feito em 13/10** (SVG estático gerado com `segno`; no início, topo e fim).
4. **Chamada que reconhece o aparelho:** Android vê o selo; iPhone vê "o Ware
   IoT é só para Android" com "mandar o link"; computador vê o QR. **Feito em 13/10** (`site/js/site.js`; sem JavaScript, tudo como antes).
5. **"Por que é grátis" à vista** (hoje só nas perguntas): "a Celiware ganha
   com o hardware da loja, não com anúncio, assinatura ou os seus dados"
   (Home Assistant, UniFi, Shelly). **Feito em 13/10** (logo abaixo dos números).
6. **Faixa de números do produto:** 13 elementos · 7 jeitos de agir · 6
   modelos prontos · 6 protocolos · R$ 0 (NN/g 2007). Nunca contagem de
   usuários. **Feito em 13/10** (números conferidos no código; "6 tipos de modelo pronto": inversor e servo têm básico e completo).
7. **Prints anotados** com os três diferenciais: "acende quando a máquina
   confirma", "sem comunicação, último valor esmaecido — nunca zero falso",
   "alarme sempre no mesmo lugar" (Linear Mobile; NN/g 2010). **Feito em 13/10** (um print, `alarme-na-tela`, com três marcas; no celular a lista vem embaixo).
8. **Pergunta "É seguro comandar a máquina pelo celular?"** no topo das
   perguntas, com a resposta franca que já existe (IHM, não intertravamento),
   e "Funciona com o meu CLP?" e "E se cair o Wi-Fi?" (NN/g 2014). **Feito em 13/10** (e o JSON-LD FAQPage).
9. **Selo oficial da Google Play** em português, no lugar do botão próprio
   (regras do Google). **Feito em 13/10** (arte oficial do Partner Marketing Hub, sem alteração; origem no `site/README.md`).

**Lote 2 — médio esforço, sem dependência externa**

10. **Herói interativo:** o celular do herói vira uma tela de operação viva em
    HTML — tocar em LIGA, o botão aguarda e acende quando "confirma", a
    produção sobe, um alarme chega na faixa e a pessoa reconhece. Etiqueta
    "Simulação — no app os valores vêm do CLP"; o print fica como reserva
    sem JavaScript; respeita `prefers-reduced-motion` (FlowFuse Dashboard,
    Home Assistant). Caminho forte, depois: a máquina de demonstração do
    próprio app em build web, carregada só no toque.
    **Feito (13/10)** em `site/js/demo.js` + `site/css/demo.css`: réplica da "Cortadora —
    operação" com o comportamento do `demo_process.dart` (tempo acelerado),
    alarme sozinho acima de 75 °C e "Simular alarme" (superaquece), Reconhecer
    na faixa, Reset abaixo de 80 °C; Lighthouse do início 99/100/100/100.
11. **"Veja funcionando":** trechos mudos de 6–12 s do vídeo de apresentação
    em loop dentro do celular (ligar e confirmar; alarme chegando e
    reconhecido; tela sendo montada), carregados só quando aparecem, e
    "Vídeo completo · 3 min" (Arc, Blynk; NN/g 2014). Depende do Pedro
    aprovar o vídeo.
    **Feito (13/10):** três loops em Recursos (`site/video/`, 106–303 KB cada,
    `tool/video/trechos_site.py`); o vídeo não mostra o operador reconhecendo
    o alarme (isso fica no herói). O vídeo completo **ficou como marcador**
    `#VIDEO-COMPLETO` no herói, até subir no YouTube (`site/README.md`).
12. **Compatibilidade honesta:** tabela por protocolo e por perfil de marca
    com três estados — conferido em equipamento real · testado em simulador ·
    em breve — e "Seu CLP não está aqui? Fale com a gente" (TagoIO, Datacake;
    NN/g 2016, especificações). **Feito em 13/10** em `como-conectar#compatibilidade`. Como nada tem data, o terceiro estado virou "ainda não" (sem data) em vez de "em breve"; nenhum item está como conferido em equipamento real.
13. **Galeria dos modelos de tela** (máquina, inversor, servo, leitor,
    temperatura, balança), com print de cada um (ThingsBoard, TagoIO). **Feito em 13/10** em cartões, sem print de cada modelo (ainda não existem; entram quando forem capturados).
14. **Para quem é:** três entradas — integrador, dono ou líder de produção,
    operador — cada uma com os seus três fatos (IXON, MachineMetrics,
    Ubidots). **Feito em 13/10.**

**Depende do Pedro ou do cliente (lote 3)**

- Foto, ficha técnica (PDF) e preço real do hardware nos cartões de "O que
  você precisa" — os links da loja ainda são marcadores.
- WhatsApp de suporte com horário, no "Por que não conecta?" e nas perguntas.
- "Qual peça eu preciso?" (três perguntas → a peça certa na loja), quando
  houver os links.
- Diagramas de ligação com a foto da peça no lugar do ícone.
- Versão e "Novidades", depois da primeira publicação na Play.
- Foto real de bancada (CLP + conversor + celular com o app); depois, casos
  reais com autorização e a nota da Play quando existir.

## Campo e fabricantes

- **Tudo da etapa 4 em equipamento real:** nada passou de simulador —
  Siemens S7, OPC UA, MQTT (broker), Arduino/protocolo cru, cabo USB-OTG,
  câmera IP, mapas das marcas (H3U primeiro), a voz no fone e a prova da 1.3.2
  (Wi-Fi sem internet + 4G). Depende das peças do cliente.
- **Teste de campo** na cortadora de rótulos do cliente (mapa Modbus já
  preparado no CLP). É o que valida a 1.x de verdade.
- **Perfil Inovance:** tradução do nome da memória do manual para endereço
  Modbus (ARQUITETURA §10.2), validada no equipamento real.
- **Levantamento de recursos** no editor de IHM da Inovance e no WinCC da
  Siemens: o que ainda falta de "básico de IHM", para não descobrir as faltas
  uma a uma.

## Ideias registradas (sem data)

- ~~Variável calculada~~ — **feita na etapa 4** (item 11). Script continua fora (ver abaixo).
- Texto gravável pela tela.
- Backup e comparação de parâmetros de inversor.
- CANopen. (Conversores RS-485 e Siemens S7 entraram na etapa 4, item 9.)
- Licenciamento. **Monetização pelo app** (perguntas do cliente, 18/10/2026; estudo de 19/10, não é intenção do Pedro agora): no Brasil, conteúdo ou recurso digital vendido dentro do app tem de passar pela cobrança da Play (taxa até 30/09/2027: 15% em assinatura; 15% no 1º US$ 1 mi/ano em compra avulsa se inscrito no nível de 15%, senão 30%; depois cai para o modelo novo de 10% + cobrança). Cobrança alternativa ("user choice billing") existe no Brasil, ao lado da Play, com só 4 pontos a menos. Link para pagar fora: proibido no Brasil (só EUA e EEE têm programa). Hardware físico pode ser vendido e linkado livremente. O app sabe qual plano a pessoa tem (produto ativo na Play Billing), mas não recebe nome nem e-mail. Assinatura com planos, compra única ("Pro") e pacote de créditos (consumível) existem; créditos e qualquer licença vendida fora pedem servidor e login — fora da regra de corte atual. Se um dia entrar: compra única ou assinatura validada no aparelho é o caminho mais curto, e a Segurança dos dados e a política mudam antes.
- ~~Identidade da Celiware no app~~ — **feito:** "Powered by Celiware" no
  Sobre (etapa 4).

## Ficou de fora de propósito

- **Script (JS) na variável:** recusado na 1.1 — não tem conta inversa, então
  quebra a escrita.
- **Vídeo "como fazer":** o Pedro decidiu não fazer (27/09/2026).
