// Conferência do site (site/) com Playwright, no Chrome instalado.
//
// Cada página em 360, 390 e 1280 px, nos temas claro e escuro:
//   • sem rolagem horizontal (nada passa da largura da tela);
//   • todas as imagens e fontes carregadas (inclusive as imagens preguiçosas,
//     rolando até o fim);
//   • alvo de toque com pelo menos 48 px no celular (link dentro de frase não
//     conta);
//   • link interno aponta para página que existe, e âncora para id que existe;
//   • título, descrição, canonical, Open Graph e lang="pt-BR";
//   • nenhum erro no console nem recurso faltando.
// Os marcadores que o dono ainda vai preencher (#LOJA-…, EMAIL_CONTATO,
// #WHATSAPP, #VIDEO-COMPLETO) são listados como aviso, não como falha.
//
// O site é servido por HTTP, como na Cloudflare: por file:// o Chrome bloqueia
// as fontes (CORS) e os caminhos de raiz da 404 ("/favicon.svg") não resolvem —
// a conferência mediria o site com a fonte errada.
//
// Uso (de tool/):  npm run conferir-site [-- pagina ...]
// Capturas em tool/site/saida/ (fora do git). Sai com código 1 se algo falhar.

const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const SITE = path.resolve(__dirname, '..', '..', 'site');
const SAIDA = path.resolve(__dirname, 'saida');
fs.mkdirSync(SAIDA, { recursive: true });

const pedidas = process.argv.slice(2);
const paginas = pedidas.length
  ? pedidas
  : fs.readdirSync(SITE).filter((f) => f.endsWith('.html')).map((f) => f.replace(/\.html$/, ''));

const vistas = [
  { nome: '360', width: 360, height: 760, celular: true },
  { nome: '390', width: 390, height: 844, celular: true },
  { nome: '1280', width: 1280, height: 800, celular: false },
];
const MARCADORES = /#LOJA-[A-Z0-9-]+|EMAIL_CONTATO|#WHATSAPP|#VIDEO-COMPLETO/g;

const TIPOS = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.webp': 'image/webp', '.jpg': 'image/jpeg',
  '.ico': 'image/x-icon', '.woff2': 'font/woff2', '.xml': 'application/xml', '.txt': 'text/plain',
};

// Endereço sem ".html" ("como-conectar"), como a Cloudflare Pages resolve.
function resolver(rel) {
  if (!path.extname(rel) && fs.existsSync(path.join(SITE, `${rel}.html`))) return `${rel}.html`;
  return rel;
}

function servir() {
  const server = http.createServer((req, res) => {
    let rel = decodeURIComponent(new URL(req.url, 'http://local').pathname);
    while (rel.startsWith('/')) rel = rel.slice(1);
    const arquivo = path.join(SITE, resolver(rel || 'index.html'));
    if (!arquivo.startsWith(SITE) || !fs.existsSync(arquivo) || fs.statSync(arquivo).isDirectory()) {
      res.writeHead(404, { 'content-type': TIPOS['.html'] });
      res.end(fs.readFileSync(path.join(SITE, '404.html')));
      return;
    }
    res.writeHead(200, { 'content-type': TIPOS[path.extname(arquivo)] || 'application/octet-stream' });
    res.end(fs.readFileSync(arquivo));
  });
  return new Promise((ok) => server.listen(0, '127.0.0.1', () => ok(server)));
}

const falhas = [];
const avisos = new Map();
const falhar = (onde, msg) => falhas.push(`${onde}: ${msg}`);
const existe = (arquivo) => fs.existsSync(path.join(SITE, arquivo));

(async () => {
  const server = await servir();
  const BASE = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ channel: 'chrome' });
  for (const tema of ['light', 'dark']) {
    for (const v of vistas) {
      const ctx = await browser.newContext({
        viewport: { width: v.width, height: v.height },
        deviceScaleFactor: v.celular ? 2 : 1,
        isMobile: v.celular,
        hasTouch: v.celular,
        colorScheme: tema,
      });
      for (const p of paginas) {
        const onde = `${p} · ${v.nome} · ${tema === 'light' ? 'claro' : 'escuro'}`;
        const page = await ctx.newPage();
        const erros = [];
        page.on('console', (m) => { if (m.type() === 'error') erros.push(m.text()); });
        page.on('pageerror', (e) => erros.push(String(e)));
        page.on('requestfailed', (r) => { if (r.url().startsWith(BASE)) erros.push(`não carregou ${r.url().slice(BASE.length)}`); });
        page.on('response', (r) => {
          // A própria 404 responde 404 de propósito.
          if (r.url().startsWith(BASE) && r.status() >= 400 && !(p === '404' && r.url().endsWith('/404.html'))) {
            erros.push(`${r.status()} em ${r.url().slice(BASE.length)}`);
          }
        });

        await page.goto(`${BASE}/${p}.html`);
        // Rola até o fim e volta: as imagens com loading="lazy" carregam.
        await page.evaluate(async () => {
          for (let y = 0; y < document.body.scrollHeight; y += 300) {
            window.scrollTo(0, y);
            await new Promise((r) => setTimeout(r, 25));
          }
          window.scrollTo(0, 0);
        });
        await page.evaluate(() => document.fonts.ready);
        await page.waitForTimeout(250);

        const m = await page.evaluate((celular) => {
          const r = { largo: [], imagens: [], fontes: [], pequenos: [], links: [], meta: {} };
          const vw = document.documentElement.clientWidth;
          if (document.documentElement.scrollWidth > vw + 1) r.largo.push(`página com ${document.documentElement.scrollWidth}px em ${vw}px`);
          for (const el of document.querySelectorAll('body *')) {
            const b = el.getBoundingClientRect();
            if (b.width === 0 || b.height === 0) continue;
            if (el.closest('details:not([open])') && !el.matches('details > summary, details > summary *')) continue;
            if (getComputedStyle(el).position === 'absolute' && el.closest('.pular')) continue;
            if (b.right > vw + 0.5 || b.left < -0.5) {
              const classe = el.className && typeof el.className === 'string' ? '.' + el.className.split(' ')[0] : '';
              r.largo.push(`${el.tagName.toLowerCase()}${classe} [${Math.round(b.left)}..${Math.round(b.right)}]`);
            }
          }
          for (const img of document.images) {
            if (!img.complete || img.naturalWidth === 0) r.imagens.push(img.getAttribute('src'));
          }
          for (const f of document.fonts) {
            if (f.status === 'error') r.fontes.push(`${f.family} ${f.weight}`);
          }
          if (celular) {
            for (const el of document.querySelectorAll('a, button, summary')) {
              const b = el.getBoundingClientRect();
              if (b.width === 0) continue;
              const display = getComputedStyle(el).display;
              // Link no meio de uma frase segue o tamanho do texto (WCAG 2.5.8, exceção "inline").
              if (display === 'inline' && el.closest('p, li, td, figcaption, small, dd')) continue;
              if (b.height < 47.5 || b.width < 47.5) {
                const nome = (el.textContent || el.getAttribute('aria-label') || '').trim().slice(0, 40);
                r.pequenos.push(`${el.tagName.toLowerCase()} "${nome}" ${Math.round(b.width)}×${Math.round(b.height)}`);
              }
            }
          }
          for (const a of document.querySelectorAll('a[href]')) r.links.push(a.getAttribute('href'));
          const q = (s) => document.querySelector(s);
          r.meta = {
            lang: document.documentElement.lang,
            titulo: document.title,
            descricao: (q('meta[name="description"]') || {}).content || '',
            canonical: (q('link[rel="canonical"]') || {}).href || '',
            og: (q('meta[property="og:title"]') || {}).content || '',
          };
          r.texto = document.documentElement.outerHTML;
          return r;
        }, v.celular);

        for (const x of m.largo.slice(0, 5)) falhar(onde, `passa da largura: ${x}`);
        for (const x of m.imagens) falhar(onde, `imagem não carregou: ${x}`);
        for (const x of m.fontes) falhar(onde, `fonte não carregou: ${x}`);
        for (const x of m.pequenos.slice(0, 5)) falhar(onde, `alvo de toque menor que 48 px: ${x}`);
        for (const x of erros) falhar(onde, `console: ${x}`);

        // Só uma vez por página: não depende do tamanho da tela nem do tema.
        if (tema === 'light' && v.nome === '390') {
          if (m.meta.lang !== 'pt-BR') falhar(p, `lang="${m.meta.lang}", esperado pt-BR`);
          if (!m.meta.titulo) falhar(p, 'sem <title>');
          if (p !== '404') {
            if (m.meta.descricao.length < 50) falhar(p, 'descrição curta ou ausente');
            if (!m.meta.canonical) falhar(p, 'sem canonical');
            if (!m.meta.og) falhar(p, 'sem og:title');
          }
          for (const href of new Set(m.links)) {
            if (/^(https?:|mailto:|tel:)/.test(href) || href.startsWith('#LOJA') || href === '#WHATSAPP' || href === '#VIDEO-COMPLETO') continue;
            const [bruto, ancora] = href.replace(/^\//, '').split('#');
            const arquivo = bruto ? resolver(bruto) : '';
            if (arquivo && !existe(arquivo)) { falhar(p, `link para página que não existe: ${href}`); continue; }
            if (ancora) {
              const alvo = arquivo ? fs.readFileSync(path.join(SITE, arquivo), 'utf8') : m.texto;
              if (!alvo.includes(`id="${ancora}"`) && !alvo.includes(`id='${ancora}'`)) falhar(p, `âncora que não existe: ${href}`);
            }
          }
          const marcas = m.texto.match(MARCADORES) || [];
          if (marcas.length) avisos.set(p, [...new Set(marcas)]);
        }

        const tag = tema === 'light' ? 'claro' : 'escuro';
        await page.screenshot({ path: path.join(SAIDA, `${tag}-${v.nome}-${p}.png`), fullPage: true });
        await page.close();
      }
      await ctx.close();
    }
  }
  await browser.close();
  server.close();

  console.log(`Site: ${paginas.length} páginas × 3 larguras × 2 temas = ${paginas.length * 6} conferências.`);
  if (avisos.size) {
    console.log('\nMarcadores para o dono preencher (aviso, não falha):');
    for (const [p, ms] of avisos) console.log(`  ${p}: ${ms.join(', ')}`);
  }
  if (falhas.length) {
    console.log(`\n${falhas.length} falha(s):`);
    for (const f of falhas) console.log('  ✗ ' + f);
    process.exit(1);
  }
  console.log(`\nTudo certo. Capturas em ${SAIDA}`);
})();
