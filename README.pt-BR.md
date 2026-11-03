# Ware IoT

[English](README.md) · Português

App Android que transforma o celular na IHM de uma máquina. O usuário cadastra o equipamento,
dá nome às memórias que interessam e monta telas de operação com botões, lâmpadas, mostradores
e gráficos, sem programar.

## Status

Em produção: 1.4.0 na Google Play desde 21/10/2026 (Brasil, grátis). A 1.5.0 está pronta no
`main` e ainda não foi enviada à loja. Atualizado em 01/11/2026.
Feito para um cliente do setor de automação industrial, que publica o app e vende o hardware
de conexão. Site do produto: https://wareiot.com.br.

## O problema

Uma IHM de painel é cara e fica presa à máquina. Quem faz manutenção ou supervisão quer ver e
comandar a máquina de perto, pelo celular, sem instalar software de fabricante nem escrever
código. O Ware IoT fala direto com o CLP pela rede local ou por cabo.

## O que faz

- **Sete protocolos**, todos implementados no próprio app:
  Modbus TCP; Modbus RTU e ASCII (por gateway TCP ou cabo USB-OTG); Siemens S7; OPC UA
  (cliente próprio, modo sem criptografia); MQTT; TCP, UDP ou serial com interpretador de
  mensagens (Arduino); HTTP/HTTPS para API REST.
- **Mapas de memória prontos** de algumas marcas de CLP e inversor.
- **Variáveis com nome**: a tela aponta para "Velocidade", não para "HR 2". Também há variáveis
  calculadas a partir de outras.
- **Editor de telas** em grade (normal, fina e extra-fina) com 13 tipos de elemento, imagem de
  fundo (sinótico) e modelos de tela prontos.
- **Planta com vários projetos** (um por máquina), salva no aparelho; um projeto ou a planta
  inteira vai como arquivo para outro celular.
- **Alarmes** no padrão ISA-18.2 (prioridade por cor, forma e número), com aviso por voz no fone.
- **Receitas, registro periódico em SQLite com exportação CSV, regras entre máquinas** (só
  propõem; nunca são função de segurança) e **câmeras IP** (RTSP) ligadas à máquina.
- **Máquina de demonstração embutida**: o app funciona completo sem nada na rede.
- Tema claro e escuro, layout de tablet, tutorial em cada tela.

## Stack

Flutter e Dart (Android; `minSdk` do Flutter, `targetSdk` fixo em 36). As pilhas de protocolo
são próprias, sem biblioteca de Modbus, S7 ou OPC UA. O vídeo das câmeras usa o ExoPlayer
(Media3) direto em Kotlin. Site estático em `site/`. Simuladores em Python em `sim/`.

Dependências do `pubspec.yaml`:

| Pacote | Para quê |
|---|---|
| `path_provider` | pasta privada do app, onde mora a planta |
| `file_picker` | exportar e importar projeto, escolher imagem ou PDF |
| `shared_preferences` | marcas pequenas por aparelho (tutorial visto) |
| `logging` | logs da pilha de protocolo e do runtime |
| `sqflite` | registro periódico de variáveis |
| `mqtt_client` | cliente MQTT 3.1.1 |
| `flutter_tts` | avisos de alarme por voz |
| `flutter_secure_storage` | senhas de câmera e de HTTP no Keystore do Android |
| `printing` | transformar uma página de PDF em imagem (elemento imagem e fundo de tela) |
| `share_plus` | enviar projeto, planta, cópias, registros em CSV e foto de câmera |
| `in_app_update` | aviso de versão nova pela Play |
| `clock`, `flutter_localizations` | relógio testável e textos do Flutter em português |

Fontes IBM Plex (licença OFL) embutidas.

## Rodar localmente

```bash
flutter pub get
flutter run
```

O app abre com o projeto de demonstração (uma cortadora de rótulos simulada). No Windows, o
`flutter pub get` exige o Modo de Desenvolvedor ligado.

Para testar a rede sem hardware há simuladores em `sim/` (Modbus TCP, Arduino, HTTP); o passo
a passo está em `docs/SIMULACAO.md`.

## Testes

```bash
flutter test      # protocolos, sockets reais em localhost, codec, runtime, telas
flutter analyze   # tem de responder "No issues found"
```

Não há CI.

## Pastas

```
lib/
  main.dart     entrada e ciclo de vida
  app/          controlador da planta e do projeto, versão do app
  core/         pilhas de protocolo (modbus, s7, opcua, mqtt, http, rawlink, serial), tema
  models/       equipamento, variável, tela, projeto, planta
  services/     motor de execução, demonstração, armazenamento, registro, voz
  screens/      páginas do app e textos dos tutoriais
  widgets/      elementos de IHM e componentes comuns
android/        projeto Android (inclui o player de câmera e o vínculo com o Wi-Fi)
sim/            simuladores em Python
site/           site do produto (HTML e CSS estáticos)
test/           testes automatizados
tool/           geradores de ícone, documento Word, imagens da loja e vídeo
docs/           arquitetura, simulação, publicação, roadmap, histórico
```

## Arquitetura

Diagramas (casos de uso, processo, C4) em [docs/arquitetura/](docs/arquitetura/). A descrição
técnica completa está em [docs/ARQUITETURA.md](docs/ARQUITETURA.md). O que vem a seguir:
[docs/ROADMAP.md](docs/ROADMAP.md).

## Decisões e limites conhecidos

- O app nunca é função de segurança da máquina. Regras entre máquinas só propõem a ação.
- Sem comunicação, o valor fica esmaecido no último lido, nunca vira zero.
- Escopo: só o que vive dentro do app. Sem login, servidor, nuvem ou licenças.
- Nenhum protocolo novo (S7, OPC UA, MQTT, serial, HTTP, câmera) foi testado em equipamento
  real até 01/11/2026; só contra simuladores e servidores de teste.
- OPC UA só no modo sem criptografia; sem Subscription.
- Alarme só com o app aberto.
- `targetSdk` fixo em 36: subir quebra as conexões na rede local.
- A documentação interna está em português.

## Licença

Todos os direitos reservados. Publicado como portfólio; sem licença de reuso. Veja [LICENSE](LICENSE).
