/* Ware IoT — chamada que reconhece o aparelho.
 *
 * Progressivo: sem este arquivo, o site funciona igual (selo da Google Play
 * sempre; QR a partir de 760 px, só pelo CSS). Com ele, a raiz da página ganha
 * uma classe e o CSS (site.css, "Chamada de baixar") faz o resto:
 *   .aparelho-android  → só o selo (o QR some, mesmo em tablet);
 *   .aparelho-iphone   → "O Ware IoT é só para Android" + "Mandar o link";
 *   .aparelho-pc       → selo e QR, mesmo com a janela estreita.
 * Aparelho que não dá para reconhecer fica como sem JavaScript.
 */
(function () {
  'use strict';

  var ua = navigator.userAgent || '';
  var tipo = '';
  if (/Android/i.test(ua)) {
    tipo = 'android';
  } else if (/iPhone|iPad|iPod/i.test(ua) || (/Macintosh/i.test(ua) && navigator.maxTouchPoints > 1)) {
    tipo = 'iphone'; // o iPad novo se apresenta como Mac, mas tem toque
  } else if (window.matchMedia && window.matchMedia('(hover: hover) and (pointer: fine)').matches) {
    tipo = 'pc';
  }
  if (!tipo) return;
  document.documentElement.classList.add('aparelho-' + tipo);
  if (tipo !== 'iphone') return;

  // "Mandar o link": a folha de compartilhar do iPhone (WhatsApp, e-mail…);
  // sem ela, copia; sem as duas, mostra o link para copiar à mão.
  function mandar(botao) {
    var link = botao.getAttribute('data-mandar');
    var aviso = botao.parentNode.querySelector('.chamada__aviso');
    var dizer = function (texto) { if (aviso) aviso.textContent = texto; };

    if (navigator.share) {
      navigator.share({
        title: 'Ware IoT',
        text: 'Ware IoT: o celular Android vira a IHM da máquina. Grátis, na Google Play:',
        url: link
      }).catch(function () { /* a pessoa fechou a folha: nada a fazer */ });
      return;
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(link).then(
        function () { dizer('Link copiado. Cole no WhatsApp ou no e-mail.'); },
        function () { dizer('Copie o link: ' + link); }
      );
      return;
    }
    dizer('Copie o link: ' + link);
  }

  var botoes = document.querySelectorAll('[data-mandar]');
  for (var i = 0; i < botoes.length; i++) {
    botoes[i].addEventListener('click', function (e) { mandar(e.currentTarget); });
  }
})();
