import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../core/theme/app_theme.dart';
import '../widgets/alarms/alarm_widgets.dart';
import '../widgets/common/adaptive.dart';
import '../widgets/tour/tour.dart';
import 'alarms_page.dart';
import 'devices/devices_page.dart';
import 'projects/projects_page.dart';
import 'screens_page.dart';
import 'tags/tags_page.dart';
import 'tools_page.dart';
import 'tours.dart';

/// Casca do app: barra inferior com as cinco áreas.
///
/// Projetos · Equipamentos · Variáveis · Ferramentas · Alarmes (reunião de
/// 19–20/10/2026: o cliente pediu cinco menus, com as ferramentas de
/// monitoramento e os alarmes à vista em vez de escondidos em "Mais"). Cada
/// aba a mais encolhe os alvos de toque no celular (lição da Retífica), por
/// isso não há sexta: os ajustes do aparelho vão na engrenagem do topo de
/// Projetos, e a ajuda mora no "?" do topo de cada página, nunca na barra.
///
/// **Projetos** tem dois estados: a lista de projetos e, dentro de um, as
/// telas dele. O app abre dentro do último projeto aberto (quem opera uma
/// máquina chega nas telas dela sem um toque a mais); a seta do topo — ou o
/// "voltar" do Android — leva à lista.
///
/// No tablet (a partir de 600 dp, fora o celular deitado) as mesmas cinco
/// áreas vão para um trilho lateral (TB-1): a barra de baixo roubava altura
/// e deixava os ícones a um palmo um do outro.
///
/// As abas são montadas **na primeira visita** (não todas de uma vez): assim
/// o tutorial de cada aba dispara quando a pessoa chega nela, e não escondido
/// atrás de outra no primeiro segundo do app.
class Shell extends StatefulWidget {
  const Shell({super.key});

  static ShellState? of(BuildContext context) => context.findAncestorStateOfType<ShellState>();

  /// A casca montada agora — para quem está fora dela (faixa de alarme acima
  /// do Navigator, página de Ajustes empilhada por cima).
  static ShellState? get active => _active;
  static ShellState? _active;

  static const projectsTab = 0;
  static const devicesTab = 1;
  static const tagsTab = 2;
  static const toolsTab = 3;
  static const alarmsTab = 4;

  @override
  State<Shell> createState() => ShellState();
}

class ShellState extends State<Shell> {
  int _index = 0;
  final Set<int> _visited = {0};

  /// Dentro de um projeto (as telas dele) ou na lista de projetos.
  bool _insideProject = true;

  // Alvos do tutorial "Primeiros passos". [navKey] vai na barra ou no
  // trilho, o que estiver à vista: o passo "O caminho" acha o alvo nos dois.
  final GlobalKey navKey = GlobalKey();
  final GlobalKey screensKey = GlobalKey();
  final GlobalKey addScreenKey = GlobalKey();
  final GlobalKey helpKey = GlobalKey();
  final GlobalKey projectsKey = GlobalKey();
  final GlobalKey<TourHostState> _tourHost = GlobalKey();

  /// As páginas trocam de lugar na árvore entre barra e trilho (girar o
  /// tablet, multijanela): a chave leva junto o estado de cada aba.
  final GlobalKey _pagesKey = GlobalKey();

  int get index => _index;
  bool get insideProject => _insideProject;

  @override
  void initState() {
    super.initState();
    Shell._active = this;
  }

  @override
  void dispose() {
    if (identical(Shell._active, this)) Shell._active = null;
    super.dispose();
  }

  /// Troca de aba por código (tutoriais, faixa de alarme).
  void goTo(int index) => setState(() {
        _index = index;
        _visited.add(index);
      });

  /// Mostra a lista de projetos (seta do topo, "voltar" do Android).
  void showProjectList() => setState(() {
        _insideProject = false;
        _index = Shell.projectsTab;
      });

  /// Mostra as telas do projeto aberto.
  void showProjectScreens() => setState(() {
        _insideProject = true;
        _index = Shell.projectsTab;
      });

  void startIntroTour() {
    showProjectScreens();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tourHost.currentState?.start());
  }

  static const _areas = [
    (Icons.folder_outlined, Icons.folder_rounded, 'Projetos'),
    (Icons.router_outlined, Icons.router_rounded, 'Equipamentos'),
    (Icons.data_object_rounded, Icons.data_object_rounded, 'Variáveis'),
    (Icons.handyman_outlined, Icons.handyman_rounded, 'Ferramentas'),
    (Icons.notifications_none_rounded, Icons.notifications_rounded, 'Alarmes'),
  ];

  /// Rótulos da barra seguram a escala em 115% (fonte do sistema em 130%:
  /// "Equipamentos" quebrava em "Equipamento/s"). Com cinco abas, cada uma
  /// tem 64 dp num celular de 320 dp e 72 num de 360 — e "Equipamentos" na
  /// Plex normal a 12 sp ocupa 83 dp. Por isso o rótulo usa a Plex Condensed
  /// (a mesma dos títulos) e encolhe o necessário, até [_minLabel], para a
  /// palavra caber inteira: nunca quebra, nunca "…". Os ícones já
  /// identificam a aba; num celular de 412 dp a letra fica nos 12 sp.
  static const _maxLabel = 12.0;
  static const _minLabel = 9.0;

  TextStyle _labelStyle(BuildContext context, TextStyle base, double slot) {
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.15);
    final style = base.copyWith(fontFamily: Ind.condensed, letterSpacing: 0, fontSize: _maxLabel);
    var widest = 0.0;
    for (final (_, _, label) in _areas) {
      final tp = TextPainter(text: TextSpan(text: label, style: style), textDirection: TextDirection.ltr, textScaler: scaler, maxLines: 1)..layout();
      if (tp.width > widest) widest = tp.width;
      tp.dispose();
    }
    // Folga de 2 dp de cada lado dentro da área da aba.
    final room = slot - 4;
    final size = widest <= room ? _maxLabel : (_maxLabel * room / widest).clamp(_minLabel, _maxLabel);
    return style.copyWith(fontSize: (size * 4).floorToDouble() / 4);
  }

  Widget _icon(int i, IconData icon) => i == Shell.alarmsTab ? AlarmTabIcon(icon: icon) : Icon(icon);

  Widget _projectsTab(BuildContext context) {
    final c = AppScope.watch(context).controller;
    final inside = _insideProject || !c.manyProjects;
    final page = inside
        ? ScreensPage(
            key: const ValueKey('aba-telas'),
            screensKey: screensKey,
            addKey: addScreenKey,
            helpKey: helpKey,
            backKey: projectsKey,
            onBack: c.manyProjects ? showProjectList : null,
          )
        : ProjectsPage(key: const ValueKey('aba-projetos'), onOpened: showProjectScreens);
    // "Voltar" do Android dentro de um projeto volta para a lista (só com a
    // aba à vista); na lista, sai do app como sempre.
    final backToList = inside && c.manyProjects && _index == Shell.projectsTab;
    return PopScope(
      canPop: !backToList,
      // O aviso chega a todos da rota, inclusive quando quem segurou o
      // "voltar" foi outra aba (o cadastro aberto ao lado no tablet).
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && backToList) showProjectList();
      },
      child: page,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      _projectsTab(context),
      const DevicesPage(),
      const TagsPage(),
      const ToolsPage(),
      const AlarmsPage(),
    ];
    final rail = WindowClass.rail(context);
    final theme = Theme.of(context);

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

    Widget clamp(Widget child) => MediaQuery.withClampedTextScaling(maxScaleFactor: 1.15, child: child);

    return TourHost(
      key: _tourHost,
      spec: Tours.inicio(screens: screensKey, nav: navKey, add: addScreenKey, help: helpKey, projects: projectsKey),
      child: Scaffold(
        body: rail
            ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                clamp(Builder(builder: (context) {
                  const width = 88.0;
                  final railTheme = theme.navigationRailTheme;
                  final fit = _labelStyle(context, railTheme.unselectedLabelTextStyle ?? const TextStyle(), width);
                  TextStyle? apply(TextStyle? s) => s?.copyWith(fontFamily: fit.fontFamily, letterSpacing: fit.letterSpacing, fontSize: fit.fontSize);
                  return NavigationRailTheme(
                    data: railTheme.copyWith(
                      selectedLabelTextStyle: apply(railTheme.selectedLabelTextStyle),
                      unselectedLabelTextStyle: apply(railTheme.unselectedLabelTextStyle),
                    ),
                    child: NavigationRail(
                      key: navKey,
                      selectedIndex: _index,
                      onDestinationSelected: goTo,
                      labelType: NavigationRailLabelType.all,
                      minWidth: width,
                      destinations: [
                        for (var i = 0; i < _areas.length; i++)
                          NavigationRailDestination(icon: _icon(i, _areas[i].$1), selectedIcon: _icon(i, _areas[i].$2), label: Text(_areas[i].$3, maxLines: 1, softWrap: false)),
                      ],
                    ),
                  );
                })),
                // O trilho já desconta a borda da tela (recorte da câmera).
                Expanded(child: MediaQuery.removePadding(context: context, removeLeft: true, child: content)),
              ])
            : content,
        bottomNavigationBar: rail
            ? null
            : clamp(LayoutBuilder(builder: (context, box) {
                final barTheme = theme.navigationBarTheme;
                final fit = _labelStyle(context, barTheme.labelTextStyle?.resolve({}) ?? const TextStyle(), box.maxWidth / _areas.length);
                return NavigationBarTheme(
                  data: barTheme.copyWith(
                    labelTextStyle: WidgetStateProperty.resolveWith(
                        (s) => barTheme.labelTextStyle?.resolve(s)?.copyWith(fontFamily: fit.fontFamily, letterSpacing: fit.letterSpacing, fontSize: fit.fontSize)),
                  ),
                  child: NavigationBar(
                    key: navKey,
                    selectedIndex: _index,
                    onDestinationSelected: goTo,
                    destinations: [
                      for (var i = 0; i < _areas.length; i++)
                        NavigationDestination(icon: _icon(i, _areas[i].$1), selectedIcon: _icon(i, _areas[i].$2), label: _areas[i].$3),
                    ],
                  ),
                );
              })),
      ),
    );
  }
}
