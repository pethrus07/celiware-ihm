import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/models/alarm.dart';
import 'package:ihm/models/camera.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/models/log_group.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/alarms/alarm_engine.dart';
import 'package:ihm/services/cameras/camera_vault.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/logging/data_logger.dart';
import 'package:ihm/services/logging/log_store.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/tag_store.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Vários projetos no aparelho (reunião de 19–20/10/2026): o projeto único
/// das versões antigas vira o primeiro da lista sem perder nada, criar e
/// importar acrescentam (nunca substituem), apagar limpa o que era do
/// projeto, e o histórico de um projeto nunca vai para outro.
void main() {
  late Directory root;
  final sep = Platform.pathSeparator;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ihm_projetos');
    CameraVault.instance = MemoryCameraVault();
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo — é só a pasta temporária */}
  });

  File at(String path) => File('${root.path}$sep${path.replaceAll('/', sep)}');

  const demoDevice = Device(id: 'd1', name: 'Cortadora', host: '192.168.0.10');
  const speed = Tag(id: 't1', name: 'Velocidade', deviceId: 'd1');
  final cortadora = Project(name: 'Cortadora', devices: const [demoDevice], tags: const [speed], screens: const [HmiScreen(id: 's1', name: 'Operação')]);

  /// O que a 1.4.0 deixava na pasta: o projeto único e o que é dele.
  void writeLegacy() {
    at('projeto.ihm.json').writeAsBytesSync(ProjectRepository.encode(cortadora));
    at('historico-alarmes.json').writeAsStringSync('[{"at":"2026-10-19T10:00:00.000Z","type":"activated","priority":"high","message":"Porta aberta"}]');
    at('historico-regras.json').writeAsStringSync('[]');
    at('historico-receitas.json').writeAsStringSync('[]');
    Directory('${root.path}${sep}registros').createSync();
    at('registros/g1.db').writeAsStringSync('banco do grupo g1');
    at('registros/g1.db-wal').writeAsStringSync('diário');
  }

  Future<ProjectController> controller({HmiRuntime? runtime}) async {
    final c = ProjectController(library: PlantStore(root: root), runtime: runtime ?? HmiRuntime());
    await c.load();
    addTearDown(() async {
      await c.flush();
      c.dispose();
      await c.runtime.dispose();
    });
    return c;
  }

  group('migração do projeto único', () {
    test('vira o primeiro projeto, aberto, com históricos e registro — nada se perde', () async {
      writeLegacy();
      final c = await controller();

      expect(c.projects, hasLength(1));
      final id = c.projects.single.id;
      expect(id, PlantStore.legacyId);
      expect(c.openId, id);
      expect(c.project.name, 'Cortadora');
      expect(c.project.tags.single.name, 'Velocidade');
      expect(c.projects.single.summary, '1 equipamento · 1 variável · 1 tela');

      // Nada sobrou solto na raiz…
      expect(at('projeto.ihm.json').existsSync(), isFalse);
      expect(at('historico-alarmes.json').existsSync(), isFalse);
      expect(at('registros/g1.db').existsSync(), isFalse);
      // …e tudo está na pasta do projeto, byte a byte.
      expect(at('projetos/$id/projeto.ihm.json').readAsBytesSync(), ProjectRepository.encode(cortadora));
      expect(at('projetos/$id/historico-alarmes.json').readAsStringSync(), contains('Porta aberta'));
      expect(at('projetos/$id/historico-regras.json').existsSync(), isTrue);
      expect(at('projetos/$id/historico-receitas.json').existsSync(), isTrue);
      expect(at('registros/$id/g1.db').readAsStringSync(), 'banco do grupo g1');
      expect(at('registros/$id/g1.db-wal').existsSync(), isTrue);
      // O histórico de alarmes migrado é o que o motor lê no projeto aberto.
      expect((await c.repository.sidecar('historico-alarmes.json')).existsSync(), isTrue);
      expect((await c.repository.logsDirectory()).path, endsWith('registros$sep$id'));
    });

    test('app fechado no meio da migração: a próxima abertura termina sem duplicar', () async {
      writeLegacy();
      // Primeira tentativa parou depois de mover o histórico de alarmes.
      final dir = Directory('${root.path}${sep}projetos$sep${PlantStore.legacyId}')..createSync(recursive: true);
      at('historico-alarmes.json').renameSync('${dir.path}${sep}historico-alarmes.json');

      final c = await controller();
      expect(c.projects.map((e) => e.id), [PlantStore.legacyId]);
      expect(c.project.name, 'Cortadora');
      expect(at('projetos/${PlantStore.legacyId}/historico-alarmes.json').readAsStringSync(), contains('Porta aberta'));
    });

    test('primeira vez no aparelho: a demonstração é o primeiro projeto', () async {
      final c = await controller();
      expect(c.projects, hasLength(1));
      expect(c.project.screens, isNotEmpty);
      expect(at('projetos/${c.openId}/projeto.ihm.json').existsSync(), isTrue);
    });

    test('índice perdido se refaz pelas pastas', () async {
      writeLegacy();
      final c = await controller();
      final second = await c.createProject(const Project(name: 'Prensa'));
      await c.flush();
      at('projetos/planta.json').deleteSync();

      final again = PlantStore(root: root);
      await again.load();
      expect(again.entries.map((e) => e.name), ['Cortadora', 'Prensa']);
      expect(again.entry(second)?.name, 'Prensa');
    });
  });

  group('lista de projetos', () {
    test('criar acrescenta e abre; o projeto anterior fica intacto no disco', () async {
      writeLegacy();
      final c = await controller();
      final first = c.openId!;
      final id = await c.createProject(const Project(name: 'Meu projeto'));

      expect(c.openId, id);
      expect(c.project.isEmpty, isTrue);
      expect(c.projects.map((e) => e.name), ['Cortadora', 'Meu projeto']);
      final kept = await c.library!.repositoryFor(first).load();
      expect(kept?.name, 'Cortadora');
      expect(kept?.tags.single.id, 't1');
    });

    test('importar acrescenta (nunca substitui); nome repetido ganha número', () async {
      writeLegacy();
      final c = await controller();
      final file = ProjectRepository.decode(ProjectRepository.encode(cortadora.copyWith(cameras: const [IpCamera(id: 'c1', secretRef: 'cs_antiga')])));
      final id = await c.importProject(file);

      expect(c.projects, hasLength(2));
      expect(c.openId, id);
      expect(c.project.name, 'Cortadora (2)');
      expect(c.project.cameras.single.secretRef, isNot('cs_antiga'), reason: 'senha de câmera é pedida de novo');
      expect(c.projects.map((e) => e.name), ['Cortadora', 'Cortadora (2)']);
    });

    test('o último aberto abre de novo na próxima vez', () async {
      writeLegacy();
      final c = await controller();
      final id = await c.createProject(const Project(name: 'Prensa'));
      await c.flush();

      final next = await controller();
      expect(next.openId, id);
      expect(next.project.name, 'Prensa');
    });

    test('renomear e duplicar (com a senha da câmera numa chave nova)', () async {
      writeLegacy();
      final c = await controller();
      final first = c.openId!;
      final other = await c.createProject(const Project(name: 'Prensa', cameras: [IpCamera(id: 'c1', secretRef: 'cs_1')]));
      await CameraVault.instance.write('cs_1', 'segredo');
      await c.renameProject(first, 'Cortadora 2');
      expect(c.projects.map((e) => e.name), containsAll(['Cortadora 2', 'Prensa']));
      expect((await c.library!.repositoryFor(first).load())?.name, 'Cortadora 2');

      final copy = await c.duplicateProject(other);
      expect(c.openId, other, reason: 'duplicar não troca o projeto aberto');
      final dup = await c.library!.repositoryFor(copy).load();
      expect(dup?.name, 'Prensa (cópia)');
      final ref = dup!.cameras.single.secretRef!;
      expect(ref, isNot('cs_1'));
      expect(await CameraVault.instance.read(ref), 'segredo');
    });

    test('apagar: o aberto passa para outro, a pasta e o registro somem, o cofre limpa; o último não se apaga', () async {
      writeLegacy();
      final c = await controller();
      final legacy = c.openId!;
      final other = await c.createProject(const Project(name: 'Prensa', cameras: [IpCamera(id: 'c1', secretRef: 'cs_p')]));
      await CameraVault.instance.write('cs_p', 'x');
      await c.flush();
      expect(c.openId, other);

      await c.deleteProject(other);
      expect(c.openId, legacy);
      expect(c.projects.map((e) => e.id), [legacy]);
      expect(at('projetos/$other').existsSync(), isFalse);
      expect(await CameraVault.instance.read('cs_p'), isNull);

      await c.deleteProject(legacy);
      expect(c.projects, hasLength(1), reason: 'o app precisa de um projeto aberto');
      expect(at('projetos/$legacy/projeto.ihm.json').existsSync(), isTrue);
      expect(at('registros/$legacy/g1.db').existsSync(), isTrue);

      // Apagar um projeto leva o registro de dados dele.
      final third = await c.createProject(const Project(name: 'Forno'));
      Directory('${root.path}${sep}registros$sep$third').createSync(recursive: true);
      at('registros/$third/g9.db').writeAsStringSync('x');
      await c.open(legacy);
      await c.deleteProject(third);
      expect(at('registros/$third').existsSync(), isFalse);
    });
  });

  group('cada projeto com o seu', () {
    test('histórico de alarmes: o de um nunca aparece no outro', () async {
      writeLegacy();
      final c = await controller();
      final a = c.openId!;
      final alarms = AlarmEngine(controller: c, runtime: c.runtime, historyFile: () => c.repository.sidecar('historico-alarmes.json'));
      addTearDown(alarms.dispose);
      // Espera o histórico migrado chegar (o motor lê ao nascer).
      for (var i = 0; i < 100 && alarms.history.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(alarms.history.map((e) => e.message), ['Porta aberta']);

      alarms.raise('teste-a', priority: AlarmPriority.low, message: 'Só da cortadora');
      final b = await c.createProject(const Project(name: 'Prensa'));
      expect(alarms.entries, isEmpty, reason: 'alarme ativo era do projeto que saiu');
      expect(alarms.history, isEmpty);

      alarms.raise('teste-b', priority: AlarmPriority.low, message: 'Só da prensa');
      await c.open(a);
      expect(alarms.history.map((e) => e.message), ['Só da cortadora', 'Porta aberta']);

      await c.open(b);
      expect(alarms.history.map((e) => e.message), ['Só da prensa']);
      final fileA = at('projetos/$a/historico-alarmes.json').readAsStringSync();
      final fileB = at('projetos/$b/historico-alarmes.json').readAsStringSync();
      expect(fileA, isNot(contains('prensa')));
      expect(fileB, isNot(contains('cortadora')));
    });

    test('registro de dados: cada projeto grava em registros/<projeto>/', () async {
      final c = await controller();
      final a = c.openId!;
      const dev = Device(id: 'dx', name: 'CLP', host: 'x');
      const t = Tag(id: 'v', name: 'Nível', deviceId: 'dx');
      const g = LogGroup(id: 'g1', name: 'Nível', tagIds: ['v']);
      await c.replace(const Project(name: 'A', devices: [dev], tags: [t], logGroups: [g]));
      final logger = DataLogger(
        controller: c,
        runtime: c.runtime,
        store: LogStore(directory: () => c.repository.logsDirectory(), factory: databaseFactoryFfiNoIsolate),
        tickEvery: null,
        flushEvery: null,
        startupGrace: Duration.zero,
      );
      addTearDown(() async {
        await logger.close();
        logger.dispose();
      });
      await logger.flush();

      void sample(double v) {
        c.runtime.store.publish('v', TagReading(value: v, quality: TagQuality.good, at: DateTime.now()));
        logger.tick();
      }

      sample(1);
      await logger.flush();
      // Projeto B com o MESMO id de grupo (é o que a duplicação produz).
      final b = await c.createProject(const Project(name: 'B', devices: [dev], tags: [t], logGroups: [g]));
      sample(2);
      await logger.flush();

      final dbA = File('${root.path}${sep}registros$sep$a$sep${LogStore.fileName('g1')}');
      final dbB = File('${root.path}${sep}registros$sep$b$sep${LogStore.fileName('g1')}');
      expect(dbA.existsSync(), isTrue);
      expect(dbB.existsSync(), isTrue);
      final h = await logger.history(g, from: DateTime.now().subtract(const Duration(hours: 1)), to: DateTime.now().add(const Duration(minutes: 1)), tagIds: ['v'], buckets: 10);
      final values = [for (final bucket in h.buckets) bucket.avg.single];
      expect(values.whereType<double>(), [2.0], reason: 'no projeto B só a amostra do B');
    });
  });

  group('revisão de 21/10/2026', () {
    Future<ProjectController> start(PlantStore plant) async {
      final c = await ProjectController.start(runtime: HmiRuntime(), plant: plant);
      addTearDown(() async {
        await c.flush();
        c.dispose();
        await c.runtime.dispose();
      });
      return c;
    }

    test('a planta não abre (pasta que não se cria): abre o projeto antigo como a 1.4.0 e migra na abertura seguinte', () async {
      writeLegacy();
      // Um arquivo no lugar da pasta "projetos": criar a pasta falha.
      at('projetos').writeAsStringSync('não é pasta');

      final rescued = await start(PlantStore(root: root));
      expect(rescued.manyProjects, isFalse, reason: 'modo de socorro: um projeto só, como a 1.4.0');
      expect(rescued.project.name, 'Cortadora');
      expect(rescued.project.tags.single.name, 'Velocidade');
      expect(at('projeto.ihm.json').existsSync(), isTrue, reason: 'o antigo fica na raiz para migrar depois');
      expect((await rescued.repository.sidecar('historico-alarmes.json')).readAsStringSync(), contains('Porta aberta'));

      // Na abertura seguinte a pasta já se cria: migra como sempre.
      at('projetos').deleteSync();
      final next = await start(PlantStore(root: root));
      expect(next.manyProjects, isTrue);
      expect(next.projects.map((e) => e.id), [PlantStore.legacyId]);
      expect(next.project.name, 'Cortadora');
      expect(at('projeto.ihm.json').existsSync(), isFalse);
    });

    test('exceção qualquer na planta: o app abre mesmo assim; sem projeto antigo, a demonstração fica só na memória', () async {
      final rescued = await start(_BrokenPlant(root: root));
      expect(rescued.manyProjects, isFalse);
      expect(rescued.project.screens, isNotEmpty, reason: 'abre com a demonstração');
      expect(at('projeto.ihm.json').existsSync(), isFalse, reason: 'senão ela viraria um projeto a mais na próxima migração');

      final withLegacy = Directory('${root.path}${sep}outro')..createSync();
      File('${withLegacy.path}${sep}projeto.ihm.json').writeAsBytesSync(ProjectRepository.encode(cortadora));
      final again = await start(_BrokenPlant(root: withLegacy));
      expect(again.project.name, 'Cortadora');
    });

    test('migração que copiou e não apagou o antigo: a abertura seguinte termina sem projeto duplicado', () async {
      writeLegacy();
      // A abertura anterior copiou tudo (outro volume) e não conseguiu
      // apagar a origem: os dois lados com os mesmos bytes.
      final dir = Directory('${root.path}${sep}projetos$sep${PlantStore.legacyId}')..createSync(recursive: true);
      for (final name in ['projeto.ihm.json', 'historico-alarmes.json']) {
        at(name).copySync('${dir.path}$sep$name');
      }

      final c = await controller();
      expect(c.projects.map((e) => e.id), [PlantStore.legacyId], reason: 'sem "Cortadora" em dobro');
      expect(c.project.name, 'Cortadora');
      expect(at('projeto.ihm.json').existsSync(), isFalse, reason: 'a origem igual ao destino sai');
      expect(at('historico-alarmes.json').existsSync(), isFalse);
      expect(at('projetos/${PlantStore.legacyId}/historico-alarmes.json').readAsStringSync(), contains('Porta aberta'));
      expect(at('registros/${PlantStore.legacyId}/g1.db').readAsStringSync(), 'banco do grupo g1');
      expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('pasta inicial com OUTRO projeto: o antigo vai para uma pasta nova, nada se sobrescreve', () async {
      writeLegacy();
      const other = Project(name: 'Prensa');
      Directory('${root.path}${sep}projetos$sep${PlantStore.legacyId}').createSync(recursive: true);
      at('projetos/${PlantStore.legacyId}/projeto.ihm.json').writeAsBytesSync(ProjectRepository.encode(other));

      final c = await controller();
      expect(c.projects.map((e) => e.name), ['Cortadora', 'Prensa']);
      expect(at('projetos/${PlantStore.legacyId}/projeto.ihm.json').readAsBytesSync(), ProjectRepository.encode(other));
    });

    test('projeto ilegível: uma cópia .corrompido-… só, por mais que o app abra', () async {
      final c = await controller();
      final id = await c.createProject(const Project(name: 'Prensa'));
      await c.flush();
      at('projetos/$id/projeto.ihm.json').writeAsStringSync('{ estragado');
      final folder = Directory('${root.path}${sep}projetos$sep$id');
      List<FileSystemEntity> copies() => folder.listSync().where((f) => f.path.contains('.corrompido-')).toList();

      for (var i = 0; i < 3; i++) {
        final again = await controller();
        await again.open(id);
        expect(again.project.name, 'Prensa', reason: 'o nome da lista segura o projeto ilegível');
      }
      // Lista perdida também lê a pasta (e não copia de novo).
      at('projetos/planta.json').deleteSync();
      await PlantStore(root: root).load();

      expect(copies(), hasLength(1));
      expect(File(copies().single.path).readAsStringSync(), '{ estragado');

      // Estragou de outro jeito: essa é outra cópia.
      at('projetos/$id/projeto.ihm.json').writeAsStringSync('{ estragado de novo');
      await ProjectRepository(directory: folder).load();
      expect(copies(), hasLength(2));
    });

    test('projeto da 1.4.0 chamado "Demonstração" com coisas do usuário vira "Meu projeto"', () async {
      const mine = Device(id: 'd_meu', name: 'Prensa do galpão', host: '192.168.0.20');
      final demo = DemoProject.build();
      final edited = demo.copyWith(devices: [...demo.devices, mine], screens: [...demo.screens, const HmiScreen(id: 's_meu', name: 'Minha tela')]);
      at('projeto.ihm.json').writeAsBytesSync(ProjectRepository.encode(edited));

      final c = await controller();
      expect(c.project.name, 'Meu projeto');
      expect(c.projects.single.name, 'Meu projeto');
      expect(c.project.devices.map((d) => d.id), contains('d_meu'), reason: 'só o nome muda');
      expect(c.project.screens, hasLength(edited.screens.length));
    });

    test('a demonstração intacta da 1.4.0 continua "Demonstração"', () async {
      at('projeto.ihm.json').writeAsBytesSync(ProjectRepository.encode(DemoProject.build()));
      final c = await controller();
      expect(c.project.name, 'Demonstração');
      expect(at('projetos/${PlantStore.legacyId}/projeto.ihm.json').readAsBytesSync(), ProjectRepository.encode(DemoProject.build()), reason: 'byte a byte');
      expect(DemoProject.isOnlyDemo(cortadora), isFalse);
    });

    test('cópias de segurança: a planta substituída aparece na lista e abrir SOMA os projetos dela', () async {
      writeLegacy();
      final c = await controller();
      expect(c.backups(), isEmpty);
      await c.newPlant();
      expect(c.projects.map((e) => e.name), ['Meu projeto']);

      final list = c.backups();
      expect(list, hasLength(1));
      expect(DateTime.now().difference(list.single.when).inMinutes, lessThan(2), reason: 'a data sai do nome do arquivo');

      final n = await c.restoreBackup(list.single);
      expect(n, 1);
      expect(c.projects.map((e) => e.name), ['Cortadora', 'Meu projeto'], reason: 'somou, não substituiu');
      expect(c.project.name, 'Meu projeto', reason: 'o aberto não muda');
      expect(c.backups(), hasLength(1), reason: 'abrir não cria cópia nova');
    });
  });

  test('o índice guarda o último aberto e não guarda dado do projeto', () async {
    writeLegacy();
    final c = await controller();
    await c.flush();
    final index = jsonDecode(at('projetos/planta.json').readAsStringSync()) as Map;
    expect(index['open'], c.openId);
    expect((index['projects'] as List).single, containsPair('name', 'Cortadora'));
  });
}

/// Planta que não abre (disco cheio, migração que lança no meio).
class _BrokenPlant extends PlantStore {
  _BrokenPlant({super.root});

  @override
  Future<void> load() async => throw const FileSystemException('Sem espaço no aparelho');
}
