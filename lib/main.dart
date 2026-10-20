import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:logging/logging.dart';

import 'app/app_scope.dart';
import 'app/appearance.dart';
import 'services/alarms/alarm_engine.dart';
import 'services/logging/data_logger.dart';
import 'services/logging/log_store.dart';
import 'services/rules/rule_engine.dart';
import 'widgets/alarms/alarm_widgets.dart';
import 'widgets/rules/rule_proposal_host.dart';
import 'app/project_controller.dart';
import 'core/theme/app_theme.dart';
import 'screens/shell.dart';
import 'services/runtime/hmi_runtime.dart';
import 'services/voice/speech_engine.dart';
import 'services/voice/voice_announcer.dart';
import 'services/update/play_update_gateway.dart';
import 'services/update/update_check.dart';
import 'services/voice/voice_prefs.dart';

/// Ponto de entrada: monta runtime + controlador e entrega ao [CeliwareIhmApp].
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _setupLogging();

  await AppearanceController.instance.load();
  Ind.use(AppearanceController.instance.resolve());
  await VoicePrefsController.instance.load();

  final runtime = HmiRuntime();
  // Vários projetos, cada um na sua pasta; o projeto único das versões
  // antigas vira o primeiro da lista ao abrir (PlantStore.load).
  final controller = ProjectController(library: PlantStore(), runtime: runtime);
  await controller.load();

  // Atualização pela Play (D2, 19–20/10/2026): oferece ao abrir; sem
  // internet ou fora da Play, nada acontece (§6.15).
  runApp(CeliwareIhmApp(controller: controller, runtime: runtime, updates: UpdateChecker(gateway: PlayUpdateGateway())));
}

void _setupLogging() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) => debugPrint('[${r.level.name}] ${r.loggerName}: ${r.message}'));
}

/// Raiz do app. Cuida do ciclo de vida: em segundo plano, solta botões de
/// pulso, para a varredura (bateria e rede) e grava o que estiver pendente.
class CeliwareIhmApp extends StatefulWidget {
  const CeliwareIhmApp({super.key, required this.controller, required this.runtime, this.speech, this.updates});

  final ProjectController controller;
  final HmiRuntime runtime;

  /// Motor de voz (testes passam um falso); nulo = `flutter_tts`.
  final SpeechEngine? speech;

  /// Verificação de atualização pela Play; nulo (testes) = não confere.
  final UpdateChecker? updates;

  @override
  State<CeliwareIhmApp> createState() => _CeliwareIhmAppState();
}

class _CeliwareIhmAppState extends State<CeliwareIhmApp> with WidgetsBindingObserver {
  late final AlarmEngine _alarms;
  late final VoiceAnnouncer _voice;
  late final DataLogger _logger;
  late final RuleEngine _rules;

  /// Navegação a partir da faixa de alarme (que fica acima do Navigator).
  final _navigator = GlobalKey<NavigatorState>();

  /// Aviso "atualização baixada" por cima de qualquer tela.
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  /// Confere a atualização sem nunca segurar a abertura nem a operação.
  void _checkUpdates({bool resumed = false}) {
    final u = widget.updates;
    if (u == null) return;
    unawaited(u.run(resumed: resumed, onDownloaded: _offerRestart));
  }

  /// Flexível baixada: a pessoa reinicia quando puder (no meio da operação,
  /// reiniciar sozinho derrubaria as conexões).
  void _offerRestart() => _messenger.currentState?.showSnackBar(SnackBar(
        duration: const Duration(days: 1),
        content: const Text('Versão nova baixada.'),
        action: SnackBarAction(label: 'Reiniciar', onPressed: () => unawaited(widget.updates?.install())),
      ));

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
    // Registro de dados: banco por grupo na pasta de registros do projeto
    // ABERTO — pedida de novo a cada vez, porque muda quando outro projeto
    // é aberto.
    _logger = DataLogger(
      controller: widget.controller,
      runtime: widget.runtime,
      store: LogStore(directory: () => widget.controller.repository.logsDirectory()),
    );
    // Regras entre máquinas: propõem em qualquer tela; parada vira alarme.
    _rules = RuleEngine(
      controller: widget.controller,
      runtime: widget.runtime,
      alarms: _alarms,
      historyFile: () => widget.controller.repository.sidecar('historico-regras.json'),
    );
    WidgetsBinding.instance.addObserver(this);
    AppearanceController.instance.addListener(_applyAppearance);
    _applySystemBars();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdates());
  }

  @override
  void dispose() {
    AppearanceController.instance.removeListener(_applyAppearance);
    WidgetsBinding.instance.removeObserver(this);
    _voice.dispose();
    _rules.dispose();
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
        // Regras param: proposta pendente sai, nada é gravado depois (§6.11).
        _rules.pause();
        unawaited(_rules.flush());
      case AppLifecycleState.resumed:
        widget.runtime.resume();
        _voice.resume();
        _logger.resume();
        _rules.resume();
        _checkUpdates(resumed: true);
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
      rules: _rules,
      child: MaterialApp(
        title: 'Ware IoT',
        debugShowCheckedModeBanner: false,
        theme: Ind.theme,
        // Só português do Brasil: o que vem do próprio Flutter (licenças,
        // dicas dos botões, copiar/colar, leitor de tela) segue o app, não
        // o idioma do celular.
        locale: const Locale('pt', 'BR'),
        supportedLocales: const [Locale('pt', 'BR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        navigatorKey: _navigator,
        scaffoldMessengerKey: _messenger,
        // Faixa do topo acima de TODAS as telas, com espaço sempre
        // reservado: alarme só na tela que ninguém está olhando não é alarme
        // (ISA-18.2 §11.3.4). A pergunta de uma regra ("Parar a prensa?")
        // usa a mesma faixa; o RuleProposalHost só vibra quando ela chega.
        builder: (context, child) => AlarmBannerHost(navigator: _navigator, child: RuleProposalHost(rules: _rules, child: child ?? const SizedBox())),
        home: const Shell(),
      ),
    );
  }
}
