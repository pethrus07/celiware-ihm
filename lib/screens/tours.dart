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

  /// v2 (reunião de 19–20/10/2026): o app abre dentro de um projeto, a
  /// seta do topo leva à lista de projetos, e a barra tem Ferramentas e
  /// Alarmes no lugar de "Mais".
  static TourSpec inicio({required GlobalKey screens, required GlobalKey nav, required GlobalKey add, required GlobalKey help, GlobalKey? projects}) =>
      TourSpec(id: 'inicio', version: 2, title: 'Primeiros passos', steps: [
        const TourStep(
          essential: true,
          title: 'Bem-vindo',
          body: 'Aqui você monta as telas das suas máquinas. Já tem uma demonstração pronta para mexer à vontade.',
        ),
        TourStep(target: screens, essential: true, title: 'Suas telas', body: 'Toque numa tela para abrir e operar.'),
        TourStep(target: add, title: 'Nova tela', body: 'Em branco ou de um modelo pronto: máquina, inversor, balança... Tudo fica salvo sozinho.'),
        TourStep(
          target: projects,
          title: 'Projetos',
          body: 'A seta mostra todos os projetos. Cada um tem os seus equipamentos, variáveis e telas.',
        ),
        TourStep(
          target: nav,
          essential: true,
          title: 'O caminho',
          body: 'Equipamento (o IP) → Variáveis (nomes das memórias) → Telas. Registros, receitas, regras e câmeras ficam em Ferramentas.',
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

  /// v2 (21/10/2026): o passo "Regras da tela" cita a grade extra-fina e a
  /// imagem de fundo (sinótico). Sem alvo à vista (elemento selecionado no
  /// celular), o passo é pulado — as regras não são essenciais.
  static TourSpec editor({GlobalKey? palette, GlobalKey? element, GlobalKey? config, GlobalKey? settings, GlobalKey? done}) =>
      TourSpec(id: 'editor', version: 2, title: 'Montar uma tela', steps: [
        TourStep(target: palette, essential: true, title: 'Acrescentar', body: 'Escolha um elemento: botão, lâmpada, gráfico, OEE...'),
        TourStep(target: element, essential: true, title: 'Mover', body: 'Toque para selecionar, arraste para mover, puxe a bolinha para aumentar.'),
        TourStep(target: config, essential: true, title: 'Configurar', body: 'Escolha a variável, o texto e a cor.'),
        // "Regras da tela", como no botão: "Regras" sozinho é o de
        // Ferramentas (regras entre máquinas).
        TourStep(
          target: settings,
          title: 'Regras da tela',
          body: 'Nome, grade (fina ou extra-fina, para encaixar com precisão), imagem de fundo e se a tela pode gravar.',
        ),
        TourStep(target: done, title: 'Pronto', body: 'Já está salvo. Concluir volta para a operação.'),
      ]);

  static TourSpec equipamentos({GlobalKey? list, GlobalKey? add}) =>
      TourSpec(id: 'equipamentos', version: 1, title: 'Cadastrar um equipamento', steps: [
        TourStep(target: list, essential: true, title: 'Equipamentos', body: 'Cada CLP, inversor ou IHM que o app lê.'),
        TourStep(target: add, essential: true, title: 'Cadastrar', body: 'Informe o IP (ou toque na lupa para procurar no Wi-Fi) e toque em Testar conexão antes de salvar.'),
        const TourStep(essential: true, title: 'Mesma rede', body: 'O celular precisa estar no mesmo Wi-Fi do equipamento.'),
      ]);

  /// v2: o passo dos ícones do topo (Σ e Criar várias), que chegaram na
  /// etapa 4 sem explicação.
  // Recursos de Ferramentas: só texto, no "?" de cada página (não abrem sozinhos).

  static TourSpec registros() => const TourSpec(id: 'registros', version: 1, title: 'Registros', steps: [
        TourStep(essential: true, title: 'Registros', body: 'Grava variáveis no celular para ver o histórico em gráfico e mandar a planilha.'),
        TourStep(essential: true, title: 'Com o app aberto', body: 'Grava em qualquer tela, mas só com o app aberto. Com ele fechado, o gráfico mostra o intervalo vazio.'),
        TourStep(essential: true, title: 'Planilha', body: 'No histórico, o botão de enviar gera o arquivo que abre no Excel.'),
      ]);

  static TourSpec receitas() => const TourSpec(id: 'receitas', version: 1, title: 'Receitas', steps: [
        TourStep(essential: true, title: 'Receitas', body: 'Os ajustes de cada produto: velocidade, comprimento, temperatura.'),
        TourStep(essential: true, title: 'Ler e comparar', body: '"Ler da máquina" guarda os valores de agora. "Comparar" mostra só o que está diferente.'),
        TourStep(essential: true, title: 'Aplicar', body: 'Mostra o "de → para" e só grava depois da sua confirmação. Não substitui a segurança da máquina.'),
      ]);

  /// v2: as regras da planta (variáveis de qualquer projeto).
  static TourSpec regras() => const TourSpec(id: 'regras', version: 2, title: 'Regras', steps: [
        TourStep(essential: true, title: 'Regras', body: '"Quando a condição durar um tempo, gravar um valor": uma máquina avisa a outra.'),
        TourStep(essential: true, title: 'Deste projeto ou da planta', body: 'As do projeto usam as variáveis dele. As da planta usam variáveis de qualquer projeto.'),
        TourStep(essential: true, title: 'Pergunta antes', body: 'O padrão é perguntar antes de gravar. Gravar sozinha só serve para parar.'),
        TourStep(essential: true, title: 'Não é segurança', body: 'Celular não é intertravamento: emergência e proteções continuam na máquina.'),
      ]);

  static TourSpec cameras() => const TourSpec(id: 'cameras', version: 1, title: 'Câmeras', steps: [
        TourStep(essential: true, title: 'Câmeras', body: 'A máquina ao vivo, em tela cheia. Toque na câmera para abrir; o lápis edita.'),
        TourStep(essential: true, title: 'Cadastrar', body: 'Em "Nova câmera", escolha a marca e digite o IP: o app monta o endereço do vídeo.'),
        TourStep(essential: true, title: 'Na tela da máquina', body: 'Um Botão no modo "Abrir câmera" abre a câmera direto da tela de operação.'),
        TourStep(essential: true, title: 'Senha', body: 'Fica só neste aparelho: não vai junto quando você envia o projeto.'),
      ]);

  /// A lista de projetos. Como Equipamentos, só abre pelo "?".
  static TourSpec projetos({GlobalKey? list, GlobalKey? add, GlobalKey? settings}) =>
      TourSpec(id: 'projetos', version: 1, title: 'Projetos', steps: [
        TourStep(target: list, essential: true, title: 'Projetos', body: 'Uma máquina por projeto, com os seus equipamentos, variáveis e telas. Toque para abrir.'),
        TourStep(target: add, title: 'Novo projeto', body: 'Em branco, a demonstração, um projeto pronto ou um arquivo recebido. Nunca apaga outro projeto.'),
        const TourStep(essential: true, title: 'Enviar', body: 'O ⋮ do projeto envia, salva ou duplica ele. O ⋮ do topo faz o mesmo com a planta inteira.'),
        TourStep(target: settings, title: 'Ajustes', body: 'Claro ou escuro, tutoriais e sobre o app.'),
      ]);

  /// A aba Ferramentas. Como Equipamentos, só abre pelo "?".
  static TourSpec ferramentas({GlobalKey? logs, GlobalKey? project, GlobalKey? device}) =>
      TourSpec(id: 'ferramentas', version: 1, title: 'Ferramentas', steps: [
        TourStep(target: logs, essential: true, title: 'Registros', body: 'Grava variáveis para ver o histórico em gráfico e mandar a planilha.'),
        TourStep(target: project, title: 'Do projeto aberto', body: 'Câmeras, receitas e regras. Cada página tem o seu "?".'),
        TourStep(target: device, title: 'Só neste aparelho', body: 'A voz dos alarmes e a procura de equipamentos no Wi-Fi.'),
      ]);

  /// Ajustes (engrenagem de Projetos).
  static TourSpec ajustes({GlobalKey? device, GlobalKey? tutorials}) =>
      TourSpec(id: 'ajustes', version: 1, title: 'Ajustes', steps: [
        TourStep(target: device, essential: true, title: 'Só neste aparelho', body: 'Claro ou escuro vale só para este celular.'),
        TourStep(target: tutorials, title: 'Tutoriais', body: 'Reveja qualquer tutorial quando quiser.'),
      ]);

  /// A aba Alarmes: só texto, pelo "?".
  static TourSpec alarmes() => const TourSpec(id: 'alarmes', version: 1, title: 'Alarmes', steps: [
        TourStep(essential: true, title: 'Alarmes', body: 'Os do projeto aberto. O mais grave fica em cima: ◆1 alta, ▲2 média, ■3 baixa.'),
        TourStep(essential: true, title: 'Reconhecer', body: 'Confirma que você viu. O alarme fica na lista enquanto a condição existir.'),
        TourStep(essential: true, title: 'Histórico', body: 'O que aconteceu, com a hora. Cada projeto tem o seu.'),
      ]);

  static TourSpec variaveis({GlobalKey? list, GlobalKey? add, GlobalKey? more}) =>
      TourSpec(id: 'variaveis', version: 2, title: 'Criar uma variável', steps: [
        TourStep(target: list, essential: true, title: 'Variáveis', body: 'Um nome para uma memória: "Velocidade" em vez de "registrador 2".'),
        TourStep(target: add, essential: true, title: 'Criar', body: 'Enquanto você digita o endereço, o app já mostra o valor lido.'),
        TourStep(target: more, title: 'Outros jeitos', body: 'Σ: variável que é uma conta com outras. Ao lado: várias de uma vez, por faixa (D0 a D99) ou planilha.'),
      ]);
}
