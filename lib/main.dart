import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'app/app_scope.dart';
import 'app/appearance.dart';
import 'services/alarms/alarm_engine.dart';
import 'services/logging/data_logger.dart';
import 'services/logging/log_store.dart';
import 'widgets/alarms/alarm_widgets.dart';
import 'app/project_controller.dart';
import 'core/theme/app_theme.dart';
import 'screens/shell.dart';
import 'services/runtime/hmi_runtime.dart';
import 'services/storage/project_repository.dart';
import 'services/voice/speech_engine.dart';
import 'services/voice/voice_announcer.dart';
import 'services/voice/voice_prefs.dart';

/// Ponto de entrada: monta runtime + controlador e entrega ao [CeliwareIhmApp].
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _setupLogging();

  await AppearanceController.instance.load();
  Ind.use(AppearanceController.instance.resolve());
  await VoicePrefsController.instance.load();

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
  const CeliwareIhmApp({super.key, required this.controller, required this.runtime, this.speech});

  final ProjectController controller;
  final HmiRuntime runtime;

  /// Motor de voz (testes passam um falso); nulo = `flutter_tts`.
  final SpeechEngine? speech;

  @override
  State<CeliwareIhmApp> createState() => _CeliwareIhmAppState();
}

class _CeliwareIhmAppState extends State<CeliwareIhmApp> with WidgetsBindingObserver {
  late final AlarmEngine _alarms;
  late final VoiceAnnouncer _voice;
  late final DataLogger _logger;

  /// Navegação a partir da faixa de alarme (que fica acima do Navigator).
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _alarms = AlarmEngine(
      controller: widget.controller,
      runtime: widget.runtime,
      historyFile: () => widget.controller.repository.sidecar('historico-alarmes.json'),
    );
    _voice = VoiceAnnouncer(
      alarms: AlarmFeed.of(_alarms),
      engine: widget.speech ?? FlutterTtsEngine(),
      prefs: VoicePrefsController.instance,
      controller: widget.controller,
      runtime: widget.runtime,
    );
    // Registro de dados: banco por grupo em `registros/`, ao lado do projeto.
    _logger = DataLogger(controller: widget.controller, runtime: widget.runtime, store: LogStore.beside(widget.controller.repository));
    WidgetsBinding.instance.addObserver(this);
    AppearanceController.instance.addListener(_applyAppearance);
    _applySystemBars();
  }

  @override
  void dispose() {
    AppearanceController.instance.removeListener(_applyAppearance);
    WidgetsBinding.instance.removeObserver(this);
    _voice.dispose();
    _alarms.dispose();
    _logger.dispose();
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
        unawaited(_alarms.flush());
        // Sem varredura não há alarme novo; a voz para junto (§2.4).
        _voice.pause();
        // O registro descarrega o lote e marca a lacuna (§6.10).
        unawaited(_logger.pause());
      case AppLifecycleState.resumed:
        widget.runtime.resume();
        _voice.resume();
        _logger.resume();
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: widget.controller,
      runtime: widget.runtime,
      alarms: _alarms,
      voice: _voice,
      logger: _logger,
      child: MaterialApp(
        title: 'Ware IoT',
        debugShowCheckedModeBanner: false,
        theme: Ind.theme,
        navigatorKey: _navigator,
        navigatorObservers: [AlarmBannerHost.observer],
        // Faixa de alarme acima de TODAS as telas: alarme só na tela que
        // ninguém está olhando não é alarme (ISA-18.2 §11.3.4).
        builder: (context, child) => AlarmBannerHost(navigator: _navigator, child: child ?? const SizedBox()),
        home: const Shell(),
      ),
    );
  }
}
