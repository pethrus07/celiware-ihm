import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_client_simulated.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/models/alarm.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/models/vendor_profiles.dart';
import 'package:ihm/services/import/tag_batch.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/tag_codec.dart';
import 'package:ihm/services/runtime/tag_store.dart';
import 'package:ihm/services/templates/screen_templates.dart';
import 'package:ihm/services/templates/template_builder.dart';
import 'package:ihm/widgets/hmi/element_catalog.dart';

import '../support/screen_checks.dart';

const _generic = Device(id: 'gen', name: 'Prensa', host: '10.0.0.3');
const _md500 = Device(id: 'md', name: 'Inversor da bomba', host: '10.0.0.4', profile: 'inovance-md500');
const _gd20 = Device(id: 'gd', name: 'Inversor da esteira', host: '10.0.0.5', profile: 'invt-gd20');
const _h3u = Device(id: 'clp', name: 'CLP', host: '10.0.0.1', profile: 'inovance-h3u');
const _project = Project(devices: [_generic, _md500, _gd20, _h3u]);

TemplateResult _build(ScreenTemplate t, Device d, {Project project = _project}) =>
    TemplateBuilder.build(t, project: project, device: d, screenId: 's1', name: t.name);

/// Os casos que a tela pode virar: cada modelo no genérico (bits) e, no de
/// inversor, também com o mapa de cada marca (palavra de comando).
List<(ScreenTemplate, Device)> get _cases => [
      for (final t in ScreenTemplates.all.where((t) => !t.isBlank)) ...[
        (t, _generic),
        if (t.driveMap) ...[(t, _md500), (t, _gd20)],
      ],
    ];

void main() {
  test('catálogo: "Em branco" primeiro, ids únicos e achados pelo id', () {
    expect(ScreenTemplates.all.first, same(ScreenTemplates.blank));
    final ids = ScreenTemplates.all.map((t) => t.id).toList();
    expect(ids.toSet().length, ids.length);
    expect(ids, containsAll(['maquina', 'inversor-basico', 'inversor-completo', 'servo-basico', 'servo-completo', 'leitor-codigo', 'temperatura', 'celula-carga', 'io-8', 'io-16']));
    for (final t in ScreenTemplates.all) {
      expect(ScreenTemplates.byId(t.id), same(t));
    }
  });

  test('em branco: a tela vazia de sempre, na grade normal, sem variável', () {
    final r = _build(ScreenTemplates.blank, _generic);
    expect(r.screen.columns, HmiScreen.defaultColumns);
    expect(r.screen.elements, isEmpty);
    expect(r.created, isEmpty);
    expect(r.reused, isEmpty);
  });

  group('cada modelo gera uma tela válida', () {
    for (final (t, d) in _cases) {
      test('${t.name} em ${d.name}', () {
        final r = _build(t, d);
        final s = r.screen;
        expect(s.columns, HmiScreen.fineColumns);
        expect(s.elements, isNotEmpty);
        final tags = {for (final x in [...r.created, ...r.reused]) x.id: x};
        expect(r.created.map((x) => x.id).toSet().length, r.created.length, reason: 'id de variável repetido');
        // Grade, mínimos, alvo de toque e a variável certa em cada elemento.
        final problems = templateScreenProblems(s, tags);
        expect(problems, isEmpty, reason: problems.join('\n'));

        // Nenhuma variável sobrando: todas aparecem em algum elemento.
        final used = s.tagIds;
        for (final x in r.created) {
          expect(used, contains(x.id), reason: '"${x.name}" criada sem elemento');
        }
      });
    }
  });

  group('sem mapa da marca', () {
    test('equipamento genérico: tudo nasce com o endereço a configurar, nada inventado', () {
      for (final t in ScreenTemplates.all.where((t) => !t.isBlank)) {
        final r = _build(t, _generic);
        expect(r.style, CommandStyle.bits, reason: t.name);
        expect(r.created, isNotEmpty);
        for (final x in r.created) {
          expect(x.addressPending, isTrue, reason: '${t.name}: ${x.name}');
          expect(x.address, 0, reason: 'só o padrão — o runtime não lê');
          expect(x.memory, isNull);
          expect(x.addressLabel, 'Endereço a configurar');
          expect(x.deviceId, _generic.id);
        }
        expect(r.mapped, 0);
        expect(r.pending, r.created.length);
        expect(r.profile, isNull);
      }
    });

    test('liga/desliga nasce em coil, número em holding; texto com o tamanho do modelo', () {
      final r = _build(ScreenTemplates.barcode, _generic);
      final code = r.created.firstWhere((t) => t.name == 'Último código lido');
      expect(code.dataType, TagDataType.string);
      expect(code.length, 16);
      final m = _build(ScreenTemplates.machine, _generic);
      expect(m.created.firstWhere((t) => t.name == 'Liga máquina').area, ModbusArea.coil);
      expect(m.created.firstWhere((t) => t.name == 'Velocidade').area, ModbusArea.holdingRegister);
    });

    test('servo nunca usa o mapa de inversor, mesmo num equipamento com perfil MD500', () {
      for (final t in [ScreenTemplates.servoBasic, ScreenTemplates.servoFull]) {
        final r = _build(t, _md500);
        expect(r.style, CommandStyle.bits);
        expect(r.created.every((x) => x.addressPending), isTrue, reason: t.name);
      }
    });

    test('inversor num CLP com perfil (H3U): o endereço depende do programa — a configurar', () {
      final r = _build(ScreenTemplates.inverterBasic, _h3u);
      expect(r.style, CommandStyle.bits);
      expect(r.created.every((x) => x.addressPending), isTrue);
    });
  });

  group('com o mapa da marca (MP-5)', () {
    Tag byMap(TemplateResult r, String key, VendorProfile p) {
      final t = p.templates.firstWhere((x) => x.key == key);
      return r.created.firstWhere((x) => x.area == ModbusArea.holdingRegister && x.address == t.address && !x.addressPending);
    }

    test('MD500: comando, referência, estado e falha com os endereços do manual; o resto a configurar', () {
      final r = _build(ScreenTemplates.inverterBasic, _md500);
      final p = VendorProfiles.inovanceMd500;
      expect(r.style, CommandStyle.word);
      expect(r.profile, same(p));
      for (final t in p.templates) {
        final x = byMap(r, t.key, p);
        expect(x.name, t.name);
        expect(x.writable, t.writable, reason: t.key);
        expect(x.scale, t.scale, reason: t.key);
        expect(x.unit, t.unit, reason: t.key);
      }
      expect(r.mapped, 4);
      final pending = r.created.where((x) => x.addressPending).map((x) => x.name);
      expect(pending, unorderedEquals(['Frequência de saída', 'Corrente do motor']));
      // Comando por bits fica de fora: a palavra de comando faz o papel.
      expect(r.created.map((x) => x.name), isNot(contains('Liga inversor')));
    });

    test('MD500: botões gravam 1 avante, 2 reverso, 6 parada em rampa e 7 reset; estados da marca', () {
      final r = _build(ScreenTemplates.inverterBasic, _md500);
      final comando = byMap(r, 'comando', VendorProfiles.inovanceMd500);
      final buttons = {
        for (final e in r.screen.elements.where((e) => e.type == ElementType.button)) e.props['label']: e,
      };
      expect(buttons.keys, unorderedEquals(['Avante', 'Reverso', 'Parar', 'Reset']));
      expect({for (final b in buttons.entries) b.key: b.value.props['value']}, {'Avante': 1, 'Reverso': 2, 'Parar': 6, 'Reset': 7});
      expect(buttons.values.every((b) => b.tagId == comando.id && b.props['mode'] == 'value'), isTrue);
      final estado = r.screen.elements.firstWhere((e) => e.props['label'] == 'Estado');
      expect(estado.tagId, byMap(r, 'estado', VendorProfiles.inovanceMd500).id);
      expect(estado.props['states'], ScreenTemplates.driveCodes['inovance-md500']!.states);
    });

    test('GD20: parar é 5 (parada em rampa) e o estado 4 é falha', () {
      final r = _build(ScreenTemplates.inverterBasic, _gd20);
      final parar = r.screen.elements.firstWhere((e) => e.props['label'] == 'Parar');
      expect(parar.props['value'], 5);
      final estado = r.screen.elements.firstWhere((e) => e.props['label'] == 'Estado');
      expect(estado.tagId, byMap(r, 'estado', VendorProfiles.invtGd20).id);
      expect((estado.props['states'] as List).map((s) => (s as Map)['text']), contains('FALHA'));
      expect(byMap(r, 'falha', VendorProfiles.invtGd20).address, 0x2102);
    });

    test('completo: rampas, torque, barramento, temperatura, horas e última falha a configurar', () {
      final r = _build(ScreenTemplates.inverterFull, _md500);
      expect(r.mapped, 4);
      expect(r.created.where((x) => x.addressPending).map((x) => x.name),
          containsAll(['Tempo de aceleração', 'Tempo de desaceleração', 'Torque', 'Tensão do barramento', 'Temperatura do inversor', 'Horas de operação', 'Código da última falha']));
      // O básico continua igual em cima; o completo acrescenta embaixo.
      final basic = _build(ScreenTemplates.inverterBasic, _md500).screen;
      expect(r.screen.elements.where((e) => e.y < basic.rows).length, basic.elements.length);
    });

    test('falha da marca ganha alarme alto (código acima de 0)', () {
      final r = _build(ScreenTemplates.inverterBasic, _md500);
      final falha = byMap(r, 'falha', VendorProfiles.inovanceMd500);
      expect(falha.alarms.single.kind, AlarmKind.above);
      expect(falha.alarms.single.limit, 0);
      expect(falha.alarms.single.priority, AlarmPriority.high);
    });
  });

  group('não duplica o que o equipamento já tem', () {
    test('mesmo endereço do mapa: usa a variável que existe', () {
      const comando = Tag(id: 'ja', name: 'Comando da bomba', deviceId: 'md', address: 0x2000, writable: true);
      final r = _build(ScreenTemplates.inverterBasic, _md500, project: _project.upsertTag(comando));
      expect(r.reused.map((t) => t.id), ['ja']);
      expect(r.created.where((t) => t.address == 0x2000 && !t.addressPending), isEmpty);
      final avante = r.screen.elements.firstWhere((e) => e.props['label'] == 'Avante');
      expect(avante.tagId, 'ja');
      expect(r.mapped, 3);
    });

    test('mesmo endereço em outro equipamento não conta', () {
      const outro = Tag(id: 'x', name: 'Comando', deviceId: 'gd', address: 0x2000, writable: true);
      final r = _build(ScreenTemplates.inverterBasic, _md500, project: _project.upsertTag(outro));
      expect(r.reused, isEmpty);
      expect(r.mapped, 4);
    });

    test('sem endereço no modelo: usa a de mesmo nome e mesmo jeito (sem acento, sem caixa)', () {
      const vel = Tag(id: 'v', name: 'velocidade', deviceId: 'gen', address: 100);
      const liga = Tag(id: 'l', name: 'Liga Maquina', deviceId: 'gen', area: ModbusArea.coil, dataType: TagDataType.bool, writable: true);
      // Mesmo nome, outro jeito (liga/desliga onde o modelo quer número): não serve.
      const prod = Tag(id: 'p', name: 'Produção', deviceId: 'gen', area: ModbusArea.coil, dataType: TagDataType.bool);
      final project = _project.upsertTag(vel).upsertTag(liga).upsertTag(prod);
      final r = _build(ScreenTemplates.machine, _generic, project: project);
      expect(r.reused.map((t) => t.id), unorderedEquals(['v', 'l']));
      expect(r.created.map((t) => t.name), contains('Produção'));
      expect(r.created.map((t) => t.name), isNot(contains('Velocidade')));
      final liga2 = r.screen.elements.firstWhere((e) => e.props['label'] == 'Liga');
      expect(liga2.tagId, 'l');
    });

    test('aplicar o mesmo modelo duas vezes no mesmo equipamento não cria nada na segunda', () {
      final first = _build(ScreenTemplates.loadCell, _generic);
      final project = _project.upsertTags(first.created);
      final second = _build(ScreenTemplates.loadCell, _generic, project: project);
      expect(second.created, isEmpty);
      expect(second.reused.length, first.created.length);
      expect(second.pending, first.created.length);
      expect(second.screen.tagIds, first.screen.tagIds);
    });
  });

  group('pedidos da reunião de 19/10/2026', () {
    test('"Reverso" no lugar de "Ré": botões, estados das marcas e descrições', () {
      for (final t in [ScreenTemplates.inverterBasic, ScreenTemplates.servoBasic]) {
        final labels = _build(t, _generic).screen.elements.map((e) => e.props['label']);
        expect(labels, contains('Reverso'), reason: t.name);
        expect(labels, isNot(contains('Ré')), reason: t.name);
      }
      for (final codes in ScreenTemplates.driveCodes.values) {
        final texts = codes.states.map((s) => s['text']);
        expect(texts, contains('REVERSO'));
        expect(texts, isNot(contains('RÉ')));
      }
      final sentido = _build(ScreenTemplates.inverterBasic, _generic).created.firstWhere((x) => x.name == 'Sentido reverso');
      expect(sentido.description, isNot(contains('ré')));
      for (final p in [VendorProfiles.inovanceMd500, VendorProfiles.invtGd20]) {
        for (final t in p.templates) {
          expect(t.description, isNot(matches(RegExp(r'\bré\b'))), reason: '${p.name}: ${t.key}');
        }
      }
    });

    test('Máquina: modo manual/automático só de leitura e o OEE calculado pelas três parcelas', () {
      final r = _build(ScreenTemplates.machine, _generic);
      final byName = {for (final t in r.created) t.name: t};
      final auto = byName['Em automático']!;
      expect(auto.dataType, TagDataType.bool);
      expect(auto.writable, isFalse, reason: 'o modo se troca no painel da máquina, não pela tela');
      final modo = r.screen.elements.singleWhere((e) => e.props['label'] == 'Modo');
      expect(modo.type, ElementType.multistate);
      expect(modo.tagId, auto.id);
      expect((modo.props['states'] as List).map((s) => (s as Map)['text']), ['MANUAL', 'AUTOMÁTICO']);

      final oee = r.screen.elements.singleWhere((e) => e.type == ElementType.oee);
      expect(oee.props['source'], 'calc');
      expect(oee.props['scale'], 'percent');
      expect(oee.props.containsKey('warn'), isFalse, reason: 'faixa não se inventa');
      expect(oee.tagIds.map((id) => r.created.firstWhere((t) => t.id == id).name), ['Disponibilidade', 'Desempenho', 'Qualidade']);
      expect(oee.w, HmiScreen.fineColumns, reason: 'largura toda, como o OEE nasce');
      // Continua com o que já tinha.
      expect(byName.keys, containsAll(['Estado da máquina', 'Liga máquina', 'Máquina em operação', 'Reset de alarme', 'Velocidade', 'Ajuste de velocidade', 'Produção', 'Alarme da máquina']));
      expect(r.screen.elements.where((e) => e.type == ElementType.button).map((e) => e.props['label']), unorderedEquals(['Liga', 'Reset']));
    });

    for (final (t, n) in [(ScreenTemplates.io8, 8), (ScreenTemplates.io16, 16)]) {
      test('I/O de CLP com $n entradas e $n saídas: uma lâmpada para cada, tudo a configurar', () {
        final r = _build(t, _generic);
        expect(r.created.length, 2 * n);
        expect(r.created.every((x) => x.addressPending && x.dataType == TagDataType.bool && !x.writable), isTrue);
        final inputs = r.created.where((x) => x.name.startsWith('Entrada ')).toList();
        final outputs = r.created.where((x) => x.name.startsWith('Saída ')).toList();
        expect(inputs.map((x) => x.name), [for (var i = 0; i < n; i++) 'Entrada E$i']);
        expect(outputs.map((x) => x.name), [for (var i = 0; i < n; i++) 'Saída S$i']);
        expect(inputs.every((x) => x.area == ModbusArea.discreteInput), isTrue, reason: 'entrada física');
        expect(outputs.every((x) => x.area == ModbusArea.coil), isTrue);
        final lamps = r.screen.elements.where((e) => e.type == ElementType.lamp).map((e) => e.props['label']).toList();
        expect(lamps, [for (var i = 0; i < n; i++) 'E$i', for (var i = 0; i < n; i++) 'S$i']);
        expect(r.screen.elements.where((e) => ElementCatalog.of(e.type).writes), isEmpty, reason: 'só para ver e ligar as memórias');
        // Toda saída abaixo de toda entrada.
        final lastInput = r.screen.elements.where((e) => e.tagId != null && inputs.any((x) => x.id == e.tagId)).map((e) => e.bottom).reduce((a, b) => a > b ? a : b);
        final firstOutput = r.screen.elements.where((e) => e.tagId != null && outputs.any((x) => x.id == e.tagId)).map((e) => e.y).reduce((a, b) => a < b ? a : b);
        expect(firstOutput, greaterThan(lastInput));
      });
    }

    test('I/O de 16 reaproveita as 8 do I/O de 8 no mesmo equipamento', () {
      final first = _build(ScreenTemplates.io8, _generic);
      final second = _build(ScreenTemplates.io16, _generic, project: _project.upsertTags(first.created));
      expect(second.reused.length, 16);
      expect(second.created.length, 16);
    });
  });

  test('temperatura: cada uma com alarme baixo e alto nos mesmos limites da faixa do medidor', () {
    final r = _build(ScreenTemplates.temperature, _generic);
    expect(r.created.length, 3);
    final alarmIds = [for (final t in r.created) ...t.alarms.map((a) => a.id)];
    expect(alarmIds.toSet().length, 6, reason: 'id de alarme repetido');
    for (final g in r.screen.elements.where((e) => e.type == ElementType.gauge)) {
      final t = r.created.firstWhere((x) => x.id == g.tagId);
      expect(t.alarms.map((a) => a.limit), [g.props['warn'], g.props['alarm']]);
      expect(t.alarms.map((a) => a.priority), [AlarmPriority.low, AlarmPriority.high]);
    }
    final trend = r.screen.elements.singleWhere((e) => e.type == ElementType.trend);
    expect(trend.tagIds.toSet(), r.created.map((t) => t.id).toSet());
  });

  group('endereço a configurar (Tag.addressPending)', () {
    test('vai e volta pelo arquivo do projeto; variável com endereço fica igual à de antes', () {
      final t = _build(ScreenTemplates.machine, _generic).created.first;
      expect(t.toJson()['addressPending'], isTrue);
      final back = Tag.fromJson(t.toJson());
      expect(back.addressPending, isTrue);
      expect(back.copyWith(name: 'Outro').addressPending, isTrue);
      expect(back.withMemory('D1').addressPending, isTrue);
      const plain = Tag(id: 'a', name: 'A', deviceId: 'd');
      expect(plain.toJson().containsKey('addressPending'), isFalse);
    });

    test('o runtime não lê nem grava: avisa "endereço a configurar" e não abre conexão', () async {
      final memory = ModbusMemory(holdingRegisters: 16, coils: 16);
      var connections = 0;
      final runtime = HmiRuntime(clientFactory: (_) {
        connections++;
        return SimulatedModbusClient(memory: memory, latency: Duration.zero);
      });
      final r = _build(ScreenTemplates.machine, _generic);
      await runtime.apply(Project(devices: const [_generic], tags: r.created));
      final liga = r.created.firstWhere((t) => t.name == 'Liga máquina');
      final sub = runtime.subscribe(r.created.map((t) => t.id));
      final reading = runtime.watch(liga.id).value;
      expect(reading.quality, TagQuality.configError);
      expect(reading.message, HmiRuntime.pendingMessage);
      expect(runtime.health(_generic.id), isNull, reason: 'nenhuma sessão para o equipamento');
      await expectLater(runtime.write(liga.id, true), throwsA(isA<TagValueError>()));
      await expectLater(runtime.readNow(liga), throwsA(isA<TagValueError>()), reason: 'receita e leitura avulsa também não leem o 0');
      await expectLater(runtime.press(liga.id), throwsA(isA<TagValueError>()));
      await runtime.release(liga.id);
      expect(memory.bit(ModbusArea.coil, 0), isFalse, reason: 'nada foi parar no endereço 0');
      expect(connections, 0);
      sub.cancel();
      await runtime.dispose();
    });

    test('"Criar várias" não acusa conflito com variável sem endereço (o HR 0 dela é só o padrão)', () {
      final r = _build(ScreenTemplates.machine, _generic);
      final project = _project.upsertTags(r.created);
      final batch = TagBatchBuilder.range(
        project: project,
        device: _generic,
        area: const ModbusAreaChoice(ModbusArea.coil),
        from: '0',
        to: '3',
      );
      expect(batch.conflicts, 0);
    });
  });
}
