import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/calc.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/logic_rule.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/models/vendor_profiles.dart';
import 'package:ihm/screens/tags/address_field.dart';
import 'package:ihm/screens/tags/reading_hints.dart';
import 'package:ihm/screens/tags/tag_form_page.dart';
import 'package:ihm/screens/tags/tag_uses.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/widgets/hmi/element_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cadastro de variável ("editar memória"): os itens EM-1 a EM-12 da etapa 4
/// (docs/REQUISITOS-ETAPA4.md §5.3), com a máquina de demonstração e o
/// relógio simulado — mesmo esquema de `app_flow_test.dart`.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  group('funções puras', () {
    test('endereço: decimal, hexadecimal (0x / h / modo hex) e faixa', () {
      const hr = ModbusArea.holdingRegister;
      expect(AddressInput.read('8192', area: hr).address, 8192);
      expect(AddressInput.read('0x2000', area: hr).address, 8192);
      expect(AddressInput.read('2000h', area: hr).address, 8192);
      expect(AddressInput.read('2000H', area: hr).converted, isTrue);
      expect(AddressInput.read('2000', area: hr, hex: true).address, 8192);
      expect(AddressInput.read('12a', area: hr).error, 'Número inteiro');
      expect(AddressInput.read('70000', area: hr).error, 'Endereço acima de 65535');
      final manual = AddressInput.read('400101', area: hr);
      expect(manual.manual, 100);
      expect(manual.address, isNull);
      expect(AddressInput.read('40101', area: hr).address, 40101, reason: '40101 também é endereço válido');
      expect(AddressInput.read('0x9C45', area: hr).manual, isNull, reason: 'notação de manual é sempre decimal');
      // MP-4: com perfil de fabricante, 40001–49999 são endereços legítimos.
      expect(AddressInput.read('400101', area: hr, manual: false).manual, isNull);
      expect(AddressInput.read('40101', area: hr, manual: false).address, 40101);
    });

    test('endereço: − / + mantém o jeito em que foi escrito', () {
      expect(AddressInput.bump('0x2000', 1), '0x2001');
      expect(AddressInput.bump('2000h', -1), '1FFFh');
      expect(AddressInput.bump('FF', 1, hex: true), '100');
      expect(AddressInput.bump('0', -1), '0');
      expect(AddressInput.bump('400101', -1), '400100');
    });

    test('valor lido: sinal escondido e palavras trocadas', () {
      const u16 = Tag(id: 'a', name: 'a', deviceId: 'd');
      expect(ReadingHints.signedInstead(u16, 65531), TagDataType.int16);
      expect(ReadingHints.signedInstead(u16, 32767), isNull);
      // ÷ 10: 6553,1 na tela é 65531 no equipamento.
      expect(ReadingHints.signedInstead(u16.copyWith(scale: 0.1), 6553.1), TagDataType.int16);
      const f32 = Tag(id: 'f', name: 'f', deviceId: 'd', dataType: TagDataType.float32);
      expect(ReadingHints.looksAbsurd(f32, 75.25), isFalse);
      expect(ReadingHints.looksAbsurd(f32, 0.0), isFalse);
      expect(ReadingHints.looksAbsurd(f32, -2.4e-41), isTrue);
      expect(ReadingHints.looksAbsurd(f32, double.nan), isTrue);
      expect(ReadingHints.looksAbsurd(f32, 3e12), isTrue);
      expect(ReadingHints.looksAbsurd(u16, 1e12), isFalse, reason: '16 bits não tem ordem de palavras');
      expect(ReadingHints.nextOrder(ByteOrder.abcd, {}), ByteOrder.cdab);
      expect(ReadingHints.nextOrder(ByteOrder.cdab, {ByteOrder.abcd, ByteOrder.cdab}), ByteOrder.dcba);
      expect(ReadingHints.nextOrder(ByteOrder.abcd, ByteOrder.values.toSet()), isNull);
    });

    test('usos da variável: cada elemento pede o tipo do lugar onde ela está', () {
      final p = DemoProject.build();
      final temp = TagUse.of(p, 'demo_temp');
      expect(temp.map((u) => u.elementName), ['Medidor', 'Gráfico de tendência']);
      // "Em ciclo" é o retorno do botão Liga e a lâmpada "Ciclo" do líder.
      final ciclo = TagUse.of(p, 'demo_bit_ciclo');
      expect(ciclo.map((u) => u.elementName), ['Botão (retorno)', 'Lâmpada']);
      expect(ciclo.every((u) => u.fit == TagFit.boolean), isTrue);
      final before = p.tag('demo_temp')!;
      expect(TagUse.brokenBy(temp, before, before.copyWith(dataType: TagDataType.int16)), isEmpty);
      expect(TagUse.describe(TagUse.brokenBy(temp, before, before.copyWith(dataType: TagDataType.bool))),
          'Cortadora — operação (Medidor, Gráfico de tendência)');
    });

    test('apagar: o aviso diz o que deixa de funcionar — telas, contas e regras, em qualquer profundidade', () {
      final p = DemoProject.build();
      // "Velocidade" está nas duas telas e na conta da calculada de exemplo.
      expect(
          TagUse.deleteNotice(p, 'demo_vel'),
          'Ela é usada em: Cortadora — operação, Resumo do líder. Esses elementos vão ficar pedindo "Escolha a variável".\n\n'
          'Ela entra na conta de: Rótulos por minuto. Essa conta vai dar erro até ser corrigida.');
      // A regra de exemplo vigia "Temperatura do motor" e grava em "Velocidade desejada".
      expect(TagUse.deleteNotice(p, 'demo_temp'), endsWith('Ela está na regra: Diminuir a velocidade (na condição). Essa regra fica parada até ser corrigida.'));
      expect(TagUse.deleteNotice(p, 'demo_sp'), contains('Diminuir a velocidade (onde grava)'));
      expect(TagUse.deleteNotice(p, 'demo_codalarme'), 'A variável sai do projeto.');

      // Calculada que cita calculada, e regra que vigia a de cima e grava na própria entrada.
      final deep = p.copyWith(
        tags: [
          ...p.tags,
          const Tag(id: 'c2', name: 'Rótulos por hora', deviceId: CalcDevice.id, dataType: TagDataType.float32, calc: CalcSpec(expression: '{${DemoProject.calcTagId}} * 60')),
        ],
        rules: [...p.rules, const LogicRule(id: 'r2', name: 'Avisar', condition: CalcSpec(expression: '{c2} < 100'), targetTagId: 'demo_comp')],
      );
      expect(
          TagUse.deleteNotice(deep, 'demo_comp'),
          'Ela entra na conta de: Rótulos por minuto, Rótulos por hora. Essas contas vão dar erro até serem corrigidas.\n\n'
          'Ela está na regra: Avisar (na condição e onde grava). Essa regra fica parada até ser corrigida.');
    });
  });

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_test');
  });

  tearDown(() async {
    DemoRegistry.discard(DemoProject.deviceId);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo — é só a pasta temporária */}
  });

  Future<ProjectController> boot(WidgetTester tester) async {
    final runtime = HmiRuntime();
    final controller = ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
    await tester.runAsync(controller.load);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CeliwareIhmApp(controller: controller, runtime: runtime));
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

  /// Abre o cadastro por cima do app, como a lista de variáveis faz.
  Future<void> open(WidgetTester tester, {Tag? tag, String? preferDeviceId}) async {
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(nav.push(MaterialPageRoute<Tag>(builder: (_) => TagFormPage(tag: tag, preferDeviceId: preferDeviceId))));
    await live(tester, 700);
  }

  Finder formScroll() =>
      find.descendant(of: find.byKey(const ValueKey('formulario-variavel')), matching: find.byType(Scrollable)).first;

  /// Rola o formulário até [f] aparecer (para cima com [up]). Fecha o teclado
  /// antes, como a pessoa faz: com um campo focado, o próprio campo puxa a
  /// rolagem de volta para mostrar o cursor.
  Future<void> reveal(WidgetTester tester, Finder f, {bool up = false}) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.scrollUntilVisible(f, up ? -200 : 200, scrollable: formScroll());
    await live(tester, 200);
  }

  Future<void> openMore(WidgetTester tester) async {
    await reveal(tester, find.text('Mais opções'));
    await tester.tap(find.text('Mais opções'));
    await live(tester, 800);
  }

  Future<void> tapKey(WidgetTester tester, String key, {int wait = 300}) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await live(tester, wait);
  }

  String fieldText(WidgetTester tester, String key) => tester.widget<TextFormField>(find.byKey(ValueKey(key))).controller!.text;

  Finder inLive(String text) => find.descendant(of: find.byKey(const ValueKey('lendo-agora')), matching: find.text(text));

  ModbusMemory demoMemory() => DemoRegistry.forDevice(DemoProject.deviceId).memory;

  testWidgets('EM-1: voltar sem mudança sai direto; com mudança pergunta, e continuar ou descartar funcionam', (tester) async {
    final c = await boot(tester);
    await open(tester, tag: c.project.tag('demo_vel'));
    await tester.pageBack();
    await live(tester, 600);
    expect(find.byType(TagFormPage), findsNothing);
    expect(find.byKey(const ValueKey('descartar-alteracoes')), findsNothing);

    // Variável nova sem nada digitado também sai direto.
    await open(tester);
    await tester.pageBack();
    await live(tester, 600);
    expect(find.byType(TagFormPage), findsNothing);

    await open(tester, tag: c.project.tag('demo_vel'));
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Velocidade da linha');
    await tester.pageBack();
    await live(tester, 400);
    expect(find.text('Descartar alterações?'), findsOneWidget);
    await tapKey(tester, 'continuar-editando', wait: 400);
    expect(find.byType(TagFormPage), findsOneWidget);
    expect(fieldText(tester, 'campo-nome-variavel'), 'Velocidade da linha');

    await tester.pageBack();
    await live(tester, 400);
    await tapKey(tester, 'descartar', wait: 600);
    expect(find.byType(TagFormPage), findsNothing);
    expect(c.project.tag('demo_vel')!.name, 'Velocidade');
    await shutdown(tester, c);
  });

  testWidgets('EM-1: alarme recém-criado conta como alteração, e "Salvar" no aviso grava', (tester) async {
    final c = await boot(tester);
    expect(c.project.tag('demo_sp')!.alarms, isEmpty);
    await open(tester, tag: c.project.tag('demo_sp'));
    await reveal(tester, find.byKey(const ValueKey('alarmes-da-variavel')));
    await tapKey(tester, 'alarmes-da-variavel', wait: 700);
    await tapKey(tester, 'acrescentar-alarme');
    await tapKey(tester, 'alarmes-pronto', wait: 700);

    await tester.pageBack();
    await live(tester, 400);
    expect(find.textContaining('inclusive os alarmes'), findsOneWidget);
    await tapKey(tester, 'salvar-e-sair', wait: 600);
    expect(find.byType(TagFormPage), findsNothing);
    expect(c.project.tag('demo_sp')!.alarms, hasLength(1));
    await shutdown(tester, c);
  });

  testWidgets('EM-2 e EM-9: trocar o tipo avisa na hora os alarmes que deixam de valer e onde a variável é usada', (tester) async {
    final c = await boot(tester);
    await open(tester, tag: c.project.tag('demo_temp')); // número com vírgula, 2 alarmes, medidor + tendência
    expect(find.byKey(const ValueKey('aviso-tipo')), findsNothing);

    // Inteiro continua servindo no medidor e nos alarmes: nada a avisar.
    await tapKey(tester, 'opcao-TagDataType.uint16');
    expect(find.byKey(const ValueKey('aviso-tipo')), findsNothing);

    await tapKey(tester, 'opcao-TagDataType.bool');
    expect(find.byKey(const ValueKey('aviso-tipo')), findsOneWidget);
    expect(find.textContaining('2 alarmes deixam de valer com este tipo'), findsOneWidget);
    expect(find.textContaining('Usada em: Cortadora — operação (Medidor, Gráfico de tendência)'), findsOneWidget);

    // Voltou: o aviso some e os alarmes continuam guardados.
    await tapKey(tester, 'opcao-TagDataType.float32');
    expect(find.byKey(const ValueKey('aviso-tipo')), findsNothing);
    await tapKey(tester, 'salvar-variavel', wait: 600);
    expect(c.project.tag('demo_temp')!.alarms, hasLength(2));
    await shutdown(tester, c);
  });

  testWidgets('apagar avisa o que deixa de funcionar: os elementos de tela e a regra que vigia a variável', (tester) async {
    final c = await boot(tester);
    await open(tester, tag: c.project.tag('demo_temp'));
    await tester.tap(find.byTooltip('Apagar'));
    await live(tester, 500);
    expect(find.text('Apagar "Temperatura do motor"?'), findsOneWidget);
    expect(find.textContaining('Ela é usada em: Cortadora — operação.'), findsOneWidget);
    expect(find.textContaining('Ela está na regra: Diminuir a velocidade (na condição). Essa regra fica parada até ser corrigida.'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await live(tester, 400);
    expect(c.project.tag('demo_temp'), isNotNull, reason: 'Cancelar não apaga');
    expect(find.byType(TagFormPage), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('EM-3: o tipo que muda "Onde fica" acende o campo por um instante', (tester) async {
    final c = await boot(tester);
    await open(tester);
    AnimatedOpacity highlight() => tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('onde-fica-destaque')));
    expect(highlight().opacity, 0);

    await tapKey(tester, 'opcao-TagDataType.bool'); // registrador → bit
    expect(highlight().opacity, 1);
    await live(tester, 2500);
    expect(highlight().opacity, 0);

    // Número → número não muda "Onde fica": sem realce.
    await tapKey(tester, 'opcao-TagDataType.uint16');
    await live(tester, 2500);
    await tapKey(tester, 'opcao-TagDataType.float32');
    expect(highlight().opacity, 0);

    // Só leitura continua só leitura: registrador de entrada → entrada.
    await tapKey(tester, 'opcao-_Where.input');
    await tapKey(tester, 'opcao-TagDataType.bool');
    expect(highlight().opacity, 1);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('pode-gravar'))).onChanged, isNull);
    await live(tester, 2500);
    await shutdown(tester, c);
  });

  testWidgets('EM-3: sair de Texto devolve "Pode ser alterada pela tela" e o tamanho como estavam', (tester) async {
    final c = await boot(tester);
    await open(tester, tag: c.project.tag('demo_sp')); // inteiro que grava
    SwitchListTile sw() => tester.widget<SwitchListTile>(find.byKey(const ValueKey('pode-gravar')));
    expect(sw().value, isTrue);

    await openMore(tester);
    await reveal(tester, find.byKey(const ValueKey('formato-string')));
    await tapKey(tester, 'formato-string');
    await reveal(tester, find.byKey(const ValueKey('campo-tamanho-texto')), up: true);
    expect(fieldText(tester, 'campo-tamanho-texto'), '10');
    await reveal(tester, find.byKey(const ValueKey('pode-gravar')));
    expect(sw().value, isFalse);

    await reveal(tester, find.byKey(const ValueKey('opcao-TagDataType.uint16')), up: true);
    await tapKey(tester, 'opcao-TagDataType.uint16');
    await reveal(tester, find.byKey(const ValueKey('pode-gravar')));
    expect(sw().value, isTrue);

    await tapKey(tester, 'salvar-variavel', wait: 600);
    final t = c.project.tag('demo_sp')!;
    expect(t.dataType, TagDataType.uint16);
    expect(t.writable, isTrue);
    expect(t.length, 1, reason: 'não pode virar lista de 10 por ter passado por Texto');
    await shutdown(tester, c);
  });

  testWidgets('EM-4: inteiro sem sinal lendo acima de 32767 sugere "Inteiro com sinal"', (tester) async {
    final c = await boot(tester);
    demoMemory().pokeRegister(ModbusArea.holdingRegister, 600, 65531); // −5 em complemento de 2
    await open(tester);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Desvio');
    await tester.enterText(find.byKey(const ValueKey('campo-endereco')), '600');
    await live(tester, 1500);
    expect(inLive('65531'), findsOneWidget);
    expect(find.byKey(const ValueKey('sugestao-com-sinal')), findsOneWidget);

    await tapKey(tester, 'sugestao-com-sinal', wait: 1500);
    expect(inLive('-5'), findsOneWidget);
    expect(find.byKey(const ValueKey('sugestao-com-sinal')), findsNothing);
    await tapKey(tester, 'salvar-variavel', wait: 600);
    expect(c.project.tags.firstWhere((t) => t.name == 'Desvio').dataType, TagDataType.int16);
    await shutdown(tester, c);
  });

  testWidgets('EM-5: número com vírgula com valor absurdo sugere palavras trocadas (CDAB)', (tester) async {
    final c = await boot(tester);
    // 75,25 gravado em CDAB: lido na ordem padrão vira lixo (~−2,4 × 10⁻⁴¹).
    final f = ByteData(4)..setFloat32(0, 75.25);
    demoMemory().pokeRegisters(ModbusArea.holdingRegister, 610, [f.getUint16(2), f.getUint16(0)]);
    await open(tester);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Pressão do óleo');
    await tapKey(tester, 'opcao-TagDataType.float32');
    await tester.enterText(find.byKey(const ValueKey('campo-endereco')), '610');
    await live(tester, 1500);
    expect(find.byKey(const ValueKey('sugestao-ordem')), findsOneWidget);
    expect(find.textContaining('palavras trocadas (CDAB)'), findsOneWidget);

    await tapKey(tester, 'sugestao-ordem', wait: 1500);
    expect(inLive('75'), findsOneWidget);
    expect(find.byKey(const ValueKey('sugestao-ordem')), findsNothing);
    await tapKey(tester, 'salvar-variavel', wait: 600);
    expect(c.project.tags.firstWhere((t) => t.name == 'Pressão do óleo').byteOrder, ByteOrder.cdab);
    await shutdown(tester, c);
  });

  testWidgets('EM-6: endereço acima de 65535 tem erro próprio no campo e no "Lendo agora"', (tester) async {
    final c = await boot(tester);
    await open(tester);
    await tester.enterText(find.byKey(const ValueKey('campo-endereco')), '70000');
    await live(tester, 300);
    expect(find.text('Endereço acima de 65535'), findsNWidgets(2)); // no campo e no painel
    expect(find.text('Complete equipamento e endereço'), findsNothing);

    // Com cara de notação de manual, a sugestão azul explica — sem erro vermelho no campo.
    await tester.enterText(find.byKey(const ValueKey('campo-endereco')), '400101');
    await live(tester, 300);
    expect(find.byKey(const ValueKey('sugestao-endereco')), findsOneWidget);
    expect(find.text('Endereço acima de 65535'), findsOneWidget);
    await tapKey(tester, 'sugestao-endereco');
    expect(fieldText(tester, 'campo-endereco'), '100');
    expect(find.text('Endereço acima de 65535'), findsNothing);
    await shutdown(tester, c);
  });

  testWidgets('EM-7: endereço em hexadecimal (0x2000, 1F4h ou modo hex) mostra o decimal e grava certo', (tester) async {
    final c = await boot(tester);
    await open(tester);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Frequência');
    await tester.enterText(find.byKey(const ValueKey('campo-endereco')), '0x2000');
    await live(tester, 300);
    expect(find.text('= 8192'), findsOneWidget);
    expect(find.text('HR 8192'), findsOneWidget); // o painel já lê o endereço convertido
    await tester.enterText(find.byKey(const ValueKey('campo-endereco')), '1F4h');
    await live(tester, 300);
    expect(find.text('= 500'), findsOneWidget);

    // Modo hexadecimal em "Mais opções": o que já estava escrito vira hexa.
    await openMore(tester);
    await reveal(tester, find.byKey(const ValueKey('endereco-hex')));
    await tapKey(tester, 'endereco-hex');
    expect(find.textContaining('endereço em hex'), findsOneWidget); // resumo de "Mais opções"
    await reveal(tester, find.byKey(const ValueKey('campo-endereco')), up: true);
    expect(fieldText(tester, 'campo-endereco'), '1F4');
    expect(find.text('Endereço (hex)'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('campo-endereco')), '2A');
    await live(tester, 300);
    expect(find.text('= 42'), findsOneWidget);

    await tapKey(tester, 'salvar-variavel', wait: 600);
    expect(c.project.tags.firstWhere((t) => t.name == 'Frequência').address, 42);
    await shutdown(tester, c);
  });

  testWidgets('EM-8: bit de registrador de entrada (só leitura) lê o bit certo e grava como IR', (tester) async {
    final c = await boot(tester);
    demoMemory().pokeRegister(ModbusArea.inputRegister, 5, 1 << 2);
    await open(tester);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Falha do inversor');
    await tapKey(tester, 'opcao-TagDataType.bool');
    expect(find.byKey(const ValueKey('bit-em-registrador-entrada')), findsNothing, reason: 'só aparece para bit de palavra');
    await tapKey(tester, 'opcao-_Where.bitInRegister');
    await tapKey(tester, 'bit-em-registrador-entrada');
    await tapKey(tester, 'opcao-_Where.bitInRegister'); // tocar de novo no cartão não desfaz a escolha
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('bit-em-registrador-entrada'))).selected, isTrue);
    await tester.enterText(find.byKey(const ValueKey('campo-endereco')), '5');
    await reveal(tester, find.byKey(const ValueKey('campo-bit')));
    await tester.enterText(find.byKey(const ValueKey('campo-bit')), '2');
    await live(tester, 1500);
    expect(inLive('LIGADO'), findsOneWidget);
    expect(find.text('IR 5.2'), findsOneWidget);
    await reveal(tester, find.byKey(const ValueKey('pode-gravar')));
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('pode-gravar'))).onChanged, isNull);

    await tapKey(tester, 'salvar-variavel', wait: 600);
    final t = c.project.tags.firstWhere((t) => t.name == 'Falha do inversor');
    expect(t.area, ModbusArea.inputRegister);
    expect(t.dataType, TagDataType.bool);
    expect(t.bitIndex, 2);
    expect(t.canWrite, isFalse);

    // Reaberta, volta com o mesmo "onde fica".
    await open(tester, tag: t);
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('bit-em-registrador-entrada'))).selected, isTrue);
    await shutdown(tester, c);
  });

  testWidgets('EM-10: erro em "Mais opções" fechado abre o painel e rola até o campo; nome vazio rola para cima', (tester) async {
    final c = await boot(tester);
    await open(tester);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Pressão');
    await openMore(tester);
    await tapKey(tester, 'escala-outra');
    await tester.enterText(find.byKey(const ValueKey('campo-fator')), '0');
    await live(tester, 200);
    await reveal(tester, find.text('Mais opções'), up: true);
    await tester.tap(find.text('Mais opções')); // fecha
    await live(tester, 600);
    expect(find.byKey(const ValueKey('campo-fator')), findsNothing);

    await tapKey(tester, 'salvar-variavel', wait: 1200);
    expect(find.byType(TagFormPage), findsOneWidget, reason: 'não salvou');
    expect(find.text('Não pode ser zero'), findsOneWidget);
    final screenH = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final factor = tester.getRect(find.byKey(const ValueKey('campo-fator')));
    expect(factor.top, greaterThan(0));
    expect(factor.bottom, lessThan(screenH));
    expect(c.project.tags.where((t) => t.name == 'Pressão'), isEmpty);

    // Corrige o fator e esquece o nome: volta lá para cima.
    await tester.enterText(find.byKey(const ValueKey('campo-fator')), '2');
    await reveal(tester, find.byKey(const ValueKey('campo-nome-variavel')), up: true);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), '');
    await reveal(tester, find.byKey(const ValueKey('endereco-hex')));
    await tapKey(tester, 'salvar-variavel', wait: 1200);
    expect(find.text('Dê um nome'), findsOneWidget);
    final name = tester.getRect(find.byKey(const ValueKey('campo-nome-variavel')));
    expect(name.top, greaterThan(0));
    expect(name.bottom, lessThan(screenH));
    await shutdown(tester, c);
  });

  testWidgets('EM-11: casas decimais com − / + (0 a 6) e atalhos de unidade', (tester) async {
    final c = await boot(tester);
    await open(tester);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Corrente');
    await openMore(tester);
    await reveal(tester, find.byKey(const ValueKey('unidade-A')));
    await tapKey(tester, 'unidade-A');
    expect(fieldText(tester, 'campo-unidade'), 'A');

    await reveal(tester, find.byKey(const ValueKey('decimais-mais')));
    IconButton btn(String k) => tester.widget<IconButton>(find.byKey(ValueKey(k)));
    String decimals() => tester.widget<Text>(find.byKey(const ValueKey('casas-decimais'))).data!;
    expect(btn('decimais-menos').onPressed, isNull);
    for (var i = 0; i < 6; i++) {
      await tapKey(tester, 'decimais-mais', wait: 100);
    }
    expect(decimals(), '6');
    expect(btn('decimais-mais').onPressed, isNull, reason: 'para em 6');
    for (var i = 0; i < 4; i++) {
      await tapKey(tester, 'decimais-menos', wait: 100);
    }
    expect(decimals(), '2');
    expect(find.text('Ex.: 75,25'), findsOneWidget);

    await tapKey(tester, 'salvar-variavel', wait: 600);
    final t = c.project.tags.firstWhere((t) => t.name == 'Corrente');
    expect(t.unit, 'A');
    expect(t.decimals, 2);
    await shutdown(tester, c);
  });

  testWidgets('EM-12: com 4 ou mais equipamentos a escolha vira uma linha com lista; com 8, ganha busca', (tester) async {
    final c = await boot(tester);
    final extras = [for (var i = 1; i <= 7; i++) Device(id: 'eq$i', name: 'Prensa $i', kind: DeviceKind.demo)];
    for (final d in extras.take(3)) {
      c.saveDevice(d);
    }
    await live(tester, 600);

    await open(tester, preferDeviceId: DemoProject.deviceId);
    expect(find.byKey(const ValueKey('opcao-${DemoProject.deviceId}')), findsNothing, reason: 'sem pilha de cartões');
    final row = find.byKey(const ValueKey('escolher-equipamento'));
    expect(find.descendant(of: row, matching: find.text('Cortadora de rótulos')), findsOneWidget);
    await tester.tap(row);
    await live(tester, 700);
    expect(find.byKey(const ValueKey('buscar-equipamento')), findsNothing, reason: 'busca só a partir de 8');
    await tapKey(tester, 'equipamento-eq2', wait: 700);
    expect(find.descendant(of: row, matching: find.text('Prensa 2')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Força');
    await tapKey(tester, 'salvar-variavel', wait: 600);
    expect(c.project.tags.firstWhere((t) => t.name == 'Força').deviceId, 'eq2');

    for (final d in extras.skip(3)) {
      c.saveDevice(d);
    }
    await live(tester, 600);
    await open(tester, preferDeviceId: DemoProject.deviceId);
    await tester.tap(row);
    await live(tester, 700);
    await tester.enterText(find.byKey(const ValueKey('buscar-equipamento')), 'prensa 6');
    await live(tester, 300);
    expect(find.byKey(const ValueKey('equipamento-eq6')), findsOneWidget);
    expect(find.byKey(const ValueKey('equipamento-eq5')), findsNothing);
    await shutdown(tester, c);
    // A leitura avulsa ("Lendo agora") liga a máquina simulada de cada
    // equipamento escolhido; aqui, sem tela aberta, ninguém a desliga.
    for (final d in extras) {
      DemoRegistry.discard(d.id);
    }
  });

  // ── Perfil de fabricante no cadastro (MP-3 e MP-4) ─────────────────────────

  const h3u = Device(id: 'h3u', name: 'CLP H3U', kind: DeviceKind.demo, profile: 'inovance-h3u');

  Future<ProjectController> bootWithProfile(WidgetTester tester) async {
    final c = await boot(tester);
    c.saveDevice(h3u);
    await live(tester, 600);
    return c;
  }

  Future<void> typeMemory(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('campo-memoria')), text);
    await live(tester, 300);
  }

  testWidgets('MP-3: com marca e modelo, "D200" preenche o endereço, e a variável guarda e mantém a memória', (tester) async {
    final c = await bootWithProfile(tester);
    final d200 = VendorProfiles.inovanceH3u.parse('D200');

    await open(tester, preferDeviceId: h3u.id);
    expect(find.byKey(const ValueKey('campo-memoria')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Pressão');
    await typeMemory(tester, 'd200');
    expect(find.text(d200.proof), findsOneWidget, reason: 'a linha de prova: D200 → Holding 200');
    expect(find.byKey(const ValueKey('campo-endereco')), findsNothing, reason: 'com perfil, o endereço Modbus mora em Mais opções');
    await reveal(tester, find.text('Mais opções'));
    expect(find.descendant(of: find.byType(ExpansionTile), matching: find.text('HR ${d200.address}')), findsOneWidget, reason: 'o resumo fechado mostra o endereço');
    await openMore(tester);
    await reveal(tester, find.byKey(const ValueKey('campo-endereco')));
    expect(fieldText(tester, 'campo-endereco'), '${d200.address}');
    await tapKey(tester, 'salvar-variavel', wait: 600);
    var tag = c.project.tags.firstWhere((t) => t.name == 'Pressão');
    expect((tag.memory, tag.area, tag.address), ('D200', ModbusArea.holdingRegister, d200.address));

    // Editar outro campo não apaga o "D200" (antes, salvar pelo formulário zerava).
    await open(tester, tag: tag);
    expect(fieldText(tester, 'campo-memoria'), 'D200');
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Pressão da linha');
    await tapKey(tester, 'salvar-variavel', wait: 600);
    tag = c.project.tag(tag.id)!;
    expect((tag.name, tag.memory), ('Pressão da linha', 'D200'));

    // Mexer no endereço Modbus à mão: a memória acompanha, sem "D200" falso.
    await open(tester, tag: tag);
    await openMore(tester);
    await reveal(tester, find.byKey(const ValueKey('campo-endereco')));
    await tester.enterText(find.byKey(const ValueKey('campo-endereco')), '${d200.address + 1}');
    await live(tester, 300);
    await reveal(tester, find.byKey(const ValueKey('campo-memoria')), up: true);
    expect(fieldText(tester, 'campo-memoria'), 'D201');
    await tapKey(tester, 'salvar-variavel', wait: 600);
    expect(c.project.tag(tag.id)!.memory, 'D201');
    await shutdown(tester, c);
    DemoRegistry.discard(h3u.id);
  });

  testWidgets('MP-3: M vira liga/desliga, X conta em octal e é só leitura, 32 bits no último D é recusado', (tester) async {
    final c = await bootWithProfile(tester);
    await open(tester, preferDeviceId: h3u.id);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Entrada 8');

    await typeMemory(tester, 'X8');
    expect(find.textContaining('octal'), findsOneWidget);

    await typeMemory(tester, 'X10');
    await reveal(tester, find.byKey(const ValueKey('pode-gravar')));
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('pode-gravar'))).onChanged, isNull,
        reason: 'entrada física exposta como coil: o perfil diz que é só leitura');
    await tapKey(tester, 'salvar-variavel', wait: 600);
    final x10 = c.project.tags.firstWhere((t) => t.name == 'Entrada 8');
    final ref = VendorProfiles.inovanceH3u.parse('X10');
    expect((x10.memory, x10.dataType, x10.area, x10.address, x10.writable), ('X10', TagDataType.bool, ModbusArea.coil, ref.address, false));

    await open(tester, preferDeviceId: h3u.id);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Relé 100');
    await typeMemory(tester, 'M100');
    await tapKey(tester, 'salvar-variavel', wait: 600);
    final m100 = c.project.tags.firstWhere((t) => t.name == 'Relé 100');
    expect((m100.memory, m100.dataType, m100.area, m100.address), ('M100', TagDataType.bool, ModbusArea.coil, 100));

    // FLOAT32 no último D ocuparia o D seguinte, que não existe.
    await open(tester, preferDeviceId: h3u.id);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Vazão');
    await tapKey(tester, 'opcao-${TagDataType.float32}');
    await typeMemory(tester, 'D8511');
    expect(find.textContaining('ocuparia D8512'), findsOneWidget);
    await tapKey(tester, 'salvar-variavel', wait: 600);
    expect(c.project.tags.where((t) => t.name == 'Vazão'), isEmpty);
    await shutdown(tester, c);
    DemoRegistry.discard(h3u.id);
  });

  testWidgets('MP-4: com perfil, 40101 é endereço (sem sugestão de notação de manual); no genérico, sugere', (tester) async {
    final c = await bootWithProfile(tester);
    Future<void> type40101({bool inMore = false}) async {
      if (inMore) await openMore(tester);
      await reveal(tester, find.byKey(const ValueKey('campo-endereco')));
      await tester.enterText(find.byKey(const ValueKey('campo-endereco')), '40101');
      await live(tester, 300);
    }

    await open(tester, preferDeviceId: h3u.id);
    await type40101(inMore: true);
    expect(find.byKey(const ValueKey('sugestao-endereco')), findsNothing);
    await reveal(tester, find.byKey(const ValueKey('campo-memoria')), up: true);
    expect(fieldText(tester, 'campo-memoria'), isNot(isEmpty), reason: 'o perfil dá nome ao endereço digitado');
    await tester.pageBack();
    await live(tester, 400);
    await tapKey(tester, 'descartar', wait: 600);

    await open(tester, preferDeviceId: DemoProject.deviceId);
    expect(find.byKey(const ValueKey('campo-memoria')), findsNothing);
    await type40101();
    expect(find.byKey(const ValueKey('sugestao-endereco')), findsOneWidget);
    await shutdown(tester, c);
    DemoRegistry.discard(h3u.id);
  });
}

/// Avança o relógio simulado em passos de 100 ms (varredura e demo andam).
Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
