# CLAUDE.md — Ware IoT (repo `celiware-ihm`)

App Flutter (Android) de IHM portátil: o usuário cadastra o equipamento, dá nome às memórias
e monta telas de operação sem programar. Nome do produto: **Ware IoT** ("Powered by Celiware").
Pacote `com.celiware.ihm` e nome do repo continuam os antigos (trocar o applicationId é decisão
em aberto do Pedro — não mexer). Cliente: Celiware. Também moram aqui o site do produto (`site/`),
a ficha da Play (`docs/loja/`) e o simulador (`sim/`).

## Onde está cada coisa (ler antes de mexer)

- `README.md` — visão geral e estrutura de `lib/`.
- `docs/ARQUITETURA.md` — documentação técnica completa (camadas, protocolos, modelo de dados,
  telas, identidade visual §8, padrões §9, como estender §10, código crítico §11, testes §13).
- `docs/ROADMAP.md` — **fonte da verdade das pendências** e do que ficou fora de propósito.
- `docs/REQUISITOS-ETAPA4.md` + `docs/pesquisa-etapa4/` — requisitos numerados e pesquisas.
- `docs/RASTREABILIDADE-LISTA-CLIENTE.md` — lista do cliente item a item (contada por script).
- `docs/SIMULACAO.md` — testar sem hardware (demonstração, simulador Python, celular por Wi-Fi, vídeo).
- `docs/PUBLICACAO.md` — roteiro da Play Store; `docs/PESQUISA-UI-UX.md` — base do visual.
- `site/README.md` — site estático (Cloudflare Pages), marcadores a preencher, regras do site.

## Rodar e testar (comandos conferidos nos docs)

```
flutter pub get                          # README.md:20
flutter run                              # README.md:21 — abre com a demonstração (cortadora)
flutter test                             # README.md:66
flutter analyze                          # README.md:67 — tem de dar "No issues found"
python tool/gerar_icone.py               # docs/ARQUITETURA.md:1199 — regera ícones (app, loja, site)
node tool/gerar_docx.js                  # docs/ARQUITETURA.md:1200 — regera o .docx da ARQUITETURA
```

- Site: em `tool/`, `npm run conferir-site` (tool/package.json:12; Playwright, 7 páginas × 3 larguras × 2 temas).
- Pacote da loja: `flutter build appbundle --release` e `python tool/loja/imagens_loja.py conferir`
  (docs/PUBLICACAO.md:108-109). Sem `android/key.properties` o `.aab` para de propósito.
- Simulador Modbus (uma vez, em `sim/`): `python -m venv .venv` e
  `.venv\Scripts\python -m pip install -r requirements.txt`; rodar
  `.venv\Scripts\python simulador.py --cenario cortadora` (docs/SIMULACAO.md:25-34).
  Arduino falso: `python sim/arduino_falso.py` (docs/SIMULACAO.md:149).
- Câmera falsa (RTSP): `dart run tool/camera/camera_falsa.dart --porta 18554 --http 18080`
  (docs/ARQUITETURA.md:1081).
- Vídeo de apresentação: `python tool/video/apresentacao.py ensaio` antes de gravar
  (docs/SIMULACAO.md:126); pré-requisitos e armadilhas em docs/SIMULACAO.md §6.

Não há CI no repo (sem `.github/`): a conferência é `flutter analyze` + `flutter test` local.

## Convenções e armadilhas documentadas no repo

- Cada arquivo de código abre com comentário dizendo o que a classe faz e por quê (README).
- Telas dependem de modelos e serviços, nunca da pilha Modbus direto (ARQUITETURA §2.1).
- Cor sempre por nome do tema (`IndPalette.escuro/.claro`, `Ind.*`), nunca hex no código (§8).
- Componentes únicos em `lib/widgets/common/common.dart` (`DecisionDialog`, `confirmDiscard`,
  `StepButton`, `SectionHeader`, `AdaptiveTitle`, `TextFit`): não montar versão própria (§8).
- Enum novo de elemento sempre **no fim**; `id` de perfil de fabricante nunca se renomeia (§10).
- Mudança incompatível no arquivo do projeto: subir `Project.schemaVersion` e migrar em
  `ProjectRepository.decode` (§10.4). Tipos/chaves desconhecidos são preservados ao salvar.
- Tutorial mudou de verdade: subir o `version` da trilha em `lib/screens/tours.dart`; todo passo
  responde "e se a tela estiver vazia?" (§10.5).
- **O app nunca é função de segurança da máquina** (NR-12): regras entre máquinas só no modo
  "propor"; sem comunicação mostra o último valor esmaecido, nunca zero falso (§6.12, §1.3).
- Senha de câmera vai no cofre do Android, nunca no arquivo do projeto (§5.7).
- `targetSdk` fixo em 36 (subir quebra as conexões locais) — ver ROADMAP 1.3.2 e REQUISITOS-ETAPA4.
- Versão: subir o número depois do `+` em `pubspec.yaml` a cada envio à Play e manter
  `AppInfo.version` (`lib/app/app_info.dart`) igual (docs/PUBLICACAO.md §7/§11).
- No Windows, `flutter pub get` exige Modo de Desenvolvedor (docs/PUBLICACAO.md:114).
- `sim/requirements.txt` trava `pymodbus==3.8.6` — a 3.9+ quebra o simulador.
- Câmera falsa no emulador: não usar a porta 8554 (é o gRPC do emulador). No emulador o PC é `10.0.2.2`.
- Site: **nunca escrever preço nem nome comercial de produto** (site/README.md:66); marcadores
  `#LOJA-*`, `EMAIL_CONTATO` etc. ficam até o Pedro dar os valores.
- Nunca vão para o git: `android/key.properties`, `*.jks`, `*.keystore`, `*.ihm.json`, `sim/.venv/`,
  `tool/node_modules/`, `tool/video/saida/`, `.claude/` (worktrees de agentes) — ver `.gitignore`.

## Regras do Pedro para este repo

- **UI: pouca informação, muito respiro.** Por tela só o que a maioria usa; o resto em
  "Mais opções" com resumo do que está configurado no título fechado. Uma informação, um sinal
  (borda só quando comunica estado). Legenda só onde muda a decisão. Espaçamento por tokens,
  cartões sem borda. Conferir com screenshot real antes de mostrar.
- **Etapa 4 é uma entrega só**: prévias de teste não levam tag nem viram "lançamento"
  (docs/ROADMAP.md, "Forma").
- Pendência nova, decisão ou mudança de escopo vai para `docs/ROADMAP.md`, não para este arquivo.
- Escopo do app: entra só o que vive DENTRO do app (sem servidor, nuvem, contas/login, licenças).
  Versão Windows está adiada por decisão do Pedro.
- Não publicar o site, não criar/enviar nada na Play Console e não mexer em conta/domínio sem
  OK explícito do Pedro na hora (deploy do site: ver site/README.md, "Publicar no Cloudflare Pages").
- Ajuda/tutorial mora num "?" sempre visível no topo, nunca na barra inferior.

## Ambiente nesta máquina (Windows 11)

- Flutter em `~/dev/flutter`; emulador `IHM_Pixel`. Para o Pedro usar o emulador, lançar
  desvinculado (`Invoke-CimMethod Win32_Process Create` com `emulator.exe -avd IHM_Pixel`) —
  `Start-Process` dentro da sessão do Claude morre quando o comando termina.
- Agentes em paralelo: um worktree por agente em `.claude/worktrees/`; para juntar commits usar
  `git reset --soft $(git merge-base HEAD main)`, nunca `--soft main`. `git worktree remove` com
  "Filename too long" → `git -c core.longpaths=true worktree remove ...`.
- Patch com regex ou contrabarra vai por arquivo (Write/Edit), **nunca** `node -e`/`python -c`
  inline no Bash (o Git Bash come as contrabarras e gera código válido e errado).

## Git

- Commits em português, sem trailer `Co-Authored-By` e sem linha "Generated with Claude Code".
- Existe um pre-commit global com gitleaks em `C:\Users\olive\.git-hooks\pre-commit`
  (`core.hooksPath` global) que encadeia o hook local do repo. **Nunca usar `--no-verify`**:
  se o gitleaks travar, tirar o segredo do diff.
- Nunca copiar segredo, token, senha, chave de assinatura ou dado pessoal para arquivo
  versionado (inclusive este). Credencial fica no cofre, fora do repo.
