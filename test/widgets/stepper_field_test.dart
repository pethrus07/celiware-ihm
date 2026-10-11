import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/widgets/common/common.dart';

/// Campo de número inteiro com − / + (porta, ID do escravo, bit, tamanho).
void main() {
  testWidgets('só algarismos: o "." do teclado numérico não entra (porta "5020." no QA de 11/10)', (tester) async {
    final c = TextEditingController(text: '502');
    addTearDown(c.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StepperField(label: 'Porta', controller: c, min: 1, max: 65535, fieldKey: const ValueKey('porta'))),
    ));
    await tester.enterText(find.byKey(const ValueKey('porta')), '5020.');
    expect(c.text, '5020');
    await tester.enterText(find.byKey(const ValueKey('porta')), '50,2');
    expect(c.text, '502');
    await tester.tap(find.byIcon(Icons.add_rounded));
    expect(c.text, '503');
  });
}
