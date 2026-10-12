import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../tour/tour.dart';

// Tablet (etapa 4, TB-1 a TB-6): as classes de janela do Android e as peças
// de layout que mudam com elas.
//
// Regra da casa: o celular fica exatamente como era. Tudo aqui só age a
// partir de 600 dp de largura, e nunca no celular deitado (altura compacta).
//
// Estado não se perde ao girar, redimensionar ou entrar em multijanela. A
// Activity não é recriada (configChanges no manifesto), então basta a árvore
// não jogar nada fora: cada peça mantém a MESMA estrutura nos dois tamanhos
// ou leva o que importa numa GlobalKey. Trocar uma coluna por uma linha sem
// chave descartaria o formulário meio preenchido, a rolagem e a aba.

/// Classes de janela do Android: compacta (< 600 dp), média (600–839) e
/// expandida (≥ 840). Decididas pela janela inteira, não pelo pedaço em que o
/// widget está — é a janela que gira e que divide a tela na multijanela.
class WindowClass {
  WindowClass._();

  /// A partir daqui: trilho lateral no lugar da barra inferior (TB-1).
  static const double medium = 600;

  /// A partir daqui: lista + detalhe e painel lateral no editor (TB-2, TB-4).
  static const double expanded = 840;

  /// Abaixo disto a altura é compacta: é o celular deitado (~390 dp de
  /// altura). Ele passa de 600 — às vezes de 840 — de largura, mas continua
  /// sendo celular: mesma barra e mesmas telas de antes.
  static const double compactHeight = 480;

  static bool _tall(Size s) => s.height >= compactHeight;

  /// Trilho lateral; cadastro abre no painel da página, um painel por vez.
  static bool rail(BuildContext context) {
    final s = MediaQuery.sizeOf(context);
    return s.width >= medium && _tall(s);
  }

  /// Dois painéis lado a lado.
  static bool twoPane(BuildContext context) {
    final s = MediaQuery.sizeOf(context);
    return s.width >= expanded && _tall(s);
  }

  /// Celular deitado (ou janela baixa da multijanela).
  static bool isCompactHeight(BuildContext context) => !_tall(MediaQuery.sizeOf(context));
}

/// Diz a uma página da casca se a aba dela é a que está à vista. As abas já
/// visitadas continuam montadas (IndexedStack): sem isto, o "voltar" do
/// Android fecharia o cadastro aberto numa aba escondida.
class ActiveTab extends InheritedWidget {
  const ActiveTab({super.key, required this.active, required super.child});
  final bool active;

  /// Fora da casca (página aberta por cima, testes) vale como à vista.
  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ActiveTab>()?.active ?? true;

  @override
  bool updateShouldNotify(ActiveTab old) => old.active != active;
}

/// Formulário com campos de no máximo [maxWidth] dp, centralizado (TB-3): no
/// tablet deitado o campo Nome passava de 1.000 dp e o olho perdia a linha.
///
/// Serve para o corpo e para a barra de baixo (o Salvar). Abaixo da largura
/// máxima não muda nada — o celular continua igual. A árvore é a mesma em
/// qualquer largura: girar no meio do cadastro não perde o que foi digitado.
class FormWidth extends StatelessWidget {
  const FormWidth({super.key, required this.child});
  final Widget child;

  /// Largura máxima dos campos; a margem da página ([Ind.page]) fica por fora.
  static const double maxWidth = 640;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) => Align(
          alignment: Alignment.topCenter,
          heightFactor: 1,
          child: SizedBox(width: math.min(box.maxWidth, maxWidth + 2 * Ind.page), child: child),
        ),
      );
}

/// Painel de apoio (TB-4): com [panel], ele fica fixo à direita com ~30% da
/// largura e a barra de baixo passa a ficar só sob o conteúdo; sem, é um
/// Scaffold comum. O corpo mora numa [GlobalKey]: o painel aparecer ou sumir
/// (girar o tablet) não perde a rolagem nem o que estava selecionado.
class SupportingPaneScaffold extends StatefulWidget {
  const SupportingPaneScaffold({super.key, this.appBar, required this.body, this.bottomNavigationBar, this.panel});
  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? bottomNavigationBar;

  /// Nulo = sem painel (celular, tablet em pé).
  final Widget? panel;

  /// ~30% da janela, sem ficar estreito demais para os cartões de escolha
  /// nem largo demais para o conteúdo.
  static double panelWidth(BuildContext context) => (MediaQuery.sizeOf(context).width * 0.3).clamp(320.0, 440.0);

  @override
  State<SupportingPaneScaffold> createState() => _SupportingPaneScaffoldState();
}

class _SupportingPaneScaffoldState extends State<SupportingPaneScaffold> {
  final _bodyKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final body = KeyedSubtree(key: _bodyKey, child: widget.body);
    final panel = widget.panel;
    if (panel == null) return Scaffold(appBar: widget.appBar, body: body, bottomNavigationBar: widget.bottomNavigationBar);
    return Scaffold(
      appBar: widget.appBar,
      body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: Column(children: [Expanded(child: body), ?widget.bottomNavigationBar])),
        SizedBox(
          width: SupportingPaneScaffold.panelWidth(context),
          // Tom de cartão, sem linha divisória. Material, não só cor: as
          // linhas do painel desenham o toque e a seleção nele.
          child: Material(color: Ind.surface, child: panel),
        ),
      ]),
    );
  }
}

/// Lista + detalhe (TB-2). A partir de 840 dp a lista fica à esquerda, com
/// [listWidth], e o cadastro abre ao lado: tocar noutro item troca o detalhe
/// sem empilhar rota. Entre 600 e 839 dp, um painel por vez, com o trilho à
/// vista. No celular nada muda: tocar empilha a página por cima, como sempre.
///
/// O detalhe mora num [Navigator] próprio. Assim os cadastros funcionam sem
/// saber onde estão: o Salvar e o Apagar, que fazem `Navigator.pop`, fecham
/// só o painel; o "Descartar alterações?" continua valendo, inclusive ao
/// tocar noutro item da lista; e uma página aberta de dentro do cadastro abre
/// no próprio painel.
///
/// Lista e detalhe vivem em [GlobalKey]s: ao girar ou redimensionar mudam de
/// lugar na árvore sem perder rolagem nem o que foi digitado. Detalhe aberto
/// numa janela que encolheu até o tamanho de celular continua aberto, no
/// lugar da lista, até alguém voltar.
class ListDetail extends StatefulWidget {
  const ListDetail({super.key, required this.list, required this.placeholder, this.listWidth = 360});

  /// A página da lista (com o próprio AppBar e botão flutuante).
  final Widget list;

  /// O detalhe quando nada está aberto (só aparece com dois painéis).
  final Widget placeholder;
  final double listWidth;

  static ListDetailState of(BuildContext context) => context.findAncestorStateOfType<ListDetailState>()!;

  /// Item aberto no painel agora, para marcar na lista. Nulo no celular, onde
  /// a lista nunca aparece junto do cadastro.
  static Object? selectedOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ListDetailScope>()?.selected;

  @override
  State<ListDetail> createState() => ListDetailState();
}

class ListDetailState extends State<ListDetail> {
  final _listKey = GlobalKey();
  final _navKey = GlobalKey<NavigatorState>();
  late final _observer = _PaneObserver(_navChanged);

  /// Detalhe aberto no painel (acima do [ListDetail.placeholder]).
  bool _open = false;
  Object? _selected;

  /// Item tocado enquanto outro estava aberto: abre quando o atual fechar —
  /// depois do "Descartar alterações?", se o cadastro perguntar.
  (Object, WidgetBuilder)? _pending;

  /// Abre o cadastro [id]. No celular, empilha a página por cima de tudo
  /// (como sempre foi); no tablet, abre no painel.
  void open(Object id, WidgetBuilder builder) {
    if (!WindowClass.rail(context)) {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: builder));
      return;
    }
    if (_open && id == _selected) return;
    final nav = _navKey.currentState;
    if (nav == null) return;
    if (nav.canPop()) {
      // Fecha pelo caminho normal: o cadastro decide se pergunta antes.
      _pending = (id, builder);
      nav.maybePop();
      return;
    }
    _push(id, builder);
  }

  void _push(Object id, WidgetBuilder builder) {
    final nav = _navKey.currentState;
    if (nav == null) return;
    setState(() {
      _open = true;
      _selected = id;
    });
    nav.push(PageRouteBuilder<Object?>(
      pageBuilder: (context, _, _) => builder(context),
      transitionDuration: const Duration(milliseconds: 160),
      reverseTransitionDuration: const Duration(milliseconds: 120),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  /// O painel fechou alguma rota. Chamado no meio da troca de rotas: decide
  /// no fim do quadro.
  void _navChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nav = _navKey.currentState;
      final stillOpen = nav != null && nav.canPop();
      final next = _pending;
      if (next != null) {
        if (stillOpen) {
          // Fechou uma página de dentro do cadastro; falta o cadastro.
          nav.maybePop();
        } else {
          _pending = null;
          _push(next.$1, next.$2);
        }
        return;
      }
      if (!stillOpen && _open) {
        setState(() {
          _open = false;
          _selected = null;
        });
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    final panes = WindowClass.rail(context);
    final two = WindowClass.twoPane(context);
    final active = ActiveTab.of(context);
    final list = KeyedSubtree(key: _listKey, child: widget.list);

    Widget body;
    if (!panes && !_open) {
      // Celular: só a lista, como sempre foi.
      body = list;
    } else {
      final theme = Theme.of(context);
      // Com dois painéis, o detalhe ganha o tom de cartão: separa da lista
      // pelo fundo, sem linha (borda só quando comunica estado).
      final detail = Theme(
        data: two
            ? theme.copyWith(
                scaffoldBackgroundColor: Ind.surface,
                appBarTheme: theme.appBarTheme.copyWith(backgroundColor: Ind.surface),
              )
            : theme,
        // Mexeu no cadastro depois de "Continuar editando": o item tocado
        // antes não abre mais sozinho.
        child: Listener(
          onPointerDown: (_) => _pending = null,
          child: Navigator(
            key: _navKey,
            observers: [_observer],
            onGenerateRoute: (_) => PageRouteBuilder<void>(
              pageBuilder: (context, _, _) => widget.placeholder,
              transitionDuration: Duration.zero,
            ),
          ),
        ),
      );
      body = two
          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: widget.listWidth, child: list),
              Expanded(child: detail),
            ])
          : IndexedStack(index: _open ? 1 : 0, sizing: StackFit.expand, children: [list, detail]);
    }

    return _ListDetailScope(
      selected: panes && _open ? _selected : null,
      // "Voltar" do Android com o cadastro aberto no painel: fecha o
      // cadastro (que pergunta, se tiver alteração), não a página.
      child: PopScope(
        canPop: !(_open && active),
        onPopInvokedWithResult: (didPop, _) {
          if (didPop || !_open || !active) return;
          // Tutorial aberto: o "voltar" fecha só o tutorial.
          final tour = TourHost.maybeOf(context);
          if (tour != null && (tour.isActive || tour.closingByBack)) return;
          _navKey.currentState?.maybePop();
        },
        child: body,
      ),
    );
  }
}

class _ListDetailScope extends InheritedWidget {
  const _ListDetailScope({required this.selected, required super.child});
  final Object? selected;

  @override
  bool updateShouldNotify(_ListDetailScope old) => old.selected != selected;
}

class _PaneObserver extends NavigatorObserver {
  _PaneObserver(this.onChange);
  final VoidCallback onChange;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => onChange();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => onChange();
}
