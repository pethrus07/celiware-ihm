import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'app/app_scope.dart';
import 'app/appearance.dart';
import 'app/project_controller.dart';
import 'core/theme/app_theme.dart';
import 'screens/shell.dart';
import 'services/runtime/hmi_runtime.dart';
import 'services/storage/project_repository.dart';

/// Ponto de entrada: monta runtime + controlador e entrega ao [CeliwareIhmApp].
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _setupLogging();

  await AppearanceController.instance.load();
  Ind.use(AppearanceController.instance.resolve());

  final runtime = HmiRuntime();
  final controller = ProjectController(repository: ProjectRepository(), runtime: runtime);
  await controller.load();

  runApp(CeliwareIhmApp(controller: controller, runtime: runtime));
}

void _setupLogging() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) => debugPrint('[${r.level.name}] ${r.loggerName}: ${r.message}'));
}

/// Raiz do app. Cuida do ciclo de vida: em segundo plano, solta botões de
/// pulso, para a varredura (bateria e rede) e grava o que estiver pendente.
class CeliwareIhmApp extends StatefulWidget {
  const CeliwareIhmApp({super.key, required this.controller, required this.runtime});

  final ProjectController controller;
  final HmiRuntime runtime;

  @override
  State<CeliwareIhmApp> createState() => _CeliwareIhmAppState();
}

class _CeliwareIhmAppState extends State<CeliwareIhmApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppearanceController.instance.addListener(_applyAppearance);
    _applySystemBars();
  }

  @override
  void dispose() {
    AppearanceController.instance.removeListener(_applyAppearance);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Modo automático: o celular trocou de claro para escuro (fim do dia).
  @override
  void didChangePlatformBrightness() => _applyAppearance();

  /// Troca a paleta e redesenha **a árvore inteira** sem recriar nada: as
  /// cores são lidas no build, então basta marcar tudo para reconstruir. A
  /// pessoa continua na mesma tela (recriar o MaterialApp a jogaria de volta
  /// para o início — no meio da operação, se o automático virasse sozinho).
  void _applyAppearance() {
    final before = Ind.revision;
    Ind.use(AppearanceController.instance.resolve());
    if (Ind.revision == before || !mounted) return;
    _applySystemBars();
    setState(() {});
    void rebuild(Element e) {
      e.markNeedsBuild();
      e.visitChildren(rebuild);
    }
    (context as Element).visitChildren(rebuild);
  }

  void _applySystemBars() {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Ind.isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Ind.surface,
      systemNavigationBarIconBrightness: Ind.isDark ? Brightness.light : Brightness.dark,
    ));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(widget.runtime.pause());
        unawaited(widget.controller.flush());
      case AppLifecycleState.resumed:
        widget.runtime.resume();
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: widget.controller,
      runtime: widget.runtime,
      child: MaterialApp(
        title: 'Celiware IHM',
        debugShowCheckedModeBanner: false,
        theme: Ind.theme,
        home: const Shell(),
      ),
    );
  }
}
