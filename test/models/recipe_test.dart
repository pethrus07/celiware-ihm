import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/models/log_group.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/recipe.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/recipes/recipe_applier.dart';
import 'package:ihm/services/recipes/recipe_history.dart';
import 'package:ihm/services/recipes/recipe_logic.dart';
import 'package:ihm/services/storage/project_repository.dart';

/// Regras puras das receitas (RC-1 a RC-7): comparação com tolerância,
/// versões, transferência para outra máquina, validação de valor e o arquivo
/// do projeto (ida e volta, projeto antigo igual, valores impossíveis).
void main() {
  const vel = RecipeParam(key: 'vel', name: 'Velocidade', unit: 'm/min', min: 0, max: 150, tolerance: 0.5);
  const comp = RecipeParam(key: 'comp', name: 'Comprimento', unit: 'mm');
  const temp = RecipeParam(key: 'temp', name: 'Temperatura', unit: '°C', decimals: 1);
  const faca = RecipeParam(key: 'faca', name: 'Faca dupla', onOff: true);
  const type = RecipeType(id: 'rt', name: 'Rótulo', params: [vel, comp, temp, faca]);
  final t0 = DateTime(2026, 10, 11, 14, 0);

  group('comparação com tolerância (RC-4)', () {
    test('dentro da tolerância é igual; fora, diferente', () {
      expect(vel.same(80, 80.5), isTrue, reason: 'na borda da tolerância');
      expect(vel.same(80, 79.6), isTrue);
      expect(vel.same(80, 80.6), isFalse);
    });

    test('tolerância zero: ruído do FLOAT32 é igual, inteiro diferente por 1 não', () {
      expect(temp.same(75.2, 75.19999694824219), isTrue, reason: '75,2 gravado num FLOAT32 volta assim');
      expect(temp.same(75.2, 75.3), isFalse);
      expect(comp.same(1000000, 1000001), isFalse, reason: 'contador grande não pode virar igual');
      expect(comp.same(120, 120), isTrue);
    });

    test('liga/desliga compara ligado com ligado', () {
      expect(faca.same(1, 1), isTrue);
      expect(faca.same(1, 0), isFalse);
      expect(faca.same(0, 0), isTrue);
    });

    test('mostra só as diferenças; leitura que falhou e valor que falta aparecem à parte', () {
      final all = RecipeLogic.compare(
        type,
        const {'vel': 80, 'comp': 120, 'temp': 75.2},
        const MachineSnapshot(values: {'vel': 80.3, 'comp': 100, 'faca': 1}, problems: {'temp': 'endereço inexistente no equipamento'}),
      );
      expect(all.map((d) => d.state), [RecipeDiffState.same, RecipeDiffState.different, RecipeDiffState.unreadable, RecipeDiffState.noValue]);
      expect(all[2].message, 'endereço inexistente no equipamento');
      final diff = RecipeLogic.differences(all);
      expect(diff.single.param.key, 'comp');
      expect((diff.single.machine, diff.single.recipe), (100.0, 120.0));
    });

    test('sem comunicação: o que não foi lido diz o motivo', () {
      final all = RecipeLogic.compare(type, const {'vel': 80, 'comp': 120}, const MachineSnapshot(values: {'vel': 80}, commError: 'sem resposta do equipamento'));
      expect(all[1].state, RecipeDiffState.unreadable);
      expect(all[1].message, 'sem resposta do equipamento');
    });
  });

  group('valores na unidade de engenharia', () {
    test('formato brasileiro, sem esconder casa que existe, sem o ruído do FLOAT32', () {
      expect(vel.format(80), '80 m/min');
      expect(temp.format(75.19999694824219), '75,2 °C');
      expect(temp.format(75.25), '75,25 °C', reason: 'mais casas que a variável: mostra, não arredonda calado');
      expect(faca.format(1), 'LIGADO');
      expect(faca.format(0), 'DESLIGADO');
      expect(vel.format(null), '—');
      expect(temp.clean(75.19999694824219), 75.2);
      expect(comp.clean(75.19999694824219), 75.2, reason: 'FLOAT32 sem casas configuradas também perde o ruído');
      expect(comp.clean(1234567.8), 1234567.8);
    });

    test('valor fora da faixa da receita ou que a variável não aceita é recusado', () {
      expect(RecipeLogic.valueProblem(vel, 80), isNull);
      expect(RecipeLogic.valueProblem(vel, 200), '"Velocidade": 200 m/min passa do máximo (150 m/min)');
      expect(RecipeLogic.valueProblem(vel, -1), contains('abaixo do mínimo'));
      expect(RecipeLogic.valueProblem(vel, 150.00000001), isNull, reason: 'na borda, com o erro do ponto flutuante');
      const div10 = Tag(id: 't', name: 'Temperatura', deviceId: 'd', writable: true, scale: 0.1, unit: '°C');
      expect(RecipeLogic.valueProblem(temp, 75.2, tag: div10), isNull);
      expect(RecipeLogic.valueProblem(temp, 75.25, tag: div10), 'Nesta máquina, "Temperatura" aceita passos de 0,1');
      expect(RecipeLogic.valueProblem(temp, 7000, tag: div10), contains('aceita de 0,0 a 6553,5'));
      expect(RecipeLogic.valueProblem(faca, 1, tag: div10), isNull, reason: 'liga/desliga não tem faixa');
    });

    test('resumo da faixa e da tolerância', () {
      expect(vel.limitsLabel, 'De 0 a 150 m/min · tolerância 0,5');
      expect(comp.limitsLabel, 'Sem faixa');
      expect(faca.limitsLabel, 'Liga / desliga');
      expect(const RecipeParam(key: 'x', name: 'X', unit: 'bar', min: 2).limitsLabel, 'A partir de 2 bar');
    });
  });

  group('versões (RC-7)', () {
    const base = Recipe(id: 'r', typeId: 'rt', name: 'Rótulo 120', values: {'vel': 80, 'comp': 120}, note: Recipe.noteCreated);

    test('valor novo = versão nova; igual = a mesma receita', () {
      final r2 = base.revise(const {'vel': 90, 'comp': 120}, note: Recipe.noteRead, at: t0);
      expect(r2.version, 2);
      expect(r2.note, Recipe.noteRead);
      expect(r2.history.single.values, {'vel': 80, 'comp': 120});
      expect(r2.history.single.note, Recipe.noteCreated);
      expect(identical(r2.revise(const {'vel': 90, 'comp': 120}, note: Recipe.noteRead, at: t0), r2), isTrue);
    });

    test('receita vazia só se preenche, sem versão nova', () {
      const empty = Recipe(id: 'r', typeId: 'rt', note: Recipe.noteCreated);
      final filled = empty.revise(const {'vel': 80}, note: Recipe.noteRead, at: t0);
      expect((filled.version, filled.history.length, filled.note), (1, 0, Recipe.noteRead));
    });

    test('ficam só as últimas 10, contando a atual', () {
      var r = base;
      for (var i = 0; i < 15; i++) {
        r = r.revise({'vel': 100.0 + i, 'comp': 120}, note: Recipe.noteRead, at: t0.add(Duration(hours: i)));
      }
      expect(r.version, 16);
      expect(r.versions.length, Recipe.maxVersions);
      expect(r.versions.first.version, 16);
      expect(r.versions.last.version, 7);
    });

    test('edições à mão seguidas viram uma versão; depois de 10 min, outra', () {
      var r = base.revise(const {'vel': 81, 'comp': 120}, note: Recipe.noteEdited, at: t0, coalesce: true);
      expect(r.version, 2);
      r = r.revise(const {'vel': 81, 'comp': 121}, note: Recipe.noteEdited, at: t0.add(const Duration(minutes: 3)), coalesce: true);
      expect(r.version, 2, reason: 'mesma sessão de edição');
      expect(r.values, {'vel': 81, 'comp': 121});
      r = r.revise(const {'vel': 82, 'comp': 121}, note: Recipe.noteEdited, at: t0.add(const Duration(minutes: 20)), coalesce: true);
      expect(r.version, 3);
      r = r.revise(const {'vel': 83, 'comp': 121}, note: Recipe.noteRead, at: t0.add(const Duration(minutes: 21)), coalesce: true);
      expect(r.version, 4, reason: 'ler da máquina nunca se junta com edição');
    });

    test('restaurar cria versão nova com os valores antigos — sem apagar nada', () {
      final r2 = base.revise(const {'vel': 90, 'comp': 120}, note: Recipe.noteRead, at: t0);
      final r3 = r2.restore(r2.versions.last, at: t0.add(const Duration(hours: 1)));
      expect(r3.version, 3);
      expect(r3.values, {'vel': 80, 'comp': 120});
      expect(r3.note, 'Restaurada da versão 1');
      expect(r3.versions.map((v) => v.version), [3, 2, 1]);
    });

    test('duplicar começa na versão 1, dizendo de onde veio', () {
      final r2 = base.revise(const {'vel': 90, 'comp': 120}, note: Recipe.noteRead, at: t0);
      final copy = r2.duplicate(id: 'c', name: 'Rótulo 120 (cópia)', at: t0);
      expect((copy.id, copy.version), ('c', 1));
      expect(copy.history, isEmpty);
      expect(copy.values, r2.values);
      expect(copy.note, 'Cópia de "Rótulo 120" (versão 2)');
    });
  });

  group('máquina e transferência (RC-1, RC-7)', () {
    const a = Device(id: 'a', name: 'Cortadora 1');
    const b = Device(id: 'b', name: 'Cortadora 2');
    final tags = [
      const Tag(id: 'a_vel', name: 'Velocidade desejada', deviceId: 'a', address: 1, writable: true),
      const Tag(id: 'a_comp', name: 'Comprimento', deviceId: 'a', address: 5, writable: true, memory: 'D5'),
      const Tag(id: 'a_temp', name: 'Temperatura alvo', deviceId: 'a', address: 9, writable: true),
      const Tag(id: 'a_faca', name: 'Faca dupla', deviceId: 'a', area: ModbusArea.coil, address: 2, dataType: TagDataType.bool, writable: true),
      // Máquina 2: mesmo nome em outro endereço, mesma memória com outro nome,
      // mesmo endereço com outro nome — e armadilhas que não podem servir.
      const Tag(id: 'b_vel_leitura', name: 'Velocidade desejada', deviceId: 'b', address: 40), // só leitura
      const Tag(id: 'b_vel', name: 'velocidade  DESEJADA', deviceId: 'b', address: 41, writable: true),
      const Tag(id: 'b_comp', name: 'Tamanho do rótulo', deviceId: 'b', address: 77, writable: true, memory: 'd5'),
      const Tag(id: 'b_temp', name: 'Setpoint do forno', deviceId: 'b', address: 9, writable: true),
      const Tag(id: 'b_faca_num', name: 'Faca dupla', deviceId: 'b', address: 3, writable: true), // número, não liga/desliga
    ];
    final project = Project(devices: const [a, b], tags: tags);
    const machineA = RecipeMachine(deviceId: 'a', tags: {'vel': 'a_vel', 'comp': 'a_comp', 'temp': 'a_temp', 'faca': 'a_faca'});
    final t = type.upsertMachine(machineA);

    test('sugere as variáveis da outra máquina: nome, memória, endereço — e nunca a que não serve', () {
      final s = RecipeLogic.suggestBinding(t, project, toDeviceId: 'b', from: machineA);
      expect(s, {'vel': 'b_vel', 'comp': 'b_comp', 'temp': 'b_temp'});
      expect(s.containsKey('faca'), isFalse, reason: 'faca é liga/desliga; a "Faca dupla" de lá é número');
    });

    test('máquina pronta não tem problema; faltas e trocas aparecem com nome', () {
      expect(RecipeLogic.machineProblems(t, machineA, project), isEmpty);
      const half = RecipeMachine(deviceId: 'b', tags: {'vel': 'b_vel', 'comp': 'b_vel_leitura', 'temp': 'sumiu', 'faca': 'b_faca_num'});
      expect(RecipeLogic.machineProblems(t, half, project), [
        '"Comprimento": "Velocidade desejada" não pode ser gravada pela tela',
        '"Temperatura": a variável foi apagada',
        '"Faca dupla" é liga/desliga e "Faca dupla" não',
      ]);
      expect(RecipeLogic.machineProblems(t, const RecipeMachine(deviceId: 'b'), project).first, 'Falta escolher a variável de "Velocidade"');
      expect(RecipeLogic.machineProblems(t, const RecipeMachine(deviceId: 'x'), project), ['A máquina foi apagada do projeto']);
      expect(RecipeLogic.machineProblems(t, machineA.withTags({...machineA.tags, 'vel': 'b_vel'}), project).single, '"Velocidade": a variável é de outra máquina');
    });

    test('condição e bit de receita carregada precisam ser liga/desliga (o bit, gravável)', () {
      expect(RecipeLogic.machineProblems(t, machineA.withCondition('a_vel', false), project).single, 'A condição para aplicar precisa de uma variável liga/desliga');
      expect(RecipeLogic.machineProblems(t, machineA.withCondition('a_faca', true).withLoaded('a_faca'), project), isEmpty);
      expect(RecipeLogic.machineProblems(t, machineA.withLoaded('a_comp'), project).single, '"Receita carregada" precisa de uma variável liga/desliga gravável');
      expect(RecipeLogic.machineProblems(t, machineA.withLoaded('sumiu'), project).single, contains('foi apagada'));
    });

    test('tirar um parâmetro tira o vínculo dele em todas as máquinas', () {
      final two = t.upsertMachine(const RecipeMachine(deviceId: 'b', tags: {'vel': 'b_vel', 'comp': 'b_comp'}));
      final less = two.removeParam('comp');
      expect(less.params.map((p) => p.key), ['vel', 'temp', 'faca']);
      expect(less.machine('a')!.tags.containsKey('comp'), isFalse);
      expect(less.machine('b')!.tags, {'vel': 'b_vel'});
    });

    test('variável que entra numa receita: gravável, valor único, número ou liga/desliga', () {
      expect(tags.where(RecipeParam.canUse).map((x) => x.id), ['a_vel', 'a_comp', 'a_temp', 'a_faca', 'b_vel', 'b_comp', 'b_temp', 'b_faca_num']);
      expect(RecipeParam.canUse(const Tag(id: 'l', name: 'Lista', deviceId: 'a', length: 8, writable: true)), isFalse);
      expect(RecipeParam.canUse(const Tag(id: 's', name: 'Nome', deviceId: 'a', dataType: TagDataType.string, length: 4, writable: true).normalized()), isFalse);
      final fromTag = RecipeParam.fromTag('k', const Tag(id: 'x', name: 'Temperatura', deviceId: 'a', unit: '°C', scale: 0.1, writable: true));
      expect((fromTag.name, fromTag.unit, fromTag.decimals, fromTag.onOff), ('Temperatura', '°C', 1, false));
    });
  });

  group('arquivo do projeto', () {
    final full = RecipeType(
      id: 'rt',
      name: 'Rótulo',
      params: const [vel, faca],
      machines: const [RecipeMachine(deviceId: 'a', tags: {'vel': 'a_vel', 'faca': 'a_faca'}, conditionTagId: 'a_ciclo', loadedTagId: 'a_ok')],
    );
    final recipe = const Recipe(id: 'r', typeId: 'rt', name: 'Rótulo 120', values: {'vel': 80, 'faca': 1}, note: Recipe.noteCreated)
        .revise(const {'vel': 90, 'faca': 1}, note: Recipe.noteRead, at: t0);

    test('tipo e receita vão para o arquivo e voltam iguais', () {
      final back = RecipeType.fromJson(jsonDecode(jsonEncode(full.toJson())) as Map<String, dynamic>);
      expect(back.name, 'Rótulo');
      expect(back.params.first.toJson(), vel.toJson());
      expect(back.params.last.onOff, isTrue);
      final m = back.machines.single;
      expect((m.deviceId, m.conditionTagId, m.conditionValue, m.loadedTagId), ('a', 'a_ciclo', false, 'a_ok'));
      expect(m.tags, {'vel': 'a_vel', 'faca': 'a_faca'});

      final r = Recipe.fromJson(jsonDecode(jsonEncode(recipe.toJson())) as Map<String, dynamic>);
      expect((r.id, r.typeId, r.name, r.version, r.note), ('r', 'rt', 'Rótulo 120', 2, Recipe.noteRead));
      expect(r.values, {'vel': 90, 'faca': 1});
      expect(r.updatedAt!.isAtSameMomentAs(t0), isTrue);
      expect(r.history.single.values, {'vel': 80, 'faca': 1});
    });

    test('projeto com receitas grava e lê pelo formato do arquivo, sem subir a versão', () {
      final p = Project(name: 'P', recipeTypes: [full], recipes: [recipe]);
      final bytes = ProjectRepository.encode(p);
      final raw = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(raw['schemaVersion'], 1);
      expect((raw['recipeTypes'] as List).length, 1);
      expect((raw['recipes'] as List).length, 1);
      final back = ProjectRepository.decode(bytes);
      expect(back.recipeType('rt')?.params.length, 2);
      expect(back.recipe('r')?.values['vel'], 90);
      expect(back.recipesOf('rt').single.name, 'Rótulo 120');
    });

    test('projeto antigo (sem receita) abre com listas vazias e grava byte a byte igual', () {
      final old = Project(
        name: 'Antigo',
        devices: const [Device(id: 'a', name: 'CLP', host: '192.168.0.10')],
        tags: const [Tag(id: 't', name: 'T', deviceId: 'a', writable: true)],
        screens: const [HmiScreen(id: 's', name: 'Tela')],
        logGroups: const [LogGroup(id: 'lg', tagIds: ['t'])],
      );
      final before = ProjectRepository.encode(old);
      final p = ProjectRepository.decode(before);
      expect(p.recipeTypes, isEmpty);
      expect(p.recipes, isEmpty);
      expect(p.toJson().containsKey('recipeTypes'), isFalse);
      expect(p.toJson().containsKey('recipes'), isFalse);
      expect(ProjectRepository.encode(p), before);

      final literal = utf8.encode(jsonEncode({'format': 'celiware-ihm', 'schemaVersion': 1, 'name': 'Antigo', 'devices': [], 'tags': [], 'screens': []}));
      expect(ProjectRepository.decode(literal).recipeTypes, isEmpty);
    });

    test('apagar o tipo apaga as receitas dele; as de outro tipo ficam', () {
      final p = Project(recipeTypes: [full, const RecipeType(id: 'outro')], recipes: [recipe, const Recipe(id: 'r2', typeId: 'outro')]);
      final q = p.removeRecipeType('rt');
      expect(q.recipeTypes.map((t) => t.id), ['outro']);
      expect(q.recipes.map((r) => r.id), ['r2']);
      expect(p.upsertRecipe(recipe.copyWith(name: 'Novo nome')).recipe('r')!.name, 'Novo nome');
      expect(p.removeRecipe('r').recipes.map((r) => r.id), ['r2']);
    });

    test('valores impossíveis viram o mais próximo possível', () {
      final t = RecipeType.fromJson(const {
        'id': 'x',
        'name': '  ',
        'params': [
          {'key': 'a', 'name': '', 'min': 10, 'max': 2, 'tolerance': -1, 'decimals': 9},
          {'key': 'a', 'name': 'Duplicado'},
          {'key': '', 'name': 'Sem chave'},
          {'key': 'b', 'name': 'Liga', 'onOff': true, 'unit': 'm', 'min': 1, 'tolerance': 3},
        ],
        'machines': [
          {'deviceId': 'd', 'tags': {'a': 't1', 'zz': 't2', 'b': 7}},
          {'deviceId': 'd', 'tags': {}},
          {'deviceId': '', 'tags': {}},
        ],
      });
      expect(t.name, 'Receita');
      expect(t.params.map((p) => p.key), ['a', 'b']);
      final a = t.params.first;
      expect((a.name, a.min, a.max, a.tolerance, a.decimals), ('Parâmetro', 2.0, 10.0, 0.0, 6));
      final b = t.params.last;
      expect((b.unit, b.min, b.tolerance), ('', null, 0.0));
      expect(t.machines.single.tags, {'a': 't1'});

      final r = Recipe.fromJson(const {
        'id': 'r',
        'typeId': 'x',
        'name': '',
        'values': {'a': 'oito', 'b': 1},
        'version': 0,
        'history': [
          {'version': 5, 'values': {'a': 1}},
        ],
      });
      expect((r.name, r.version), ('Receita', 1));
      expect(r.values, {'b': 1.0});
      expect(r.history, isEmpty);
      final many = Recipe.fromJson({
        'id': 'r',
        'typeId': 'x',
        'version': 20,
        'history': [for (var v = 1; v < 20; v++) {'version': v, 'values': {'a': v}}],
      });
      expect(many.history.length, Recipe.maxVersions - 1);
      expect(many.history.first.version, 11);
    });
  });

  group('histórico de aplicações (no aparelho)', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('ihm_receitas_hist'));
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {/* Windows segurando o arquivo — é só a pasta temporária */}
    });

    RecipeApplyRecord rec(int i, {String operator = ''}) => RecipeApplyRecord(
          at: t0.add(Duration(minutes: i)),
          recipeId: 'r',
          recipeName: 'Rótulo $i',
          version: i,
          typeName: 'Rótulo',
          machineName: 'Cortadora',
          operator: operator,
          outcome: RecipeOutcome.partial,
          headline: 'Parou no 2º de 3 valores: sem resposta do equipamento',
          changes: const [RecipeChangeRecord(name: 'Velocidade', from: '80 m/min', to: '90 m/min', result: 'Gravado e conferido')],
        );

    test('grava, lê o mais novo primeiro e lembra quem aplicou por último', () async {
      final store = RecipeHistoryStore(() async => File('${dir.path}/${RecipeHistoryStore.fileName}'));
      expect(await store.load(), isEmpty);
      expect(await store.lastOperator(), '');
      await store.add(rec(1, operator: 'Ana'));
      await store.add(rec(2, operator: 'Pedro'));
      await store.add(rec(3));
      final list = await store.load();
      expect(list.map((r) => r.recipeName), ['Rótulo 3', 'Rótulo 2', 'Rótulo 1']);
      expect(list.last.outcome, RecipeOutcome.partial);
      expect(list.last.at.isAtSameMomentAs(t0.add(const Duration(minutes: 1))), isTrue);
      expect(list.last.changes.single.result, 'Gravado e conferido');
      expect(await store.lastOperator(), 'Pedro', reason: 'a última sem nome não apaga o nome');
    });

    test('guarda até 200; linha de versão mais nova é pulada, não vira "aplicada"', () async {
      final file = File('${dir.path}/${RecipeHistoryStore.fileName}');
      await file.writeAsString(jsonEncode([
        for (var i = 0; i < RecipeHistoryStore.limit; i++) rec(i).toJson(),
        {...rec(999).toJson(), 'outcome': 'outroResultado'},
      ]));
      final store = RecipeHistoryStore(() async => file);
      expect((await store.load()).length, RecipeHistoryStore.limit);
      await store.add(rec(1000));
      final list = await store.load();
      expect(list.length, RecipeHistoryStore.limit);
      expect(list.first.recipeName, 'Rótulo 1000');
      expect(list.any((r) => r.recipeName == 'Rótulo 999'), isFalse);
    });
  });
}
