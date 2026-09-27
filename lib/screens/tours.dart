import 'package:flutter/widgets.dart';

import '../widgets/tour/tour.dart';

/// Todas as trilhas de tutorial, com os textos num lugar só.
///
/// Cada página cria as [GlobalKey]s dos seus alvos e chama a fábrica da sua
/// trilha. Revisar linguagem = mexer só aqui. Mudou a trilha de verdade?
/// Suba a `version` dela — reaparece para todos no próximo acesso.
///
/// Regras da casa: frase curta (o balão é pequeno e ninguém lê parágrafo em
/// tutorial) e todo passo responde "e se a tela estiver vazia?" — passo que
/// ensina o essencial é `essential: true` (aparece centralizado sem alvo).
class Tours {
  Tours._();

  /// Lista para a tela de tutoriais (título + id). A ordem é a de aprendizado.
  static const catalog = [
    ('inicio', 'Primeiros passos', 'Visão geral do app.'),
    ('operar', 'Operar uma tela', 'Botões, ajustes e cores.'),
    ('editor', 'Montar uma tela', 'Colocar, mover e configurar.'),
    ('equipamentos', 'Cadastrar um equipamento', 'IP e teste de conexão.'),
    ('variaveis', 'Criar uma variável', 'Dar nome a uma memória.'),
  ];

  static TourSpec inicio({required GlobalKey screens, required GlobalKey nav, required GlobalKey add, required GlobalKey help}) =>
      TourSpec(id: 'inicio', version: 1, title: 'Primeiros passos', steps: [
        const TourStep(
          essential: true,
          title: 'Bem-vindo',
          body: 'Aqui você monta as telas das suas máquinas. Já tem uma demonstração pronta para mexer à vontade.',
        ),
        TourStep(target: screens, essential: true, title: 'Suas telas', body: 'Toque numa tela para abrir e operar.'),
        TourStep(target: add, title: 'Nova tela', body: 'Crie e monte arrastando elementos. Tudo fica salvo sozinho.'),
        TourStep(
          target: nav,
          essential: true,
          title: 'O caminho',
          body: 'Equipamento (o IP) → Variáveis (nomes das memórias) → Telas.',
        ),
        TourStep(target: help, essential: true, title: 'Dúvida?', body: 'O "?" explica a tela em que você está.'),
      ]);

  static TourSpec operar({GlobalKey? status, GlobalKey? button, GlobalKey? input, GlobalKey? link, GlobalKey? edit}) =>
      TourSpec(id: 'operar', version: 1, title: 'Operar uma tela', steps: [
        TourStep(target: link, essential: true, title: 'Conexão', body: 'Verde: respondendo. Vermelho: sem conexão, com o último valor esmaecido.'),
        TourStep(
            target: status,
            title: 'Cores e alarmes',
            body: 'Cor só aparece quando pede atenção. Alarme sobe numa faixa no topo, com forma e número: '
                '◆1 alta, ▲2 média, ■3 baixa. Toque na faixa para reconhecer.'),
        TourStep(target: button, title: 'Botões', body: 'Acende quando o equipamento confirma. Botão de pulso: segure.'),
        TourStep(target: input, title: 'Ajustar', body: 'Toque, digite e confirme o novo valor.'),
        TourStep(target: edit, essential: true, title: 'Editar', body: 'O lápis abre o editor desta tela.'),
      ]);

  static TourSpec editor({GlobalKey? palette, GlobalKey? element, GlobalKey? config, GlobalKey? settings, GlobalKey? done}) =>
      TourSpec(id: 'editor', version: 1, title: 'Montar uma tela', steps: [
        TourStep(target: palette, essential: true, title: 'Acrescentar', body: 'Escolha um elemento: botão, lâmpada, gráfico...'),
        TourStep(target: element, essential: true, title: 'Mover', body: 'Toque para selecionar, arraste para mover, puxe a bolinha para aumentar.'),
        TourStep(target: config, essential: true, title: 'Configurar', body: 'Escolha a variável, o texto e a cor.'),
        TourStep(target: settings, title: 'Regras', body: 'Nome da tela e se ela pode gravar.'),
        TourStep(target: done, title: 'Pronto', body: 'Já está salvo. Concluir volta para a operação.'),
      ]);

  static TourSpec equipamentos({GlobalKey? list, GlobalKey? add}) =>
      TourSpec(id: 'equipamentos', version: 1, title: 'Cadastrar um equipamento', steps: [
        TourStep(target: list, essential: true, title: 'Equipamentos', body: 'Cada CLP, inversor ou IHM que o app lê.'),
        TourStep(target: add, essential: true, title: 'Cadastrar', body: 'Informe o IP e toque em Testar conexão antes de salvar.'),
        const TourStep(essential: true, title: 'Mesma rede', body: 'O celular precisa estar no mesmo Wi-Fi do equipamento.'),
      ]);

  static TourSpec variaveis({GlobalKey? list, GlobalKey? add}) =>
      TourSpec(id: 'variaveis', version: 1, title: 'Criar uma variável', steps: [
        TourStep(target: list, essential: true, title: 'Variáveis', body: 'Um nome para uma memória: "Velocidade" em vez de "registrador 2".'),
        TourStep(target: add, essential: true, title: 'Criar', body: 'Enquanto você digita o endereço, o app já mostra o valor lido.'),
      ]);
}
