import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/widgets/hmi/element_catalog.dart';
import 'package:ihm/widgets/hmi/hmi_canvas.dart';

const _tela = HmiScreen(id: 's', name: 'Teste', elements: [
  HmiElement(id: 'a', type: ElementType.label, x: 0, y: 0, w: 3, h: 1, props: {'text': 'A'}),
  HmiElement(id: 'b', type: ElementType.label, x: 3, y: 0, w: 3, h: 2, props: {'text': 'B'}),
  HmiElement(id: 'c', type: ElementType.label, x: 1, y: 2, w: 2, h: 1, props: {'text': 'C'}),
]);

void main() {
  group('conversão de grade', () {
    test('6 → 12 dobra tudo; 12 → 6 volta igual', () {
      final fina = _tela.withColumns(HmiScreen.fineColumns)!;
      expect(fina.columns, 12);
      expect(fina.fine, isTrue);
      final b = fina.elements[1];
      expect([b.x, b.y, b.w, b.h], [6, 0, 6, 4]);
      final volta = fina.withColumns(HmiScreen.defaultColumns)!;
      expect(volta.toJson(), _tela.toJson());
    });

    test('meia célula impede voltar para a normal, e diz quantos', () {
      final fina = _tela.withColumns(12)!;
      final torta = fina.copyWith(elements: [fina.elements[0].copyWith(w: 5), ...fina.elements.skip(1)]);
      expect(torta.withColumns(6), isNull);
      expect(torta.oddElements, 1);
    });

    test('projeto antigo sem "columns" abre na grade normal', () {
      final j = _tela.toJson()..remove('columns');
      expect(HmiScreen.fromJson(j).columns, HmiScreen.defaultColumns);
    });
  });

  group('tamanhos por grade', () {
    test('na fina o tamanho inicial dobra', () {
      expect(ElementCatalog.defaultSize(ElementType.button, 6), (2, 2));
      expect(ElementCatalog.defaultSize(ElementType.button, 12), (4, 4));
      expect(ElementCatalog.defaultSize(ElementType.lamp, 12), (6, 2));
    });

    test('quem grava nunca desce de 2×2 na fina; valor pode ter uma linha fina', () {
      expect(ElementCatalog.minSize(ElementType.button, 12), (2, 2));
      expect(ElementCatalog.minSize(ElementType.input, 12), (2, 2));
      expect(ElementCatalog.minSize(ElementType.value, 12), (2, 1));
      expect(ElementCatalog.minSize(ElementType.trend, 12), (6, 4));
      expect(ElementCatalog.minSize(ElementType.trend, 6), (3, 2));
    });
  });

  test('regra única de encaixe: dentro da grade, acima do mínimo, sem sobrepor', () {
    final fina = _tela.withColumns(12)!;
    final a = fina.elements[0]; // 0,0 6×2
    expect(ElementCatalog.fits(fina, a.copyWith(h: 1)), isTrue, reason: 'rótulo pode ter uma linha fina');
    expect(ElementCatalog.fits(fina, a.copyWith(x: 7)), isFalse, reason: 'passaria da borda');
    expect(ElementCatalog.fits(fina, a.copyWith(w: 7)), isFalse, reason: 'sobreporia o B');
    expect(ElementCatalog.fits(fina, a.copyWith(x: -1)), isFalse);
    const botao = HmiElement(id: 'z', type: ElementType.button, x: 0, y: 10, w: 2, h: 2);
    final comBotao = fina.copyWith(elements: [...fina.elements, botao]);
    expect(ElementCatalog.fits(comBotao, botao.copyWith(w: 1)), isFalse, reason: 'botão não desce de 2×2 na fina');
  });
  testWidgets('a mesma tela nas duas grades ocupa as mesmas células', (tester) async {
    Future<Map<String, Rect>> desenha(HmiScreen s) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: HmiCanvas(screen: s))));
      return {for (final e in s.elements) e.id: tester.getRect(find.byKey(ValueKey('el-${e.id}')))};
    }

    tester.view.physicalSize = const Size(1170, 2532); // 390×844 dp
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final normal = await desenha(_tela);
    final fina = await desenha(_tela.withColumns(12)!);
    for (final id in normal.keys) {
      // O respiro encolhe na fina (20% da célula), então a borda do cartão anda
      // até a diferença dos respiros; o centro fica no mesmo lugar.
      expect((normal[id]!.center - fina[id]!.center).distance, lessThan(1), reason: id);
      expect((normal[id]!.width - fina[id]!.width).abs(), lessThanOrEqualTo(HmiCanvas.gap), reason: id);
    }
  });

  testWidgets('grade fina num celular em pé mostra 40 valores sem rolar', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    // 40 rótulos 4×1 finos: 3 por linha → 14 linhas.
    final elementos = [
      for (var i = 0; i < 40; i++)
        HmiElement(id: 'v$i', type: ElementType.label, x: (i % 3) * 4, y: i ~/ 3, w: 4, h: 1, props: {'text': 'V$i'}),
    ];
    final s = HmiScreen(id: 'd', name: 'Densa', columns: 12, elements: elementos);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: HmiCanvas(screen: s, padding: const EdgeInsets.all(14)))));
    final altura = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final ultimo = tester.getRect(find.byKey(const ValueKey('el-v39')));
    expect(ultimo.bottom, lessThan(altura));
  });
}
