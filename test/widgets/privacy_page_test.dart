import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/app_info.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/main.dart';
import 'package:ihm/screens/privacy_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Política de privacidade dentro do app (PS-5): a Play pede link ou texto no
/// próprio app, além da URL no Play Console.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // Todas as versões já vistas (a trilha de início está na v2).
      for (final (id, _, _) in Tours.catalog) for (final v in [1, 2]) 'tour:v$v:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_privacidade');
  });

  tearDown(() async {
    DemoRegistry.discard(DemoProject.deviceId);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo */}
  });

  testWidgets('Mais → Privacidade abre o texto da política, sem internet', (tester) async {
    final runtime = HmiRuntime();
    final controller = ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
    await tester.runAsync(controller.load);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CeliwareIhmApp(controller: controller, runtime: runtime));
    await live(tester, 600);

    // Privacidade mora nos Ajustes (engrenagem do topo de Projetos).
    await tester.tap(find.byKey(const ValueKey('ajustes')));
    await live(tester, 600);
    final tile = find.byKey(const ValueKey('privacidade'));
    await tester.scrollUntilVisible(tile, 200, scrollable: find.byType(Scrollable).first);
    // Até o meio: na beirada de baixo, a barra de abas cobre a linha.
    await Scrollable.ensureVisible(tester.element(tile), alignment: 0.5);
    await live(tester, 400);
    await tester.tap(tile);
    await live(tester, 600);

    expect(find.byType(PrivacyPage), findsOneWidget);
    expect(find.textContaining('não coleta, não envia e não compartilha dados'), findsOneWidget);
    final page = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(find.textContaining(AppInfo.privacyUrl), 300, scrollable: page);
    expect(find.textContaining(AppInfo.privacyUrl), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    final done = runtime.dispose();
    await live(tester, 1200);
    await done;
    controller.dispose();
  });

  test('o texto do app e a página do site dizem as mesmas coisas', () {
    // Mudou um, mude o outro: o revisor da Play compara a política publicada
    // com o formulário de Segurança dos dados e com o app.
    final site = File('site/privacidade.html').readAsStringSync();
    final app = PrivacyPage.sections.expand((s) => [s.$1, ...s.$2]).join('\n');
    for (final fato in [
      'broker MQTT',
      'servidor OPC UA',
      'equipamento com servidor web HTTP',
      'A senha ou o token de equipamento HTTP também fica no cofre do Android',
      'cofre do Android',
      'Quem está aplicando',
      'Ferramentas → Registros',
      'backup do Android',
      'os registros de dados ficam de fora',
      'senhas de equipamento cadastradas',
      'Serviços de fala do Google',
      'estado da rede e troca de rede',
      'áudio nem identificadores do aparelho',
      'O app pergunta à Google Play se há versão nova; isso é feito pela própria Play.',
    ]) {
      expect(app, contains(fato), reason: 'app sem "$fato"');
      expect(site, contains(fato), reason: 'site/privacidade.html sem "$fato"');
    }
    for (final (titulo, _) in PrivacyPage.sections.where((s) => s.$1 != 'Uso profissional')) {
      expect(site, contains('<h2>$titulo</h2>'), reason: 'seção "$titulo" só no app');
    }
  });
}

Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
