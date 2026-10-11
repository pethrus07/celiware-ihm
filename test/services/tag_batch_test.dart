import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/models/alarm.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/models/vendor_profiles.dart';
import 'package:ihm/services/import/tag_batch.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';

const _h3u = Device(id: 'clp', name: 'CLP', host: '10.0.0.1', profile: 'inovance-h3u');
const _ivc1 = Device(id: 'ivc', name: 'IVC1', host: '10.0.0.2', profile: 'invt-ivc1');
const _generic = Device(id: 'gen', name: 'Genérico', host: '10.0.0.3');
const _md500 = Device(id: 'inv', name: 'Inversor', host: '10.0.0.4', profile: 'inovance-md500');
const _project = Project(devices: [_h3u, _ivc1, _generic, _md500]);

BatchArea _area(Device d, String chip) => TagBatchBuilder.areasFor(VendorProfiles.of(d)).firstWhere((a) => a.chip == chip);

TagBatch _range(Device d, String chip, String from, String to,
        {TagDataType type = TagDataType.uint16, String prefix = '', bool writable = false, Project project = _project, bool noEeprom = false}) =>
    TagBatchBuilder.range(project: project, device: d, area: _area(d, chip), from: from, to: to, type: type, namePrefix: prefix, writable: writable, noEeprom: noEeprom);

Matcher _error(Object message) => throwsA(isA<BatchError>().having((e) => e.message, 'mensagem', message));

TagBatch _csv(String text, {Device device = _h3u, List<int>? bytes, Project project = _project}) =>
    TagBatchBuilder.csv(project: project, device: device, bytes: bytes ?? utf8.encode(text));

void main() {
  group('faixa (IF-1)', () {
    test('D0 até D9: dez variáveis com o nome da própria memória', () {
      final b = _range(_h3u, 'D', '0', '9');
      expect(b.count, 10);
      expect(b.items.map((i) => i.tag.name), [for (var n = 0; n < 10; n++) 'D$n']);
      expect(b.items.map((i) => i.tag.address), [for (var n = 0; n < 10; n++) n]);
      expect(b.items.first.tag.memory, 'D0');
      expect(b.items.every((i) => i.tag.area == ModbusArea.holdingRegister && !i.tag.writable), isTrue);
    });

    test('32 bits anda de 2 em 2 e usa a ordem da marca (CDAB)', () {
      final b = _range(_h3u, 'D', 'D0', 'D9', type: TagDataType.int32);
      expect(b.items.map((i) => i.tag.memory), ['D0', 'D2', 'D4', 'D6', 'D8']);
      expect(b.items.map((i) => i.tag.address), [0, 2, 4, 6, 8]);
      expect(b.items.every((i) => i.tag.byteOrder == ByteOrder.cdab), isTrue);
    });

    test('X0 até X17 em octal dá 16 entradas, sempre só leitura', () {
      final b = _range(_h3u, 'X', '0', '17', writable: true);
      expect(b.count, 16);
      expect(b.items.last.tag.memory, 'X17');
      expect(b.items.last.tag.address, 0xF800 + 15);
      expect(b.items.every((i) => i.tag.dataType == TagDataType.bool && !i.tag.writable), isTrue);
    });

    test('X8 na faixa é recusado com a explicação do octal', () {
      expect(() => _range(_h3u, 'X', '0', '8'), _error('X8 não existe — X conta em octal: X7, X10'));
    });

    test('nome com prefixo: texto + número da memória', () {
      expect(_range(_h3u, 'D', '200', '201', prefix: 'Temperatura').items.map((i) => i.tag.name), ['Temperatura 200', 'Temperatura 201']);
      expect(_range(_h3u, 'Y', '10', '10', prefix: 'Saída-').items.single.tag.name, 'Saída-10');
    });

    test('contador de 32 bits: número anda de 1, endereço de 2, tipo INT32', () {
      final b = _range(_h3u, 'C · 32 bits', '200', '203');
      expect(b.items.map((i) => i.tag.address), [0xF700, 0xF702, 0xF704, 0xF706]);
      expect(b.items.every((i) => i.tag.dataType == TagDataType.int32), isTrue);
    });

    test('faixa que passa do fim da área ou cai no buraco entre trechos é recusada', () {
      expect(() => _range(_ivc1, 'D', '7990', '8000'), _error('D8000 não existe neste CLP: D vai de D0 a D7999.'));
      expect(() => _range(_h3u, 'M', '7670', '7690'), _error(contains('M7680 não existe')));
      expect(() => _range(_h3u, 'C · valor', '190', '210'), _error(contains('C200 não existe em "C · valor"')));
    });

    test('32 bits precisa da memória seguinte, existindo e ao lado', () {
      expect(() => _range(_ivc1, 'D', '7998', '7999', type: TagDataType.int32), returnsNormally);
      // D7999 + 1 seria SD0 no mapa Modbus: não pode.
      expect(() => _range(_ivc1, 'D', '7999', '7999', type: TagDataType.int32), _error(contains('ocuparia D8000')));
      // SD255 está em 8255 e SD256 em 12000.
      expect(() => _range(_ivc1, 'SD', '255', '255', type: TagDataType.int32), _error(contains('não ficam lado a lado')));
    });

    test('fim antes do começo e campo vazio', () {
      expect(() => _range(_h3u, 'D', '10', '5'), _error(contains('vem antes')));
      expect(() => _range(_h3u, 'D', '', '5'), _error(contains('Falta')));
      expect(() => _range(_h3u, 'D', 'abc', '5'), _error(contains('não é um número')));
    });

    test('genérico: endereço Modbus a partir de 0, sem memória', () {
      final b = _range(_generic, ModbusArea.holdingRegister.label, '100', '104');
      expect(b.items.map((i) => i.tag.name), ['HR 100', 'HR 101', 'HR 102', 'HR 103', 'HR 104']);
      expect(b.items.every((i) => i.tag.memory == null), isTrue);
      final coils = _range(_generic, ModbusArea.coil.label, '0x10', '0x11');
      expect(coils.items.map((i) => (i.tag.address, i.tag.dataType)), [(16, TagDataType.bool), (17, TagDataType.bool)]);
    });

    test('ids únicos mesmo com mil de uma vez', () {
      final b = _range(_h3u, 'D', '0', '999');
      expect(b.items.map((i) => i.tag.id).toSet(), hasLength(1000));
    });
  });

  group('limites (IF-4)', () {
    test('aviso a partir de 256; teto de 1000', () {
      expect(_range(_h3u, 'D', '0', '254').large, isFalse);
      expect(_range(_h3u, 'D', '0', '255').large, isTrue);
      expect(_range(_h3u, 'D', '0', '999').count, 1000);
      expect(() => _range(_h3u, 'D', '0', '1000'), _error(contains('o máximo é 1000')));
      // O teto vale antes de gerar: R0–R32767 não monta 32 mil variáveis para recusar.
      expect(() => _range(_h3u, 'R', '0', '32767'), _error(contains('São 32768')));
    });

    test('leituras por ciclo: 1000 D = 8 leituras; 1000 M = 1', () {
      expect(_range(_h3u, 'D', '0', '999').readsPerCycle, 8);
      expect(_range(_h3u, 'M', '0', '999').readsPerCycle, 1);
      // Dois trechos do M do INVT ficam longe no Modbus: viram leituras separadas.
      expect(_range(_ivc1, 'M', '2040', '2055').readsPerCycle, 2);
    });
  });

  group('conflitos', () {
    final existing = Tag(
      id: 'ja',
      name: 'Temperatura do forno',
      deviceId: _h3u.id,
      address: 5,
      alarms: const [AlarmRule(id: 'a1', kind: AlarmKind.above, limit: 80)],
    );
    final project = _project.copyWith(tags: [existing]);

    test('mesmo endereço no mesmo equipamento é conflito', () {
      final b = _range(_h3u, 'D', '0', '9', project: project);
      expect(b.conflicts, 1);
      expect(b.items[5].existing!.id, 'ja');
      // Outro equipamento com o mesmo endereço não conta.
      expect(_range(_ivc1, 'D', '0', '9', project: project).conflicts, 0);
    });

    test('pular deixa a que existe; substituir mantém id e alarmes', () {
      final b = _range(_h3u, 'D', '0', '9', type: TagDataType.int16, project: project);
      final skip = b.resolve(ConflictPolicy.skip);
      expect(skip, hasLength(9));
      expect(skip.any((t) => t.address == 5), isFalse);
      final replace = b.resolve(ConflictPolicy.replace);
      expect(replace, hasLength(10));
      final over = replace.firstWhere((t) => t.address == 5);
      expect((over.id, over.name, over.dataType, over.memory), ('ja', 'D5', TagDataType.int16, 'D5'));
      expect(over.alarms.single.id, 'a1');
    });

    test('bit de registrador só conflita com o mesmo bit', () {
      final bits = _project.copyWith(tags: [Tag(id: 'b', name: 'b', deviceId: _h3u.id, address: 0, dataType: TagDataType.bool, bitIndex: 3)]);
      expect(_range(_h3u, 'D', '0', '0', project: bits).conflicts, 0);
    });
  });

  group('inversor', () {
    test('faixa de parâmetros num grupo só', () {
      final b = _range(_md500, 'Parâmetros', 'F0-00', 'F0-03');
      expect(b.items.map((i) => i.tag.address), [0xF000, 0xF001, 0xF002, 0xF003]);
      expect(b.items.map((i) => i.tag.memory), ['F0-00', 'F0-01', 'F0-02', 'F0-03']);
      expect(() => _range(_md500, 'Parâmetros', 'F0-00', 'F1-03'), _error(contains('grupo só')));
    });

    test('sem EEPROM: endereço da RAM, só para gravar', () {
      final b = _range(_md500, 'Parâmetros', 'F3-12', 'F3-12', noEeprom: true);
      final t = b.items.single.tag;
      expect((t.address, t.memory, t.writable), (0x030C, 'F3-12 (RAM)', true));
      expect(t.description, contains('não deixa ler'));
    });

    test('modelos prontos com um toque', () {
      final b = TagBatchBuilder.templates(project: _project, device: _md500, templates: VendorProfiles.inovanceMd500.templates);
      expect(b.items.map((i) => (i.tag.name, i.tag.address)), [
        ('Comando', 0x2000),
        ('Referência de frequência', 0x1000),
        ('Estado', 0x3000),
        ('Falha', 0x8000),
      ]);
      expect(b.items.first.tag.writable, isTrue);
    });
  });

  group('CSV (IF-5)', () {
    test('ponto e vírgula, UTF-8 com BOM, cabeçalho, escala com vírgula', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode('memoria;nome;tipo;gravavel;unidade;escala;descricao\r\nD200;Temperatura;int16;sim;°C;0,1;forno\r\nX10;Porta;;;;;\r\n')];
      final b = _csv('', bytes: bytes);
      expect(b.errors, isEmpty);
      expect(b.count, 2);
      final t = b.items.first.tag;
      expect((t.name, t.address, t.dataType, t.writable, t.unit, t.scale, t.description, t.memory), ('Temperatura', 200, TagDataType.int16, true, '°C', 0.1, 'forno', 'D200'));
      final x = b.items.last.tag;
      expect((x.area, x.address, x.dataType, x.memory), (ModbusArea.coil, 0xF800 + 8, TagDataType.bool, 'X10'));
    });

    test('vírgula como separador, aspas com vírgula dentro, colunas fora de ordem', () {
      final b = _csv('nome,memoria,escala\n"Pressão, linha 2",D1,"0,5"\n"Diz ""oi""",D2,÷10\n');
      expect(b.errors, isEmpty);
      expect(b.items.map((i) => (i.tag.name, i.tag.address, i.tag.scale)), [('Pressão, linha 2', 1, 0.5), ('Diz "oi"', 2, 0.1)]);
    });

    test('sem cabeçalho: colunas na ordem do modelo; só a memória é obrigatória', () {
      final b = _csv('D1;Velocidade;float32\nD10\n');
      expect(b.items.map((i) => (i.tag.name, i.tag.dataType)), [('Velocidade', TagDataType.float32), ('D10', TagDataType.uint16)]);
    });

    test('relatório por linha: a linha ruim fica de fora, as boas seguem', () {
      final b = _csv([
        'memoria;nome;tipo;gravavel', // 1
        'D1;Boa', // 2
        'X8;Octal', // 3
        'D2;Tipo errado;abc', // 4
        'D1;Repetida', // 5
        'M10;Bit;int16', // 6
        'X1;Entrada;;sim', // 7
        'D5;Gravável;;talvez', // 8
        ';Sem memória', // 9
        'D20.3;Bit de palavra', // 10
      ].join('\n'));
      expect(b.items.map((i) => i.tag.name), ['Boa', 'Bit de palavra']);
      expect(b.items.last.tag.bitIndex, 3);
      final byLine = {for (final e in b.errors) e.line: e.message};
      expect(byLine.keys, [3, 4, 5, 6, 7, 8, 9]);
      expect(byLine[3], '"X8": X8 não existe — X conta em octal: X7, X10');
      expect(byLine[4], contains('tipo "abc" desconhecido'));
      expect(byLine[5], 'repete a memória da linha 2');
      expect(byLine[6], contains('é bit'));
      expect(byLine[7], contains('só leitura'));
      expect(byLine[8], contains('sim ou não'));
      expect(byLine[9], 'falta a memória');
      expect(b.errors.first.text, startsWith('Linha 3: '));
    });

    test('arquivo do Excel sem UTF-8 (Latin-1) mantém os acentos', () {
      final b = _csv('', bytes: latin1.encode('memoria;nome\nD1;Pressão da linha\n'));
      expect(b.items.single.tag.name, 'Pressão da linha');
    });

    test('genérico aceita HR 200 e a notação de manual; com perfil, 40201 é erro', () {
      final g = _csv('memoria;nome\nHR 200;A\n40202;B\nCOIL 3;C\n', device: _generic);
      expect(g.errors, isEmpty);
      expect(g.items.map((i) => (i.tag.area, i.tag.address, i.tag.memory)), [
        (ModbusArea.holdingRegister, 200, null),
        (ModbusArea.holdingRegister, 201, null),
        (ModbusArea.coil, 3, null),
      ]);
      final p = _csv('memoria\n40201\nHR 7\n');
      expect(p.errors.single.line, 2);
      expect(p.items.single.tag.address, 7);
    });

    test('contato ou valor: sem tipo pergunta; contador de 32 bits só aceita 32 bits', () {
      final b = _csv('memoria;nome;tipo\nC200;Peças;int32\nC201;Errado;int16\nC202;Sem tipo;\nC5;Contato;bool\n');
      expect(b.items.map((i) => (i.tag.name, i.tag.dataType, i.tag.area)), [
        ('Peças', TagDataType.int32, ModbusArea.holdingRegister),
        ('Contato', TagDataType.bool, ModbusArea.coil),
      ]);
      final byLine = {for (final e in b.errors) e.line: e.message};
      expect(byLine[3], contains('contador de 32 bits'));
      expect(byLine[4], 'C202 tem contato e valor: diga o tipo (BOOL para o contato, INT32 para o valor)');
    });

    test('conflito com o que já existe e teto de 1000', () {
      final project = _project.copyWith(tags: [Tag(id: 'ja', name: 'x', deviceId: _h3u.id, address: 1)]);
      expect(_csv('D1\nD2\n', project: project).conflicts, 1);
      final big = [for (var i = 0; i <= 1000; i++) 'D$i'].join('\n');
      expect(() => _csv(big), _error(contains('Divida o arquivo')));
    });
  });

  group('saveTags (IF-2)', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('ihm_lote'));
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {/* Windows ainda segurando o arquivo */}
    });

    test('mil variáveis = um aviso às telas e uma gravação', () async {
      final repo = _CountingRepository(dir);
      final runtime = HmiRuntime();
      final c = ProjectController(repository: repo, runtime: runtime);
      await c.load();
      final before = c.project.tags.length;
      final savesBefore = repo.saves;
      var notified = 0;
      c.addListener(() => notified++);

      final device = c.project.devices.first;
      final b = TagBatchBuilder.range(project: c.project, device: device, area: const ModbusAreaChoice(ModbusArea.holdingRegister), from: '0', to: '999');
      c.saveTags(b.resolve(ConflictPolicy.skip));
      expect(notified, 1);
      expect(c.project.tags.length, before + b.resolve(ConflictPolicy.skip).length);

      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(repo.saves - savesBefore, 1);
      final saved = await repo.load();
      expect(saved!.tags.length, c.project.tags.length);

      // Lista vazia não faz nada (nem grava).
      c.saveTags(const []);
      expect(notified, 1);

      // Mesmo id = substitui no lugar, sem duplicar.
      final first = c.project.tags.last;
      c.saveTags([first.copyWith(name: 'Renomeada')]);
      expect(c.project.tags.where((t) => t.id == first.id).single.name, 'Renomeada');
      expect(c.project.tags.length, saved.tags.length);

      c.dispose();
      await runtime.dispose();
    });
  });
}

class _CountingRepository extends ProjectRepository {
  _CountingRepository(Directory dir) : super(directory: dir);
  int saves = 0;

  @override
  Future<void> save(Project project) async {
    saves++;
    await super.save(project);
  }
}
