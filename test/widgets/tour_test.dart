import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/theme/app_theme.dart';
import 'package:ihm/widgets/tour/tour.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regras do tutorial que já quebraram uma vez (aqui ou na Retífica).
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const spec = TourSpec(id: 'teste', version: 3, title: 'Teste', steps: [
    TourStep(essential: true, title: 'Passo sem alvo', body: 'Aparece centralizado.'),
  ]);

  Widget app() => MaterialApp(
        theme: Ind.theme,
        home: const TourHost(spec: spec, child: Scaffold(body: Text('página'))),
      );

  testWidgets('aparece sozinho na primeira visita e grava "já vi" com a versão', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Passo sem alvo'), findsOneWidget); // essencial sem alvo: centralizado

    await tester.tap(find.text('Entendi'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Passo sem alvo'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('tour:v3:teste'), isTrue);
  });

  testWidgets('não reaparece para quem já viu esta versão, mas volta numa versão nova', (tester) async {
    SharedPreferences.setMockInitialValues({'tour:v3:teste': true, 'tour:v2:teste': true});
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Passo sem alvo'), findsNothing);

    SharedPreferences.setMockInitialValues({'tour:v2:teste': true}); // viu só a versão antiga
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Passo sem alvo'), findsOneWidget);
  });

  testWidgets('"voltar" do Android fecha o tutorial, não a página', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Passo sem alvo'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Passo sem alvo'), findsNothing);
    expect(find.text('página'), findsOneWidget);
  });
}
