# Site do Ware IoT

Site do produto: HTML e CSS estáticos, sem framework e sem build; JavaScript
só como camada extra (o site funciona sem ele — ver "Herói vivo e 'Veja
funcionando'"). Mobile primeiro, tema claro e escuro pelo sistema, com as cores e a
fonte do app (`docs/ARQUITETURA.md` §8). Requisitos: `docs/REQUISITOS-ETAPA4.md` §6.

| Página | Arquivo | Endereço |
|---|---|---|
| Início | `index.html` | `/` |
| Como conectar (3 cenários + "Por que não conecta?") | `como-conectar.html` | `/como-conectar` |
| Recursos | `recursos.html` | `/recursos` |
| Tutoriais (equipamento, variável, tela, alarme) | `tutoriais.html` | `/tutoriais` |
| Política de privacidade (exigida pela Play) | `privacidade.html` | `/privacidade` |
| Contato | `contato.html` | `/contato` |
| Página de erro | `404.html` | qualquer endereço que não existe |

Outros arquivos: `css/site.css` (folha única), `fonts/` (IBM Plex, licença em
`fonts/OFL.txt`), `img/` (prints em WebP e a imagem de compartilhamento),
`favicon.svg`/`favicon.ico`/`apple-touch-icon.png`, `sitemap.xml`,
`robots.txt` e `_headers` (cabeçalhos e cache no Cloudflare Pages).

Ícones: `python tool/gerar_icone.py` regera `favicon.ico` e
`apple-touch-icon.png` e acerta a cor do arco em `favicon.svg` e no logo em SVG
de cada página — sempre o destaque do app (`accent` de
`lib/core/theme/app_theme.dart`), junto com os ícones do Android e da loja. A
imagem de compartilhamento (`img/compartilhar.jpg`) não tem gerador: o ícone
dela é o `store/icone-512.png` reduzido a 56 px, colado em x 80, y 84.

## Antes de publicar: trocar os marcadores

Os links que ainda não existem estão como **marcadores**. Até a troca, os
botões "Ver na loja" e o e-mail não levam a lugar nenhum.

| Marcador | Trocar por | Onde aparece |
|---|---|---|
| `#LOJA-INICIO` | página inicial da loja Shopify | menu e rodapé de todas as páginas, contato |
| `#LOJA-CONVERSOR` | produto: conversor RS-485/232 → Wi-Fi | início, como conectar |
| `#LOJA-ROTEADOR-4G` | produto: roteador 4G com VPN | início, como conectar |
| `#LOJA-REPETIDOR` | produto: repetidor Wi-Fi | início, como conectar |
| `EMAIL_CONTATO` | e-mail público (o mesmo cadastrado na Play) | privacidade, contato |
| `#WHATSAPP` | `https://wa.me/55` + DDD + número (opcional) | contato; sem WhatsApp, apague o bloco marcado no HTML |
| `https://ware-iot.pages.dev` | domínio definitivo, sem barra no fim | canonical, Open Graph, JSON-LD, `sitemap.xml`, `robots.txt` |
| `#VIDEO-COMPLETO` | link do vídeo de apresentação completo (3 min) no YouTube | herói do início ("Vídeo completo · 3 min") |

O link da Google Play já é o definitivo
(`https://play.google.com/store/apps/details?id=com.celiware.ihm`); passa a
funcionar quando o app for publicado.

**Medição (UTM).** Cada link da loja já leva o rastreio depois do marcador:
`#LOJA-CONVERSOR?utm_source=site&utm_medium=<página>&utm_campaign=ware-iot&utm_content=<posição>`.
Troque só o marcador, por um endereço **sem `?`**. Se o endereço do produto já
tiver `?`, troque o `?` do rastreio por `&` nesses links. Os links da Play levam
o mesmo rastreio no parâmetro `referrer` (aparece no Play Console, em Aquisição).

**Instituto Automação** (item 184 da lista do cliente). Um link discreto,
"Quero aprender automação", no fim das perguntas do início e no fim dos
tutoriais, para `https://institutoautomacao.com.br/` com o mesmo rastreio
(`utm_campaign=ware-iot`, `utm_medium` = página, `utm_content` = posição). Já é o
endereço definitivo: não há marcador para trocar.

**Nunca escreva preço nem nome comercial de produto no site.** O preço fica na
loja. Os cartões usam descrições genéricas de propósito.

### Trocar tudo de uma vez (PowerShell 7, na raiz do repositório)

Preencha os valores e rode:

```powershell
$troca = [ordered]@{
  '#LOJA-INICIO'               = 'https://LOJA/'
  '#LOJA-CONVERSOR'            = 'https://LOJA/products/CONVERSOR'
  '#LOJA-ROTEADOR-4G'          = 'https://LOJA/products/ROTEADOR'
  '#LOJA-REPETIDOR'            = 'https://LOJA/products/REPETIDOR'
  'EMAIL_CONTATO'              = 'contato@DOMINIO'
  '#WHATSAPP'                  = 'https://wa.me/55DDDNUMERO'
  '#VIDEO-COMPLETO'            = 'https://www.youtube.com/watch?v=VIDEO'
  'https://ware-iot.pages.dev' = 'https://DOMINIO'
}
Get-ChildItem site -Recurse -Include *.html, *.xml, *.txt | ForEach-Object {
  $texto = Get-Content $_ -Raw -Encoding utf8
  foreach ($k in $troca.Keys) { $texto = $texto.Replace($k, $troca[$k]) }
  Set-Content $_ $texto -Encoding utf8 -NoNewline
}
```

Conferir se sobrou algum:

```powershell
Select-String -Path site\*.html, site\*.xml, site\*.txt -Pattern '#LOJA-|EMAIL_CONTATO|#WHATSAPP|#VIDEO-COMPLETO|ware-iot\.pages\.dev'
```

(Os comentários no topo de cada página citam os marcadores; tudo bem se
aparecerem só ali.)

## Herói vivo e "Veja funcionando" (13/10/2026)

O único JavaScript desta parte é `js/demo.js` (com `css/demo.css`, ligado no
`<head>` do início e de Recursos). Sem JavaScript, tudo continua: o print no
herói e os vídeos com os controles do navegador.

**Herói interativo (início).** O `demo.js` troca o print `img/operacao.webp`
(que fica no HTML como reserva) por uma réplica em HTML da tela "Cortadora —
operação" da máquina de demonstração, com as cores do tema escuro do app e as
medidas do próprio print (1em = 10 px do print; a tela escala com o celular por
container query). O comportamento segue `lib/services/demo/demo_process.dart`,
com o tempo acelerado: LIGA fica **aguardando** (borda e ampulheta) ~0,6 s e
acende quando a máquina confirma (EM CICLO); a velocidade sobe em rampa até 80
m/min, a produção conta, o motor esquenta com a velocidade. Acima de 75 °C
chega sozinho o alarme "Motor esquentando" (prioridade 3, quadrado); o botão
**Simular alarme**, abaixo do celular, superaquece o motor: "Motor
superaquecido" (prioridade 1, losango), a máquina para, o LIGA fica aguardando
e, depois de 5 s, **SEM RETORNO**; "Máquina parada: dê Reset" (prioridade 2,
triângulo). Cada alarme chega na faixa do topo com forma e número e o
visitante toca **Reconhecer**; o RESET só limpa abaixo de 80 °C e a máquina
volta. Etiqueta abaixo do celular: "Simulação — no app, os valores vêm do
CLP". Acessível: LIGA, RESET, Reconhecer e Simular alarme são `<button>` com
nome e foco visível, todos com 48 px ou mais (LIGA/RESET ~76 px em 360 px de
tela); as mudanças de estado são anunciadas numa região `aria-live`. Com
`prefers-reduced-motion`, nada pisca nem anima e os valores mudam em degraus de
1 s. A simulação para quando sai da tela ou a aba fica escondida.

**Trechos de vídeo (Recursos).** Três loops mudos, só a tela do celular
recortada do vídeo de apresentação, um em cada bloco (no lugar de um dos dois
prints): `video/ligar` (Operar, 10 s: toca em LIGA, confirma, acende),
`video/alarme` (Alarmes, 10,5 s: a porta abre, a faixa "Porta aberta"
chega e volta ao normal — o vídeo não mostra ninguém tocando em Reconhecer; o
reconhecer está no herói) e `video/montar` (Monte a tela, 11,4 s, 1,4×: lâmpada
e botão escolhidos e já funcionando). `preload="none"` + capa WebP; tocam
quando aparecem (IntersectionObserver) e param quando saem; botão de
pausa/tocar de 48 px; com `prefers-reduced-motion` não tocam sozinhos. WebM só
onde ficou menor que o MP4 (ligar e montar). Pesos: ligar 159 KB (MP4) / 138 KB
(WebM), alarme 106 KB, montar 303 KB / 222 KB; capas 11–18 KB. Para refazer:
`python tool/video/trechos_site.py` (lê `tool/video/saida/ware-iot-apresentacao.mp4`,
que fica fora do git). O vídeo completo (12 MB) não vai para o site: o link
"Vídeo completo · 3 min" usa o marcador `#VIDEO-COMPLETO` (tabela acima), para
o YouTube.

**Medido (13/10, Lighthouse 12.8 celular, servidor local):** início 99 / 100 /
100 / 100 (LCP 2,0 s, CLS 0, TBT 10 ms, 234 KB); Recursos 100 / 100 / 100 / 100
(LCP 1,9 s, CLS 0, 256 KB — os vídeos só baixam quando aparecem).
`demo.js` 19 KB (6,7 KB com gzip), `demo.css` 20 KB (5,6 KB com gzip).

## Publicar no Cloudflare Pages

Arquivos estáticos são grátis e sem limite de acesso no plano gratuito; o custo
é só o domínio.

**Pelo Git (recomendado).** Cloudflare → Workers & Pages → Criar → Pages →
Conectar ao Git → este repositório.

- Branch de produção: `main`
- Framework: *None*
- Comando de build: vazio
- Diretório de saída: `site`

Cada push na `main` publica sozinho. Nomeando o projeto `ware-iot`, o endereço
provisório é `https://ware-iot.pages.dev` (o mesmo dos marcadores). Se o nome
estiver ocupado, troque o domínio nos arquivos (tabela acima).

**Sem Git.** Envio direto da pasta, pela linha de comando:

```bash
npx wrangler pages deploy site --project-name ware-iot
```

**Domínio próprio.** No projeto: Custom domains → Set up a domain. Depois
troque `https://ware-iot.pages.dev` nos arquivos e publique de novo.

O Pages serve `como-conectar.html` em `/como-conectar`; os links internos já
usam esse formato. A `404.html` aparece sozinha em endereços que não existem.

## Depois de publicar

1. Abrir `/privacidade` no celular e conferir o e-mail.
2. Colocar `https://DOMINIO/privacidade` no Play Console (Política de
   privacidade) e no app (Mais → Sobre). A Play exige a página no ar antes do envio.
3. Enviar o `sitemap.xml` no Google Search Console (opcional).
4. Quando o app estiver na Play, dá para trocar o selo textual "Baixar grátis na
   Google Play" pelo selo oficial do Google (gerador de selos da Play, para
   parceiros), mantendo o mesmo link.

## Como foi feito e medido (11/10/2026)

- **Prints (refeitos em 12/10/2026, build 1.4.0+11):** todos capturados no
  emulador (perfil Pixel 7, 1080×2400, Android 16, tema escuro, relógio 24 h,
  barra de status no modo demonstração), com a máquina de demonstração.
  Reduzidos à metade (540×1200, Lanczos) e gravados em WebP qualidade 80 com
  Pillow; os mesmos 540×1200 em PNG vão para `docs/imagens/`. Três novos:
  `nova-tela-modelo` (folha "Começar de" com os modelos), `procurar-rede`
  (achados do simulador `sim/simulador.py` rodando no PC, visto pelo emulador
  em 10.0.2.2, portas 502 e 5020) e `oee` (tela de teste "OEE da cortadora":
  OEE calculado no app a partir de três variáveis calculadas — disponibilidade
  `se([Velocidade] > 0; 92,5; 0)`, desempenho `[Velocidade] × 100 ÷ 75`,
  qualidade `98 − abs([Tensão do papel] − 62) ÷ 4` — com a máquina a 65 m/min).
  Imagem de compartilhamento: 1200×630, JPEG (não refeita).
- **Fontes:** IBM Plex Sans (400 e 600) e Sans Condensed (600), recortes
  Latin1 oficiais da IBM (`@ibm/plex-sans` e `@ibm/plex-sans-condensed`
  1.1.0), servidas pelo próprio site. Nenhuma requisição a terceiros.
- **Visual (13/10/2026):** o topo de cada página, a galeria, as chamadas
  finais e o rodapé ficam num "palco" escuro com brilho verde-água e a grade
  de pontos do editor do app, nos dois temas (classe `.palco`, que redefine
  os tokens de cor por dentro); o resto alterna fundo claro e uma faixa
  tingida. No herói, um segundo print atrás e dois selos soltos aparecem só a
  partir de 960 px. Tudo em CSS, sem imagem nova. Próximos passos de
  conversão: `docs/ROADMAP.md`, seção "Site — conversão".
- **Peso transferido** (Lighthouse, 13/10, depois do palco): início 258 KB,
  Recursos 319 KB, Tutoriais 244 KB, Como conectar 111 KB. Em 11/10, antes do
  palco, a home tinha cerca de 210 KB sem compressão, com todas as imagens
  (limite: 500 KB). A primeira dobra fica perto de 130 KB.
- **Lighthouse 12.8 (celular), servidor local, 13/10, depois do palco:** 98–99 em Desempenho
  (LCP 1,8–2,4 s, CLS 0) e 100 em Acessibilidade, Boas práticas e SEO no início,
  Recursos, Tutoriais e Como conectar. Em 11/10, antes do palco: 99–100 em Desempenho e 100 em
  Acessibilidade, Boas práticas e SEO, nas seis páginas; LCP entre 1,6 e 2,1 s.
- **Sem rolagem horizontal** em 360 e 390 px; alvos de toque com 48 px ou mais
  (exceto links dentro de frases).
