import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/main.dart';
import 'package:ihm/screens/tags/tag_form_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/services/voice/speech_engine.dart';
import 'package:ihm/services/voice/voice_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Motor de voz falso que termina cada frase na hora (o teste de widget só
/// quer saber o que foi falado; a fila em detalhe está em
/// voice_announcer_test).
class InstantSpeech implements SpeechEngine {
  InstantSpeech({this.status = const VoiceStatus(VoiceAvailability.ready)});
  final List<String> spoken = [];
  final VoiceStatus status;

  @override
  Future<void> speak(String text, {required double volume, required double rate}) async => spoken.add(text);

  @override
  Future<void> stop() async {}

  @override
  Future<VoiceStatus> check() async => status;
}

/// Voz no app inteiro, com a máquina de demonstração e o relógio simulado
/// (mesmo arranjo de app_flow_test).
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    VoicePrefsController.instance.value = const VoicePrefs();
    dir = await Directory.systemTemp.createTemp('ihm_voz');
  });

  tearDown(() async {
    DemoRegistry.discard(DemoProject.deviceId);
    VoicePrefsController.instance.value = const VoicePrefs();
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo */}
  });

  Future<ProjectController> boot(WidgetTester tester, SpeechEngine speech) async {
    final runtime = HmiRuntime();
    final controller = ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
    await tester.runAsync(controller.load);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CeliwareIhmApp(controller: controller, runtime: runtime, speech: speech));
    await live(tester, 600);
    return controller;
  }

  Future<void> shutdown(WidgetTester tester, ProjectController c) async {
    await tester.pumpWidget(const SizedBox());
    final done = c.runtime.dispose();
    await live(tester, 1200);
    await done;
    c.dispose();
  }

  testWidgets('Silenciar: cala a voz do alarme, não reconhece e fica no histórico', (tester) async {
    final speech = InstantSpeech();
    final c = await boot(tester, speech);
    final memory = DemoRegistry.forDevice(DemoProject.deviceId).memory;
    const porta = 'Alarme urgente: Porta aberta';

    memory.pokeBit(ModbusArea.discreteInput, DemoMap.diDoorClosed, false);
    await live(tester, 1800);
    expect(speech.spoken, [porta]);
    // Na faixa, discreto: só o ícone.
    expect(find.byKey(const ValueKey('silenciar-faixa')), findsOneWidget);

    // Alta não reconhecida repete a cada 30 s.
    await live(tester, 30500, step: 500);
    expect(speech.spoken.where((s) => s == porta), hasLength(2));

    await tester.tap(find.byKey(const ValueKey('faixa-alarme')));
    await live(tester, 600);
    const key = 'regra:demo_porta:al_porta';
    await tester.tap(find.byKey(const ValueKey('silenciar-$key')));
    await live(tester, 300);
    expect(find.byKey(const ValueKey('silenciado-$key')), findsOneWidget);
    expect(find.text('Alta · Não reconhecido'), findsOneWidget, reason: 'silenciar não reconhece');
    expect(find.byKey(const ValueKey('reconhecer-$key')), findsOneWidget);

    await live(tester, 31000, step: 500);
    expect(speech.spoken.where((s) => s == porta), hasLength(2), reason: 'silenciado não repete');

    await tester.tap(find.text('Histórico'));
    await live(tester, 600);
    expect(find.text('Silenciado'), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('folha Voz e avisos: exemplo, velocidade, quem repete e desligar', (tester) async {
    final speech = InstantSpeech();
    final c = await boot(tester, speech);
    await tester.tap(find.text('Mais'));
    await live(tester, 400);
    final tile = find.byKey(const ValueKey('voz-e-avisos'));
    await tester.scrollUntilVisible(tile, 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Fala os alarmes'), findsOneWidget);
    await tester.tap(tile);
    await live(tester, 600);

    expect(find.text('Falar os alarmes'), findsOneWidget);
    // A plataforma do teste não informa fone: a opção nem aparece.
    expect(find.byKey(const ValueKey('so-com-fone')), findsNothing);

    // Desligada, a folha encolhe para o interruptor; a linha da aba Mais diz.
    await tester.tap(find.byKey(const ValueKey('voz-ligada')));
    await live(tester, 300);
    expect(VoicePrefsController.instance.value.enabled, isFalse);
    expect(find.byKey(const ValueKey('falar-exemplo')), findsNothing);
    expect(find.text('Desligada'), findsOneWidget); // atrás da folha
    await tester.tap(find.byKey(const ValueKey('voz-ligada')));
    await live(tester, 300);
    expect(VoicePrefsController.instance.value.enabled, isTrue);

    await tester.tap(find.byKey(const ValueKey('falar-exemplo')));
    await live(tester, 300);
    expect(speech.spoken.single, startsWith('Exemplo de aviso'));

    await tester.tap(find.text('Rápida'));
    await live(tester, 200);
    expect(VoicePrefsController.instance.value.rate, VoiceRate.fast);

    final sheet = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(find.text('Mais opções'), 150, scrollable: sheet);
    await tester.tap(find.text('Mais opções'));
    await live(tester, 700);
    final mediumRepeats = find.byKey(const ValueKey('modo-medium-repeat'));
    await tester.scrollUntilVisible(mediumRepeats, 150, scrollable: sheet);
    await tester.tap(mediumRepeats);
    await live(tester, 200);
    expect(VoicePrefsController.instance.value.medium, VoiceMode.repeat);

    // Do aparelho: gravado no shared_preferences, não no projeto.
    final saved = (await SharedPreferences.getInstance()).getString('voz');
    expect(saved, contains('"rate":"fast"'));
    expect(saved, contains('"medium":"repeat"'));
    expect(c.project.toJson().toString(), isNot(contains('repeat')));
    await shutdown(tester, c);
  });

  testWidgets('sem voz pt-BR: aviso com o nome do motor na linha da aba Mais e na folha (VZ-6)', (tester) async {
    final c = await boot(tester, InstantSpeech(status: const VoiceStatus(VoiceAvailability.missing, engine: 'com.google.android.tts')));
    await tester.tap(find.text('Mais'));
    await live(tester, 400);
    final tile = find.byKey(const ValueKey('voz-e-avisos'));
    await tester.scrollUntilVisible(tile, 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Falta a voz em português'), findsOneWidget);
    await tester.tap(tile);
    await live(tester, 600);
    expect(find.byKey(const ValueKey('voz-faltando')), findsOneWidget);
    expect(find.textContaining('Serviços de fala do Google'), findsOneWidget);
    expect(find.textContaining('só na faixa e na vibração'), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('cadastro de variável: linha de narração, textos por estado e salvar', (tester) async {
    final c = await boot(tester, InstantSpeech());
    // Direto no cadastro (a aba Variáveis não interessa aqui).
    unawaited(tester.state<NavigatorState>(find.byType(Navigator).first).push(
      MaterialPageRoute<void>(builder: (_) => TagFormPage(tag: c.project.tag('demo_status'))),
    ));
    await live(tester, 600);

    final row = find.byKey(const ValueKey('narracao-da-variavel'));
    // A lista do formulário (os campos de texto também têm Scrollable por dentro).
    await tester.scrollUntilVisible(row, 200, scrollable: find.descendant(of: find.byType(ListView).last, matching: find.byType(Scrollable)).first);
    expect(find.text('Valer 0 · Valer 1'), findsOneWidget); // a demonstração já narra parada e em ciclo
    await tester.tap(row);
    await live(tester, 600);

    final add = find.byKey(const ValueKey('acrescentar-narracao'));
    await tester.scrollUntilVisible(add, 150, scrollable: find.descendant(of: find.byType(ListView).last, matching: find.byType(Scrollable)).first);
    await tester.tap(add);
    await live(tester, 300);
    // O novo já vem com o próximo estado (2); falta só o texto.
    final texts = find.widgetWithText(TextFormField, 'Falar');
    expect(texts, findsNWidgets(3));
    await tester.enterText(texts.last, 'A cortadora parou por alarme');
    await live(tester, 200);
    await tester.tap(find.byKey(const ValueKey('narracao-pronto')));
    await live(tester, 600);
    expect(find.text('Valer 0 · Valer 1 · Valer 2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('salvar-variavel')));
    await live(tester, 600);
    final saved = c.project.tag('demo_status')!.narrations;
    expect(saved.map((n) => (n.value, n.text)).last, (2.0, 'A cortadora parou por alarme'));
    expect(saved, hasLength(3));
    await shutdown(tester, c);
  });
}

/// Avança o relógio simulado em passos (varredura e demonstração andam).
Future<void> live(WidgetTester tester, int ms, {int step = 100}) async {
  for (var t = 0; t < ms; t += step) {
    await tester.pump(Duration(milliseconds: step));
  }
}
