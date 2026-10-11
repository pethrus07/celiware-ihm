# Ware IoT

IHM portátil no celular: o usuário cadastra o equipamento pelo IP, dá nome às
memórias que interessam e monta telas de operação arrastando botões,
lâmpadas, mostradores e gráficos — sem programar.

- **Modbus TCP** com qualquer CLP, inversor, IHM ou conversor (genérico; perfis
  de fabricante entram depois).
- **Variáveis intermediárias**: a tela aponta para "Velocidade", não para "HR 2";
  o mesmo dado aparece em vários lugares com uma leitura só.
- **Telas salvas no aparelho**, exportáveis como arquivo para outro celular.
- **Máquina de demonstração embutida**: o app funciona completo sem nada na rede.
- **Alarmes** no padrão ISA-18.2: prioridade por cor, forma e número, faixa no topo, histórico.
- **Tema claro e escuro** (ou automático, pelo celular).
- **Tutorial em cada tela** (botão "?").

## Como rodar

```bash
flutter pub get
flutter run
```

O app abre com o projeto de demonstração (cortadora de rótulos simulada).

## Real × Simulação

Cada equipamento cadastrado é **Na rede** (Modbus TCP de verdade) ou
**Demonstração** (simulado dentro do app). Para testar a rede sem hardware, há
um simulador Modbus TCP em Python em `sim/` — ver `docs/SIMULACAO.md`.

## Estrutura

```
lib/
├── main.dart     Entrada; ciclo de vida (solta botões e para a leitura em segundo plano).
├── app/          Controlador do projeto e injeção de dependência.
├── core/         Pilha Modbus, tema visual, utilitários.
├── models/       Equipamento, variável, tela, projeto.
├── services/     Motor de execução, demonstração, armazenamento.
├── screens/      Páginas do app e textos dos tutoriais.
└── widgets/      Elementos de IHM, tutorial, componentes comuns.
sim/              Simulador Modbus TCP externo (Python).
test/             Testes automatizados.
tool/             Gerador de ícone, da documentação em Word e do vídeo de apresentação (tool/video).
```

## Documentação

| Arquivo | Conteúdo |
|---|---|
| `docs/ARQUITETURA.md` | Documentação técnica completa: arquitetura, comunicação, modelo de dados, telas, tutoriais, padrões, manutenção, código crítico. |
| `docs/Documentacao_Tecnica_Celiware_IHM.docx` | O mesmo documento em Word (gerado de `ARQUITETURA.md` por `node tool/gerar_docx.js`). |
| `docs/SIMULACAO.md` | Como testar sem equipamento: demonstração, simulador Python, Modbus Slave, celular por Wi-Fi. |
| `docs/PUBLICACAO.md` | Roteiro da Play Store (conta, chave, pacote, ficha). |
| `docs/ROADMAP.md` | Versões entregues e tudo o que ainda falta fazer. |
| `docs/REQUISITOS-ETAPA4.md` | Requisitos numerados da etapa 4, com horas e fontes (pesquisas completas em `docs/pesquisa-etapa4/`). |
| `docs/PESQUISA-UI-UX.md` | Pesquisa que embasou o visual (ISA-101, ISA-18.2, mercado). |
| `site/README.md` | Site do produto (HTML/CSS estático em `site/`): como publicar no Cloudflare Pages e onde trocar os links da loja e o e-mail. |

Cada arquivo de código abre com um comentário explicando o que a classe faz e por quê.

## Testes

```bash
flutter test      # protocolo, TCP real, codec, agrupamento, runtime, fluxos de tela
flutter analyze   # deve responder "No issues found"
```

## Dependências

`path_provider`, `file_picker`, `shared_preferences`, `logging`. Modbus sem
biblioteca externa. Fontes IBM Plex (OFL) embutidas.
