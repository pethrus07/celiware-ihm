/* Ware IoT — demonstração viva do herói e trechos "Veja funcionando".
 *
 * 1. Herói (index): troca o print da tela de operação por uma réplica em
 *    HTML da "Cortadora — operação" da máquina de demonstração do app, com o
 *    mesmo comportamento de lib/services/demo/demo_process.dart (tempo
 *    acelerado): LIGA aguarda e acende quando a máquina confirma, a velocidade
 *    sobe em rampa, a produção conta, o motor esquenta com a velocidade;
 *    acima de 75 °C alarme baixo, acima de 85 °C alarme alto e a máquina para;
 *    o Reset só limpa abaixo de 80 °C. Sem JavaScript, o print continua.
 * 2. Trechos de vídeo (recursos): tocam quando aparecem na tela e param quando
 *    saem; botão de pausa; com prefers-reduced-motion, só tocam no botão.
 */
(() => {
  'use strict';
  const reduz = window.matchMedia('(prefers-reduced-motion: reduce)');
  const temIO = 'IntersectionObserver' in window;

  /* ── 1. Herói ─────────────────────────────────────────────────────────── */
  const host = document.querySelector('[data-demo]');
  const print = host && host.querySelector('img');
  if (print) {
    const num = (v, d = 0) => v.toLocaleString('pt-BR', { minimumFractionDigits: d, maximumFractionDigits: d, useGrouping: false });
    const hhmm = (t) => t.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
    // Coordenadas em "pixels do print" (540 de largura): 1em = 10 px do print.
    const box = (x, y, w, h) => `style="left:${x / 10}em;top:${y / 10}em;width:${w / 10}em;height:${h / 10}em"`;

    // Medidor: 240° a partir de 150°, como o _GaugePainter do app.
    const G = { cx: 117, cy: 137, r: 74 };
    const ponto = (f, r) => {
      const a = (150 + 240 * f) * Math.PI / 180;
      return [G.cx + r * Math.cos(a), G.cy + r * Math.sin(a)];
    };
    const arco = (f0, f1, r) => {
      const [x0, y0] = ponto(f0, r), [x1, y1] = ponto(f1, r);
      return `M${x0.toFixed(1)} ${y0.toFixed(1)}A${r} ${r} 0 ${(f1 - f0) * 240 > 180 ? 1 : 0} 1 ${x1.toFixed(1)} ${y1.toFixed(1)}`;
    };
    let marcas = '';
    for (let i = 0; i <= 20; i++) {
      const maior = i % 5 === 0;
      if (!maior && i % 2) continue; // régua: 10 divisões, as de 25% mais longas
      const [a, b] = ponto(i / 20, 62), [c, d] = ponto(i / 20, maior ? 51 : 56);
      marcas += `<line x1="${a.toFixed(1)}" y1="${b.toFixed(1)}" x2="${c.toFixed(1)}" y2="${d.toFixed(1)}" stroke-width="${maior ? 2.2 : 1.4}"/>`;
    }

    const lampada = (id, x, y, w, h, rotulo) =>
      `<div class="dm-card dm-lamp dm-lamp--linha" data-el="${id}" ${box(x, y, w, h)}><span class="dm-rot">${rotulo}</span><i></i><b></b></div>`;

    const html = `
<div class="dm-tela" aria-hidden="true">
  <div class="dm-sb"><span data-v="hora"></span><svg viewBox="0 0 48 16"><path d="M2 5a12 12 0 0 1 16 0l-8 9z"/><path d="M24 14 34 3v11z"/><rect x="38" y="2" width="7" height="12" rx="1.5"/></svg></div>
  <div class="dm-faixa" data-v="faixa">
    <span class="dm-forma" data-v="forma"></span>
    <span class="dm-faixa__txt"><b data-v="msg">Sem alarmes</b><small data-v="sub"></small></span>
    <span class="dm-mais" data-v="mais"></span>
    <svg class="dm-seta" viewBox="0 0 24 24"><path d="m9 6 6 6-6 6"/></svg>
  </div>
  <div class="dm-titulo"><svg viewBox="0 0 24 24"><path d="M20 12H5m6-6-6 6 6 6"/></svg><b>Cortadora — operação</b><svg viewBox="0 0 24 24"><path d="m4 20 1-4L16 5l3 3L8 19z"/></svg><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.3-1 .8-1 1.5v.7M12 17h.01"/></svg></div>
  <div class="dm-online"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><path d="m7.5 12.5 3 3 6-6.5"/></svg>Online · <span data-v="ms">72</span> ms</div>

  <div class="dm-card dm-estado" data-el="status" ${box(27, 305, 234, 150)}><span class="dm-rot">Status</span><i><svg class="dm-s0" viewBox="0 0 24 24"><path d="M9 7v10M15 7v10"/></svg><svg class="dm-s1" viewBox="0 0 24 24"><path d="M9 6.5v11l9-5.5z"/></svg><svg class="dm-s2" viewBox="0 0 24 24"><path d="M12 7v6M12 16.5v.5"/></svg></i><b data-v="status">PARADA</b></div>
  <div class="dm-card dm-valor" ${box(278, 305, 235, 150)}><span class="dm-rot">Velocidade</span><b data-v="vel">0</b><small>m/min</small></div>
  <div class="dm-card dm-lamp dm-lamp--alarme" data-el="lampAlarme" ${box(362, 472, 151, 150)}><span class="dm-rot">Alarme</span><i></i><b></b></div>
  <div class="dm-card dm-ajuste" ${box(27, 640, 234, 150)}><span class="dm-rot">Ajuste de velocidade</span><b>80</b><small>m/min</small><span class="dm-lapis"><svg viewBox="0 0 24 24"><path d="m4 20 1-4L16 5l3 3L8 19z"/></svg></span></div>
  <div class="dm-card dm-valor" ${box(278, 640, 235, 150)}><span class="dm-rot">Produção</span><b data-v="prod">18240</b><small>un</small><svg class="dm-ir" viewBox="0 0 24 24"><path d="M7 17 17 7M9 7h8v8"/></svg></div>
  <div class="dm-card dm-medidor" data-el="motor" ${box(27, 808, 234, 234)}><span class="dm-rot">Motor</span>
    <svg viewBox="0 0 234 234">
      <path class="dm-g-poco" d="${arco(0, 1, G.r)}"/>
      <path class="dm-g-aviso" d="${arco(0.75, 0.85, G.r + 15)}"/>
      <path class="dm-g-alarme" d="${arco(0.85, 1, G.r + 15)}"/>
      <g class="dm-g-marcas">${marcas}</g>
      <path class="dm-g-valor" data-v="garco" d="${arco(0, 1, G.r)}" pathLength="100"/>
      <line class="dm-g-agulha" data-v="agulha"/>
    </svg>
    <b data-v="temp">32,0 °C</b></div>
  ${lampada('porta', 278, 808, 235, 67, 'Porta')}
  ${lampada('faca', 278, 892, 235, 67, 'Faca')}
  ${lampada('papel', 278, 976, 235, 66, 'Papel')}
  <div class="dm-card dm-barra" ${box(27, 1060, 486, 66)}><span class="dm-rot">Tensão do papel</span><span class="dm-trilho"><i data-v="tensao"></i></span><b data-v="tensaoTxt">48 %</b></div>
  <div class="dm-card dm-tend" ${box(27, 1143, 486, 120)}><span class="dm-rot">Últimos 2 minutos</span><small><i></i>Velocidade: <b data-v="lvel">0 m/min</b> <i></i>Temperatura do motor: <b data-v="ltemp">32,0 °C</b></small></div>
  <span class="dm-gesto"></span>
</div>
<button type="button" class="dm-botao dm-liga" data-acao="liga" ${box(27, 472, 151, 150)}><span class="dm-led"></span><b>Liga</b><span class="dm-dica"></span></button>
<button type="button" class="dm-botao dm-reset" data-acao="reset" aria-label="Reset de alarme (pulso)" ${box(194, 472, 151, 150)}><span class="dm-led"></span><b>Reset</b><span class="dm-dica"><svg viewBox="0 0 24 24"><path d="M9 11V6.5a1.5 1.5 0 0 1 3 0V11m0-1.5a1.5 1.5 0 0 1 3 0V11m0-.5a1.5 1.5 0 0 1 3 0v4.5a5 5 0 0 1-5 5h-1.2a5 5 0 0 1-4-2L5 15.6a1.5 1.5 0 0 1 2.3-1.9L9 15"/></svg></span></button>
<button type="button" class="dm-reconhecer" data-acao="reconhecer" hidden><span>Reconhecer</span></button>
<p class="dm-falado" aria-live="polite"></p>`;

    const demo = document.createElement('div');
    demo.className = 'dm';
    demo.setAttribute('role', 'group');
    demo.setAttribute('aria-label', 'Simulação da tela de operação do Ware IoT: máquina cortadora de demonstração');
    demo.innerHTML = html;

    const barra = document.createElement('div');
    barra.className = 'dm-controles';
    barra.innerHTML = '<p class="dm-etiqueta">Simulação — no app, os valores vêm do CLP.</p>'
      + '<button type="button" class="dm-simular" data-acao="simular">Simular alarme</button>';

    const el = (s) => demo.querySelector(`[data-el="${s}"]`);
    const v = {};
    for (const n of demo.querySelectorAll('[data-v]')) v[n.dataset.v] = n;
    const liga = demo.querySelector('.dm-liga');
    const reset = demo.querySelector('.dm-reset');
    const reconhecer = demo.querySelector('.dm-reconhecer');
    const simular = barra.querySelector('.dm-simular');
    const falado = demo.querySelector('.dm-falado');
    const P = { 1: 'alta', 2: 'média', 3: 'baixa' };

    // Estado do "CLP" (DemoMap) e do app.
    const m = {
      cmd: false, ciclo: false, porta: true, cod: 0, vel: 0, sp: 80, temp: 32, prod: 18240, tensao: 48,
      faca: 0, aquecer: false, confirmaEm: 0, aguardaDesde: 0, resetAte: 0,
    };
    const regras = [
      { p: 1, msg: 'Motor superaquecido', el: 'motor', se: () => m.temp > 85 },
      { p: 2, msg: 'Máquina parada: dê Reset', el: 'lampAlarme', se: () => m.cod !== 0 },
      { p: 3, msg: 'Motor esquentando', el: 'motor', se: () => m.temp > 75 },
    ];
    let alarmes = []; // { r, ativo, visto, desde }
    let ultimo = performance.now(), pisca = false, falaAnterior = '';

    const falar = (t) => { if (t && t !== falaAnterior) { falaAnterior = t; falado.textContent = t; } };

    // Um ciclo de varredura, como DemoProcess.step (tempo acelerado ~10×).
    function passo(dt, agora) {
      if (agora >= m.resetAte && m.resetAte) {
        m.resetAte = 0;
        if (m.cod === 1 && m.temp < 80) m.cod = 0;
      }
      const run = m.cmd && agora >= m.confirmaEm; // a ordem chega ao CLP no ciclo seguinte
      m.ciclo = run && m.porta && m.cod === 0;
      const alvo = m.ciclo ? m.sp : 0;
      m.vel += Math.max(-25 * dt, Math.min(25 * dt, alvo - m.vel));
      if (Math.abs(m.vel) < 0.05) m.vel = 0;
      m.prod += m.vel * 1000 / 120 / 60 * dt;
      if (m.aquecer) {
        m.temp += 16 * dt;
        if (m.temp > 92) m.aquecer = false;
      } else {
        const t = 32 + m.vel * 0.62;
        m.temp += (t - m.temp) * Math.min(1, dt / (t > m.temp ? 4 : 15)) + (Math.random() - 0.5) * 0.06;
      }
      if (m.temp > 85) m.cod = 1;
      m.tensao += ((m.ciclo ? 62 : 48) - m.tensao) * Math.min(1, dt * 1.2) + (Math.random() - 0.5) * 0.8;
      if (m.ciclo) m.faca += dt;

      // Alarmes (AlarmEngine): entra não reconhecido; some só depois de normalizar E ser reconhecido.
      for (const r of regras) {
        const ativo = r.se();
        let a = alarmes.find((x) => x.r === r);
        if (ativo && !a) {
          alarmes.push(a = { r, ativo, visto: false, desde: new Date() });
          falar(`Alarme de prioridade ${r.p}, ${P[r.p]}: ${r.msg}.`);
        } else if (a) {
          if (ativo && !a.ativo) a.visto = false;
          a.ativo = ativo;
        }
      }
      alarmes = alarmes.filter((a) => a.ativo || !a.visto).sort((a, b) => a.r.p - b.r.p || a.desde - b.desde);
    }

    const forma = (p, cheia) => {
      const f = p === 1 ? '<path d="M15 1.5 28.5 15 15 28.5 1.5 15z"/>'
        : p === 2 ? '<path d="M15 3 28 26H2z"/>' : '<rect x="3.5" y="3.5" width="23" height="23" rx="4"/>';
      return `<svg viewBox="0 0 30 30" class="dm-p${p}${cheia ? ' dm-cheia' : ''}">${f}<text x="15" y="${p === 2 ? 22.5 : 19.5}">${p}</text></svg>`;
    };

    function desenha(agora) {
      v.hora.textContent = hhmm(new Date());
      const status = m.cod ? 2 : m.ciclo ? 1 : 0;
      v.status.textContent = ['PARADA', 'EM CICLO', 'ALARME'][status];
      el('status').dataset.s = status;
      v.vel.textContent = num(Math.round(m.vel));
      v.prod.textContent = num(Math.floor(m.prod));
      v.temp.textContent = `${num(m.temp, 1)} °C`;
      v.lvel.textContent = `${num(Math.round(m.vel))} m/min`;
      v.ltemp.textContent = `${num(m.temp, 1)} °C`;
      const tensao = Math.max(0, Math.min(100, Math.round(m.tensao)));
      v.tensao.style.width = `${tensao}%`;
      v.tensaoTxt.textContent = `${tensao} %`;

      // Medidor: arco até o valor, na cor da zona; agulha atravessando o arco.
      const f = Math.max(0, Math.min(1, m.temp / 100));
      v.garco.style.strokeDasharray = `${f * 100} 200`;
      v.garco.style.opacity = f > 0.001 ? 1 : 0;
      const zona = m.temp >= 85 ? 'alarme' : m.temp >= 75 ? 'aviso' : '';
      el('motor').dataset.z = zona;
      const [x1, y1] = ponto(f, G.r - 20), [x2, y2] = ponto(f, G.r + 14);
      Object.entries({ x1, y1, x2, y2 }).forEach(([k, n]) => v.agulha.setAttribute(k, n.toFixed(1)));

      // Lâmpadas.
      const lamp = (id, on, sim, nao) => { const e = el(id); e.dataset.on = on ? 1 : 0; e.querySelector('b').textContent = on ? sim : nao; };
      lamp('lampAlarme', m.cod !== 0, 'ATIVO', 'OK');
      lamp('porta', m.porta, 'FECHADA', 'ABERTA');
      lamp('faca', m.ciclo && m.vel > 1 && (reduz.matches || Math.floor(m.faca / 0.4) % 2 === 0), 'CORTANDO', 'PARADA');
      lamp('papel', true, 'PRESENTE', 'FALTA');

      // LIGA com retorno: acende pelo "Em ciclo"; ligado sem retorno = aguardando; 5 s = sem retorno.
      const aguarda = m.cmd && !m.ciclo;
      if (aguarda && !m.aguardaDesde) m.aguardaDesde = agora;
      if (!aguarda) m.aguardaDesde = 0;
      const semRetorno = aguarda && agora - m.aguardaDesde > 5000;
      liga.dataset.s = m.ciclo ? 'aceso' : semRetorno ? 'sem' : aguarda ? 'aguarda' : '';
      liga.querySelector('.dm-dica').textContent = semRetorno ? 'SEM RETORNO' : '';
      const nome = `Liga: ${m.ciclo ? 'ligado, a máquina confirmou' : semRetorno ? 'ligado, sem retorno da máquina' : aguarda ? 'aguardando a máquina confirmar' : 'desligado'}`;
      if (liga.getAttribute('aria-label') !== nome) liga.setAttribute('aria-label', nome);
      reset.dataset.s = m.resetAte ? 'aceso' : '';

      // Marca de alarme no elemento: forma e número; borda na cor enquanto ativo.
      for (const id of ['motor', 'lampAlarme']) {
        const e = el(id), a = alarmes.find((x) => x.r.el === id);
        e.dataset.p = a && a.ativo ? a.r.p : '';
        let badge = e.querySelector('.dm-badge');
        if (!a) { if (badge) badge.remove(); continue; }
        if (!badge) { badge = document.createElement('span'); badge.className = 'dm-badge'; e.append(badge); }
        if (badge.dataset.p !== String(a.r.p)) { badge.dataset.p = a.r.p; badge.innerHTML = forma(a.r.p, true); }
      }

      // Faixa do topo (AlarmBannerHost): o mais grave não reconhecido; senão o mais grave; senão "Sem alarmes".
      const naoVistos = alarmes.filter((a) => !a.visto);
      const topo = naoVistos[0] || alarmes[0];
      const faixa = v.faixa;
      if (!topo) {
        faixa.dataset.p = '';
        faixa.dataset.alto = '';
        v.forma.innerHTML = '<svg viewBox="0 0 24 24" class="dm-sino"><path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15zM10 20.5h4"/></svg>';
        v.msg.textContent = 'Sem alarmes';
        v.sub.textContent = '';
        v.mais.textContent = '';
        reconhecer.hidden = true;
        faixa.dataset.rec = '';
      } else {
        const fase = !topo.ativo ? 'Voltou ao normal' : topo.visto ? 'Reconhecido' : 'Não reconhecido';
        faixa.dataset.p = topo.r.p;
        faixa.dataset.alto = naoVistos.length && topo.ativo ? 1 : '';
        v.forma.innerHTML = forma(topo.r.p, topo.visto || reduz.matches || pisca);
        v.msg.textContent = topo.r.msg;
        v.sub.textContent = `${fase} · desde ${hhmm(topo.desde)}`;
        v.mais.textContent = alarmes.length > 1 ? `+${alarmes.length - 1}` : '';
        reconhecer.hidden = topo.visto;
        faixa.dataset.rec = topo.visto ? '' : 1;
        reconhecer.setAttribute('aria-label', `Reconhecer o alarme ${topo.r.msg}, prioridade ${topo.r.p}`);
      }
      if (m.ciclo !== desenha.ciclo) {
        if (desenha.ciclo !== undefined) falar(m.ciclo ? 'A máquina confirmou: em ciclo.' : m.cod ? 'A máquina parou por alarme.' : 'Máquina parada.');
        desenha.ciclo = m.ciclo;
      }
    }

    // Relógio: 200 ms como o tick do DemoProcess; com movimento reduzido,
    // a tela muda em degraus de 1 s. Para fora da tela e com a aba escondida.
    let timer = 0, visivel = !temIO, contador = 0;
    function tique() {
      const agora = performance.now();
      const dt = Math.min(0.5, (agora - ultimo) / 1000);
      ultimo = agora;
      passo(dt, agora);
      pisca = !pisca;
      if (++contador % 5 === 0) v.ms.textContent = 60 + Math.floor(Math.random() * 20);
      if (!reduz.matches || contador % 5 === 0) desenha(agora);
    }
    function liga_relogio() {
      const roda = visivel && !document.hidden;
      if (roda && !timer) { ultimo = performance.now(); timer = setInterval(tique, 200); }
      if (!roda && timer) { clearInterval(timer); timer = 0; }
    }
    const agir = (acao) => {
      const agora = performance.now();
      if (acao === 'liga') {
        demo.classList.add('dm--tocou');
        m.cmd = !m.cmd;
        m.confirmaEm = agora + 600;
        if (m.cmd) falar('Ligar enviado. Aguardando a máquina confirmar.');
      } else if (acao === 'reset') {
        m.resetAte = agora + 300;
        if (m.cod === 1 && m.temp >= 80) falar('O Reset só limpa o alarme abaixo de 80 °C.');
      } else if (acao === 'reconhecer') {
        const a = alarmes.find((x) => !x.visto);
        if (a) { a.visto = true; falar(`Reconhecido: ${a.r.msg}.`); }
        alarmes = alarmes.filter((x) => x.ativo || !x.visto);
        if (!alarmes.some((x) => !x.visto)) liga.focus();
      } else if (acao === 'simular') {
        m.aquecer = true;
        falar('Simulando: o motor está esquentando rápido.');
      }
      desenha(agora);
    };
    demo.addEventListener('click', (e) => { const b = e.target.closest('[data-acao]'); if (b) agir(b.dataset.acao); });
    simular.addEventListener('click', () => agir('simular'));

    print.replaceWith(demo);
    host.classList.add('celular--demo');
    (host.closest('.heroi__aparelhos') || host).after(barra);
    const linkVideo = document.querySelector('.heroi__video');
    if (linkVideo) barra.append(linkVideo);
    desenha(performance.now());
    if (temIO) new IntersectionObserver((es) => { visivel = es[0].isIntersecting; liga_relogio(); }).observe(demo);
    document.addEventListener('visibilitychange', liga_relogio);
    liga_relogio();
  }

  /* ── 2. Trechos de vídeo ──────────────────────────────────────────────── */
  const lacos = document.querySelectorAll('.laco');
  if (!lacos.length) return;
  const io = temIO && new IntersectionObserver((es) => {
    for (const e of es) {
      const l = e.target;
      l.naTela = e.isIntersecting;
      if (l.naTela && !l.pausadoPelaPessoa && !reduz.matches) tocar(l);
      else if (!l.naTela) l.video.pause();
    }
  }, { threshold: 0.35 });
  function tocar(l) {
    const p = l.video.play();
    if (p) p.catch(() => {});
  }
  for (const l of lacos) {
    const video = l.querySelector('video');
    const botao = document.createElement('button');
    botao.type = 'button';
    botao.className = 'laco__botao';
    l.append(botao);
    l.video = video;
    l.pausadoPelaPessoa = false;
    video.removeAttribute('controls');
    const rotulo = () => {
      const parado = video.paused;
      botao.setAttribute('aria-label', `${parado ? 'Tocar' : 'Pausar'} o vídeo (${l.dataset.titulo || 'trecho'})`);
      botao.dataset.s = parado ? 'parado' : 'tocando';
    };
    video.addEventListener('play', rotulo);
    video.addEventListener('pause', rotulo);
    botao.addEventListener('click', () => {
      if (video.paused) { l.pausadoPelaPessoa = false; tocar(l); } else { l.pausadoPelaPessoa = true; video.pause(); }
    });
    rotulo();
    if (io) io.observe(l);
  }
})();
