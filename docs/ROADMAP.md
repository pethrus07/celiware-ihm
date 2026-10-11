# Roadmap — Celiware IHM

O que já está entregue, o que falta e o que ficou de fora de propósito.
A documentação técnica do que existe está em `ARQUITETURA.md`; este arquivo é
só a lista de trabalho.

## Versão estável atual: 1.3.1

Tag `v1.3.1`. É a versão para apresentar e instalar
(`celiware-ihm-1.3.1-arm64.apk`, celulares Android de 2017 para cá).

| Versão | O que trouxe |
|---|---|
| 1.0 | Modbus TCP próprio, variáveis intermediárias, 11 elementos, editor em grade, demonstração embutida, tutoriais, simulador Python. |
| 1.1 | Escala (fator + soma), texto ASCII, botão com retorno, "Ir para tela", imagem por etapa e PDF em páginas (os 7 áudios do cliente). |
| 1.1.1 | Correções do QA ponta a ponta: tablet/paisagem, bateria (quadros parados), acessibilidade, busca de variável, APK de 19 MB. |
| 1.2.0 | Sistema visual novo pela pesquisa de UI/UX: tema Claro/Escuro/Auto, interação verde-água, lâmpada alto desempenho, elementos redesenhados. |
| 1.3.0 | Alarmes ISA-18.2: prioridade por cor + forma + número, faixa no topo, marca no elemento, lista, histórico, editor na variável, falta de comunicação como alarme. |
| 1.3.1 | QA do APK instalado: botão com retorno vira "SEM RETORNO" após 5 s; faixa sem valor congelado e em uma linha com o celular deitado; tutorial explica cores e alarmes; "ligado" sem verde na lista de variáveis; alarme "Máquina parada" (média) na demonstração; tirado o "Vídeos · Em breve"; textos. |

## Etapa 4 — escopo fechado em 11/10/2026

Reunião de 3h com o cliente em 05/10 (ata `2026-10-05_alinhamento`
no Atas). A lista dele chegou em 11/10: uma conversa no ChatGPT que cresceu até
159 itens e virou uma plataforma de três aplicações (celular, servidor Windows,
nuvem). A própria lista admite que os itens 1–16 são provisórios e que 72–86
repetem 57–71.

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

| # | Item | Da lista dele / da reunião | Hoje (código em 11/10) |
|---|---|---|---|
| 0 | **Correção de conexão (1.3.2):** conectar sempre pelo Wi-Fi quando o equipamento tem IP de rede local, mesmo com dados móveis ligados; teste de conexão avisa "fora do Wi-Fi" e "faixa de IP diferente" | cliente do cliente não conectou (28/09) | o app não amarra a conexão ao Wi-Fi |
| 1 | Publicação na Play Store | reunião | roteiro em `PUBLICACAO.md` |
| 2 | Site do produto: o que é, telas, recursos, como conectar, download, tutoriais | 44, 47 · reunião | não existe |
| 3 | Versão para Windows do **próprio app** (sem função de servidor) | parte cliente do 89 · reunião | `windows/` existe; `.exe` nunca gerado |
| 4 | Grade maior e mais variáveis por tela | reunião | grade atual do editor |
| 5 | Correções no "editar memória" | 2, 11 · reunião | — |
| 6 | Tela de tablet | reunião | item 3 de "Próximo" |
| 7 | Importar memórias por faixa (M0–M1000, D0–D3000, X, Y) | reunião | importa o projeto inteiro |
| 8 | Mapas de memória prontos das marcas parceiras (Inovance, INVT…) | reunião | perfil Inovance planejado (ARQUITETURA §10.2) |
| 9 | Protocolos: Siemens S7, OPC UA, MQTT, Modbus RTU/ASCII (serial e USB-OTG), TCP/UDP/serial com interpretador de mensagens (Arduino) | 15, 16, 60, 64 · reunião | só Modbus TCP |
| 10 | Avisos por voz no fone e narração de eventos | 10, 12 · reunião | o alarme só vibra |
| 11 | Lógica entre máquinas (intertravamento) e cálculos | 13, 14 · reunião | sem motor de lógica; script na escrita recusado na 1.1 — a lógica **nunca** é função de segurança da máquina |
| 12 | Câmeras IP (RTSP) vinculadas à máquina, abertas por botão | 70, 71 | não existe |
| 13 | Receitas: criar, salvar, comparar com a ativa, aplicar com confirmação | 96, 114–118 | não existe |
| 14 | Registro periódico de variáveis, gráfico do registro e exportação CSV | 17, 63, 158, 159 | gráfico de 2 min só em memória |

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
- **Sem data, não decidido:** os itens locais de gestão (OEE, painéis por
  perfil, turnos, metas, paradas, manutenção, peças, relatórios —
  8, 24, 92–154). Não pedem nada externo, mas cada um é um módulo; ficam para
  depois desta etapa.

**Do lado do cliente:** nome comercial, marca e domínio do app; lista do hardware
e cadastro na Shopify; uma peça de cada para os testes; testes nas máquinas
reais com as marcas parceiras.

**Respostas que ficaram da reunião (enviadas a ele):**
- O Windows 11 não roda APK direto (o subsistema Android foi encerrado em 2025);
  no PC, só com emulador. Por isso o item 6.
- Para presentear o app, o Google Play tem códigos promocionais gratuitos.
- Público (leigo ou técnico): em aberto, decidir junto da lista dele.
- Nomes com `.com.br` livre em 06/10: MáquinaNaMão, IHM no Bolso,
  MonitoraMáquina, LigaMáquina, PainelNaMão, MáquinaConectada, ConectaPLC.
  "Conecta Fácil" já é registrado. A decisão é dele.

## Próximo — visual e operação

Na ordem em que convém fazer. Cada item é uma versão pequena, testada no
emulador antes de seguir.

1. **Faixa de status na tela em operação.** Uma linha fixa no topo com o
   estado da máquina (rodando / parada / sem comunicação), o equipamento e
   a hora da última leitura. Hoje essa informação está espalhada. Resolve
   junto o **pulo da tela** quando a faixa de alarme aparece (tudo desce
   ~70 dp e o toque seguinte cai no lugar errado — hoje amortecido porque
   todo comando pede confirmação): o espaço da faixa passa a ser reservado.
2. **Miniatura real das telas.** A lista de telas mostra um desenho genérico;
   passar a mostrar a tela em miniatura, para reconhecer de relance.
3. **Tablet com barra lateral e duas colunas.** Foi a pior nota do QA (4).
   Barra de navegação lateral (NavigationRail) e lista + detalhe lado a lado
   em Equipamentos, Variáveis e Alarmes.
4. **Comando em 3 fases visíveis.** Tocar → "enviando" → confirmado pelo
   equipamento (ou falhou, com o motivo). O botão com retorno já faz parte
   disso; falta estender a todo comando e deixar as três fases à vista.

## Achados do QA de 27/09 que ficaram para depois

Pequenos, nenhum atrapalha a apresentação.

- Gráfico de tendência com série parada em 0 desenha eixo 0 – 1 com
  decimais (0,25 · 0,50): ruído; eixo de série constante deveria ser só "0".
- Gráfico de barras "Produção por hora" rotula o eixo com 1…8 (posição na
  lista), não com a hora.
- Alarme que voltou ao normal mostra "desde 20:07" — é a hora do disparo;
  "disparou 20:07" leria melhor.
- Tela em operação desenha ~14 quadros/s com a máquina parada (valores e
  gráfico ao vivo). Aceitável; cabe revisar a cadência do gráfico quando
  ninguém está olhando para ele.
- Na demonstração, depois do RESET a máquina volta a rodar sozinha porque o
  comando LIGA continuou ligado. É a lógica do CLP simulado, não do app —
  máquina real decide isso no próprio CLP.

## Alarmes — o que falta

- **Alarme com o app fechado.** Hoje o alarme só vale com o app aberto.
  Exige serviço em primeiro plano do Android com notificação permanente
  (e mais bateria). Decidir com o cliente se o uso de campo pede isso.
- **Adiar (shelve)** um alarme com motivo e prazo, para manutenção planejada.
- **Exportar o histórico** de alarmes (CSV) junto com o projeto.

## Publicação — etapa 3 (Play Store)

Roteiro completo em `PUBLICACAO.md`.

- Conta de desenvolvedor **de organização** em nome da Celiware (pede D-U-N-S).
- Chave de upload (credencial permanente — criar e guardar no cofre).
- Ficha da loja: textos, capturas, ícone, política de privacidade.
- Teste fechado com o cliente antes de abrir ao público.

## Campo e fabricantes

- **Teste de campo** na cortadora de rótulos do cliente (mapa Modbus já
  preparado no CLP). É o que valida a 1.x de verdade.
- **Perfil Inovance:** tradução do nome da memória do manual para endereço
  Modbus (ARQUITETURA §10.2), validada no equipamento real.
- **Levantamento de recursos** no editor de IHM da Inovance e no WinCC da
  Siemens: o que ainda falta de "básico de IHM", para não descobrir as faltas
  uma a uma.

## Ideias registradas (sem data)

- Variável calculada / script — só se aparecer caso que a escala linear não cobre.
- Texto gravável pela tela.
- Backup e comparação de parâmetros de inversor.
- Conversores RS-485 e CANopen; perfil Siemens.
- Licenciamento.
- Identidade da Celiware no app (ficou de fora de propósito na 1.2). Em
  05/10 ficou "Powered by Celiware" no app e na máquina (etapa 4).

## Ficou de fora de propósito

- **Script (JS) na variável:** recusado na 1.1 — não tem conta inversa, então
  quebra a escrita.
- **Vídeo "como fazer":** o Pedro decidiu não fazer (27/09/2026).
