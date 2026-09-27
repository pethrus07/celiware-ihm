import 'package:flutter/material.dart';

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

  // Alvos do tutorial "Primeiros passos".
  final GlobalKey navKey = GlobalKey();
  final GlobalKey screensKey = GlobalKey();
  final GlobalKey addScreenKey = GlobalKey();
  final GlobalKey helpKey = GlobalKey();
  final GlobalKey<TourHostState> _tourHost = GlobalKey();

  /// Troca de aba por código (tela de tutoriais).
  void goTo(int index) => setState(() {
        _index = index;
        _visited.add(index);
      });

  void startIntroTour() {
    goTo(0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _tourHost.currentState?.start());
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      ScreensPage(screensKey: screensKey, addKey: addScreenKey, helpKey: helpKey),
      const DevicesPage(),
      const TagsPage(),
      const MorePage(),
    ];

    return TourHost(
      key: _tourHost,
      spec: Tours.inicio(screens: screensKey, nav: navKey, add: addScreenKey, help: helpKey),
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < pages.length; i++) _visited.contains(i) ? pages[i] : const SizedBox.shrink(),
          ],
        ),
        // Fonte do sistema em 130%: "Equipamentos" quebrava em "Equipamento/s".
        // A barra segura a escala em 115% (os ícones já identificam a aba); o
        // resto do app segue a fonte que a pessoa escolheu.
        bottomNavigationBar: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.15,
          child: NavigationBar(
            key: navKey,
            selectedIndex: _index,
            onDestinationSelected: goTo,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard_rounded), label: 'Telas'),
              NavigationDestination(icon: Icon(Icons.router_outlined), selectedIcon: Icon(Icons.router_rounded), label: 'Equipamentos'),
              NavigationDestination(icon: Icon(Icons.data_object_rounded), selectedIcon: Icon(Icons.data_object_rounded), label: 'Variáveis'),
              NavigationDestination(icon: Icon(Icons.more_horiz_rounded), selectedIcon: Icon(Icons.more_horiz_rounded), label: 'Mais'),
            ],
          ),
        ),
      ),
    );
  }
}
