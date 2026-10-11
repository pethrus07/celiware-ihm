import 'package:flutter/material.dart';

import '../widgets/common/adaptive.dart';
import '../widgets/tour/tour.dart';
import 'devices/devices_page.dart';
import 'more_page.dart';
import 'screens_page.dart';
import 'tags/tags_page.dart';
import 'tours.dart';

/// Casca do app: barra inferior com as quatro áreas.
///
/// Telas · Equipamentos · Variáveis · Mais. Quatro abas, não cinco: a lição
/// da Retífica é que cada aba a mais encolhe todos os alvos de toque no
/// celular, e a ajuda mora no "?" do topo, não na barra.
///
/// No tablet (a partir de 600 dp, fora o celular deitado) as mesmas quatro
/// áreas vão para um trilho lateral (TB-1): a barra de baixo roubava altura
/// e deixava os ícones a um palmo um do outro.
///
/// As abas são montadas **na primeira visita** (não todas de uma vez): assim
/// o tutorial de cada aba dispara quando a pessoa chega nela, e não escondido
/// atrás de outra no primeiro segundo do app.
class Shell extends StatefulWidget {
  const Shell({super.key});

  static ShellState? of(BuildContext context) => context.findAncestorStateOfType<ShellState>();

  @override
  State<Shell> createState() => ShellState();
}

class ShellState extends State<Shell> {
  int _index = 0;
  final Set<int> _visited = {0};

  // Alvos do tutorial "Primeiros passos". [navKey] vai na barra ou no
  // trilho, o que estiver à vista: o passo "O caminho" acha o alvo nos dois.
  final GlobalKey navKey = GlobalKey();
  final GlobalKey screensKey = GlobalKey();
  final GlobalKey addScreenKey = GlobalKey();
  final GlobalKey helpKey = GlobalKey();
  final GlobalKey<TourHostState> _tourHost = GlobalKey();

  /// As páginas trocam de lugar na árvore entre barra e trilho (girar o
  /// tablet, multijanela): a chave leva junto o estado de cada aba.
  final GlobalKey _pagesKey = GlobalKey();

  /// Troca de aba por código (tela de tutoriais).
  void goTo(int index) => setState(() {
        _index = index;
        _visited.add(index);
      });

  void startIntroTour() {
    goTo(0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _tourHost.currentState?.start());
  }

  static const _areas = [
    (Icons.dashboard_outlined, Icons.dashboard_rounded, 'Telas'),
    (Icons.router_outlined, Icons.router_rounded, 'Equipamentos'),
    (Icons.data_object_rounded, Icons.data_object_rounded, 'Variáveis'),
    (Icons.more_horiz_rounded, Icons.more_horiz_rounded, 'Mais'),
  ];

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      ScreensPage(screensKey: screensKey, addKey: addScreenKey, helpKey: helpKey),
      const DevicesPage(),
      const TagsPage(),
      const MorePage(),
    ];
    final rail = WindowClass.rail(context);

    final content = KeyedSubtree(
      key: _pagesKey,
      child: IndexedStack(
        index: _index,
        children: [
          // HeroMode: só a aba à vista entra na animação de troca de página.
          // Sem isso, duas abas visitadas com botão flutuante (mesma tag de
          // Hero) quebravam qualquer navegação em modo debug.
          for (var i = 0; i < pages.length; i++)
            _visited.contains(i) ? ActiveTab(active: i == _index, child: HeroMode(enabled: i == _index, child: pages[i])) : const SizedBox.shrink(),
        ],
      ),
    );

    return TourHost(
      key: _tourHost,
      spec: Tours.inicio(screens: screensKey, nav: navKey, add: addScreenKey, help: helpKey),
      child: Scaffold(
        body: rail
            ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.15,
                  child: NavigationRail(
                    key: navKey,
                    selectedIndex: _index,
                    onDestinationSelected: goTo,
                    labelType: NavigationRailLabelType.all,
                    minWidth: 88,
                    destinations: [
                      for (final (icon, selected, label) in _areas)
                        NavigationRailDestination(icon: Icon(icon), selectedIcon: Icon(selected), label: Text(label)),
                    ],
                  ),
                ),
                // O trilho já desconta a borda da tela (recorte da câmera).
                Expanded(child: MediaQuery.removePadding(context: context, removeLeft: true, child: content)),
              ])
            : content,
        // Fonte do sistema em 130%: "Equipamentos" quebrava em "Equipamento/s".
        // A barra segura a escala em 115% (os ícones já identificam a aba); o
        // resto do app segue a fonte que a pessoa escolheu.
        bottomNavigationBar: rail
            ? null
            : MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.15,
                child: NavigationBar(
                  key: navKey,
                  selectedIndex: _index,
                  onDestinationSelected: goTo,
                  destinations: [
                    for (final (icon, selected, label) in _areas)
                      NavigationDestination(icon: Icon(icon), selectedIcon: Icon(selected), label: label),
                  ],
                ),
              ),
      ),
    );
  }
}
