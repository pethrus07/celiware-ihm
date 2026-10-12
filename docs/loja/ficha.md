# Ficha da Google Play — Ware IoT

Tudo o que vai em **Presença na loja → Ficha principal da loja** e em
**Configurações da loja**, pronto para colar. Os formulários de **Conteúdo do
app** estão em [`formularios.md`](formularios.md). O roteiro de publicação,
na ordem, está em [`../PUBLICACAO.md`](../PUBLICACAO.md).

Idioma da ficha: **português (Brasil) – pt-BR**, como idioma padrão.

Antes de subir qualquer texto ou imagem, rode o portão (confere limites de
caracteres, tamanhos, proporção, transparência e marcador esquecido):

```
python tool/loja/imagens_loja.py conferir
```

## Textos

O texto que se cola está nos arquivos `.txt` desta pasta: copiar do arquivo
evita levar formatação do Markdown para a loja.

| Campo do Console | Arquivo | Limite | Hoje |
|---|---|---|---|
| Nome do app | [`nome.txt`](nome.txt) | 30 | 8 |
| Descrição curta | [`descricao-curta.txt`](descricao-curta.txt) | 80 | 78 |
| Descrição completa | [`descricao-completa.txt`](descricao-completa.txt) | 4.000 | 3.728 |
| Notas da versão (no envio, não na ficha) | [`notas-da-versao.txt`](notas-da-versao.txt) | 500 | 386 |

**Nome:** `Ware IoT`. A Play aceita até 30 caracteres; um complemento
descritivo ("Ware IoT: IHM no celular", 24) ajuda na busca e não muda o nome
no aparelho, que vem do app (`android:label`). Decisão do cliente; o padrão
aqui é só a marca.

**Descrição curta:**

> A IHM da sua máquina no celular: monte telas e opere CLP e inversor pela rede.

**O que a descrição completa promete, e onde isso está no app** (conferido
contra `docs/ARQUITETURA.md` em 12/10/2026):

| Promessa | Onde |
|---|---|
| Demonstração que abre pronta, sem equipamento | §5.1 (`demo`), §6.8 "Demonstração" |
| 12 elementos | `ElementCatalog` (§6.3, §6.4) |
| 40 valores ou mais numa tela de celular | GR-8, `table_element_test` (46 e 44) |
| Valor ao vivo enquanto configura | §6.6 "Lendo agora" |
| Escala, texto ASCII, botão com retorno, troca de tela, imagem por etapa e PDF | §1.2 (versão 1.1), §4.12, §4.13 |
| Confirmação, só acompanhamento, limites, pulso que não prende | §1.3 |
| Testar conexão com o que conferir | §6.5, §4.14 |
| Notação de Inovance, INVT, WEG, Delta, MD500, GD20 | §6.6 "Memória do CLP"; **validação em bancada pendente** — por isso "confira com o manual do seu modelo" |
| Criar várias por faixa ou CSV | §6.6, IF-1 a IF-5 |
| RTU/ASCII por conversor ou cabo USB-OTG, S7, OPC UA, MQTT, cru | §4.15–4.20 (OPC UA só no modo None, conferido contra o asyncua); **nenhum testado em equipamento real** (o USB só com porta simulada) — por isso "novos nesta versão e ainda estão sendo conferidos" |
| ISA-18.2, faixa, marca, vibração, reconhecer, histórico | §6.8 |
| Voz no fone com fila e narração | §6.9 |
| Registro, gráfico e CSV | §6.10 |
| Receitas com comparação e uma confirmação | §6.11 |
| Calculadas e regras que perguntam antes | §6.12 |
| Câmeras IP por botão, senha no cofre | §5.7 e §6.14; **sem câmera de verdade ainda** (testado com câmera falsa e ffmpeg) — por isso "ainda em conferência" |
| Tutoriais, claro e escuro, tablet | §7, §8, §6.13 |
| Só com o app aberto; não é função de segurança (NR-12) | §6.8–6.12 "Limite desta versão"; §6.12 (PS-7) |
| Serial por conversor ou cabo USB-OTG | §4.15 e §4.20 (USB: `uses-feature` opcional, sem permissão nova; adaptador validado só com porta simulada) |

Ficou de fora de propósito: a correção do Wi-Fi sem internet com dados móveis
ligados (1.3.2) ainda não foi provada num celular de verdade; a descrição fala
só do que o "Testar conexão" mostra. A linha do serial já cita o cabo USB-OTG (12/10). **Quando as câmeras
entrarem, mudam a descrição, a política e o formulário de Segurança dos dados.**

### Palavras para busca

A Play não tem campo de palavras-chave: a busca lê o nome e as duas
descrições. Os termos que o público digita já aparecem no texto, cada um uma
ou duas vezes (repetir demais é motivo de recusa):

IHM · CLP · PLC · Modbus TCP · inversor · Inovance · INVT · WEG · Delta ·
Siemens S7 · OPC UA · MQTT · Arduino · ESP · RS-485 · alarmes · receitas · máquina ·
operador · tablet.

## Configurações da loja

| Campo | Valor |
|---|---|
| Tipo | App |
| Categoria | **Ferramentas** (alternativa: Empresas) |
| Tags | Até 5, escolhidas da lista do Console; as mais próximas de automação, monitoramento e ferramentas de trabalho |
| E-mail de contato | `EMAIL_CONTATO` (o mesmo do site; aparece na loja) |
| Telefone | opcional; deixar em branco |
| Site | o domínio do site publicado (`site/README.md`); enquanto não houver, `https://ware-iot.pages.dev` |
| Política de privacidade | `https://ware-iot.pages.dev/privacidade` (ou o domínio definitivo), **publicada antes do envio**. A mesma URL está em `AppInfo.privacyUrl` |
| Preço | Gratuito — **definitivo na Play** (ver `PUBLICACAO.md`, decisões) |
| Países | Brasil (a ficha é só pt-BR) |

## Imagens

| Peça | Exigência da Play | Arquivo |
|---|---|---|
| Ícone do app | 512 × 512, PNG 32 bits, até 1 MB | [`store/icone-512.png`](../../store/icone-512.png) (gerado por `tool/gerar_icone.py`) |
| Gráfico de recursos | 1024 × 500, JPEG ou PNG 24 bits, sem transparência | [`imagens/grafico-recursos.png`](imagens/grafico-recursos.png) |
| Capturas de celular | 2 a 8; lado de 320 a 3.840 px; o maior até 2× o menor; sem transparência | [`imagens/celular/`](imagens/celular/) — 8, em 1080 × 1920 (9:16) |
| Capturas de tablet 7" e 10" | as mesmas regras; até 8 cada | [`../imagens/tablet/`](../imagens/tablet/) — 5, em 2560 × 1600 e 1600 × 2560; servem para as duas seções |

Ordem das capturas de celular (a primeira é a que aparece na busca):

1. `01-operacao` — a cortadora em ciclo, com o selo Online.
2. `02-editor` — editor com um elemento selecionado.
3. `03-variavel-lendo-agora` — cadastro de variável lendo o valor ao vivo.
4. `04-alarme-na-tela` — faixa de alarme, botão "sem retorno" e marca no elemento.
5. `05-alarmes` — lista com as três prioridades.
6. `06-graficos` — tendência dos últimos 2 minutos e produção por hora.
7. `07-receitas` — comparação "na máquina × na receita".
8. `08-resumo-do-lider` — tela só de acompanhamento.

**Por que 1080 × 1920 e não a tela de um celular atual.** Celular de hoje é
20:9 (1080 × 2400): passa da proporção máxima de 2:1 e a Play recusa. As
capturas saem de um emulador com tela 9:16 (perfil `pixel_2`), que é o que a
Play recomenda para a vitrine.

**Como refazer as capturas** (quando a interface mudar):

1. AVD próprio com o perfil `pixel_2` (1080 × 1920, 420 dpi) e a imagem
   Android 36; pasta de AVD própria (`ANDROID_AVD_HOME`), porta própria.
2. `flutter build apk --release --target-platform android-x64` e instalar.
3. Tema escuro e barra de status limpa:
   `adb shell cmd uimode night yes`, `adb shell settings put system time_12_24 24`
   e o modo demonstração da SystemUI (`sysui_demo_allowed`; relógio na hora
   real, para bater com os horários dos alarmes; Wi-Fi cheio; sem notificações).
4. Na demonstração: pular os tutoriais; LIGA; velocidade 150 até os alarmes
   (≈ 40 s); reconhecer; velocidade 65 e RESET (segurar); capturar cada tela
   com `adb exec-out screencap -p` nos nomes `cel-*.png` de
   `tool/loja/imagens_loja.py`. O alarme não reconhecido pisca: tirar duas ou
   três e ficar com a de forma cheia.
5. `python tool/loja/imagens_loja.py capturas PASTA`, depois `grafico` e
   `conferir`. Apagar o AVD no fim.
