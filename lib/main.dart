import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'app/app_scope.dart';
import 'app/project_controller.dart';
import 'core/theme/app_theme.dart';
import 'screens/shell.dart';
import 'services/runtime/hmi_runtime.dart';
import 'services/storage/project_repository.dart';

/// Ponto de entrada: monta runtime + controlador e entrega ao [CeliwareIhmApp].
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _setupLogging();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Ind.surface,
  ));

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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
