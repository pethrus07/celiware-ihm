import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../models/camera.dart';
import '../models/device.dart';
import '../models/hmi_screen.dart';
import '../models/log_group.dart';
import '../models/logic_rule.dart';
import '../models/plant.dart';
import '../models/project.dart';
import '../models/recipe.dart';
import '../models/tag.dart';
import '../services/cameras/camera_vault.dart';
import '../services/demo/demo_project.dart';
import '../core/utils/ids.dart';
import '../services/plant/plant_view.dart';
import '../services/runtime/hmi_runtime.dart';
import '../services/storage/plant_store.dart';
import '../services/storage/project_repository.dart';

export '../services/storage/plant_store.dart' show ProjectEntry, PlantStore, PlantBackup;

/// Dono do projeto aberto: toda edição passa por aqui.
///
/// Cada alteração (1) troca o [Project] imutável, (2) avisa as telas
/// (ChangeNotifier), (3) repassa ao [HmiRuntime] para as leituras
/// acompanharem, e (4) salva no disco — com um pequeno atraso para juntar
/// várias edições seguidas (arrastar um elemento gera dezenas) numa gravação.
///
/// Não há botão "Salvar": o que o usuário fez está feito. É uma decisão de
/// simplicidade — quem monta tela no chão de fábrica não pode perder trabalho
/// porque esqueceu de salvar.
///
/// **Planta** ([library], reunião de 19–20/10/2026): o app guarda uma planta
/// com vários projetos (um por máquina), cada um na sua pasta, e o
/// controlador cuida do projeto **aberto** — é dele que Equipamentos,
/// Variáveis, Ferramentas e Alarmes mostram as coisas. Criar e importar um
/// projeto sempre acrescentam; só "Nova planta" e importar uma planta
/// inteira substituem, com cópia automática antes. As **regras da planta**
/// usam variáveis de qualquer projeto: o motor recebe [liveProject], o
/// projeto aberto mais o que essas regras citam dos outros ([PlantView]).
///
/// Sem planta (testes, bancada), o controlador cuida de um projeto só, no
/// [ProjectRepository] dado — o comportamento das versões até a 1.4.0.
class ProjectController extends ChangeNotifier {
  ProjectController({ProjectRepository? repository, this.library, required this.runtime, this.saveFirstDemo = true})
      : assert(repository != null || library != null, 'repository ou library'),
        _repository = repository;

  static final Logger _log = Logger('ProjectController');

  /// Abre o app: a planta ([plant]) e, se ela não abrir (disco cheio, pasta
  /// que não se cria, migração que parou no meio), o projeto como a 1.4.0
  /// abria ([PlantStore.rescueRepository]) — o app nunca deixa de abrir por
  /// causa da planta. O projeto único das versões antigas continua na raiz
  /// e a migração tenta de novo na próxima abertura.
  static Future<ProjectController> start({required HmiRuntime runtime, required PlantStore plant}) async {
    final c = ProjectController(library: plant, runtime: runtime);
    try {
      await c.load();
      return c;
    } catch (e, st) {
      _log.severe('A planta não abriu; abrindo o projeto como na 1.4.0: $e', e, st);
      c.dispose();
    }
    // Sem gravar a demonstração na raiz: ela viraria um projeto a mais na
    // migração da próxima abertura.
    final rescue = ProjectController(repository: plant.rescueRepository(), runtime: runtime, saveFirstDemo: false);
    await rescue.load();
    return rescue;
  }

  /// Sem planta e sem projeto salvo: grava a demonstração aberta (o normal).
  /// Falso no modo de socorro ([start]): ela só vai para o disco se a pessoa
  /// mexer.
  final bool saveFirstDemo;

  /// Os projetos guardados no aparelho. Nulo = um projeto só ([repository]).
  final PlantStore? library;
  final HmiRuntime runtime;

  ProjectRepository? _repository;
  String? _openId;
  Project _project = const Project();
  Timer? _saveTimer;
  bool _loaded = false;
  Future<void> _switching = Future.value();
  final List<ProjectScoped> _scoped = [];

  /// Outros projetos já lidos (os que as regras da planta citam; todos,
  /// depois de abrir o editor das regras da planta).
  final Map<String, Project> _others = {};
  Project? _live;

  /// O que vai para o motor: o projeto aberto e, com regras da planta, as
  /// variáveis que elas citam dos outros projetos ([PlantView.runtime]).
  /// As telas usam [project]; o motor das regras usa este.
  Project get liveProject => _live ?? _project;

  /// Nome da planta (sem planta: o do projeto).
  String get plantName => library?.name ?? _project.name;

  /// Regras da planta, guardadas com referência qualificada ([PlantRef]).
  List<LogicRule> get plantRules => library?.rules ?? const [];

  /// Regras da planta como aparecem com este projeto aberto (as variáveis
  /// dele com o id de sempre).
  List<LogicRule> get plantRulesView {
    final id = _openId;
    return id == null ? const [] : [for (final r in plantRules) PlantRef.ruleToView(r, id)];
  }

  Map<String, Project> get _othersButOpen => {for (final e in _others.entries) if (e.key != _openId) e.key: e.value};

  void _refreshLive() {
    final lib = library, id = _openId;
    _live = lib == null || id == null || lib.rules.isEmpty
        ? null
        : PlantView.runtime(openId: id, open: _project, others: _othersButOpen, rules: lib.rules);
  }

  /// Lê os projetos que as regras da planta ligadas citam e ainda não
  /// estão na memória.
  Future<void> _loadReferenced() async {
    final lib = library;
    if (lib == null) return;
    final ids = {for (final r in lib.rules) if (r.enabled) ...PlantRef.projectsOf(r)}..remove(_openId);
    for (final id in ids) {
      if (_others.containsKey(id) || lib.entry(id) == null) continue;
      final p = await lib.read(id);
      if (p != null) _others[id] = p;
    }
  }

  /// A pasta do projeto aberto. Muda quando outro projeto é aberto — quem
  /// guarda coisa do projeto pede de novo a cada vez, nunca guarda a antiga.
  ProjectRepository get repository => _repository!;

  Project get project => _project;
  bool get loaded => _loaded;

  /// Id do projeto aberto na biblioteca; nulo sem biblioteca.
  String? get openId => _openId;

  /// Dá para ter vários projetos (criar, duplicar, apagar, importar).
  bool get manyProjects => library != null;

  /// A lista de projetos. Sem biblioteca, só o aberto.
  List<ProjectEntry> get projects => library?.entries ?? [ProjectEntry.of('', _project)];

  /// Quem guarda coisa do projeto aberto fora do arquivo dele (históricos,
  /// registro de dados) se inscreve para acompanhar a troca de projeto.
  void attachScoped(ProjectScoped s) => _scoped.add(s);
  void detachScoped(ProjectScoped s) => _scoped.remove(s);

  /// Abre o último projeto aberto, ou a demonstração na primeira vez.
  ///
  /// Com biblioteca, o projeto único das versões antigas (`projeto.ihm.json`)
  /// vira o primeiro da lista, com os históricos dele ([PlantStore.load]).
  Future<void> load() async {
    final lib = library;
    if (lib == null) {
      Project? saved;
      try {
        saved = await repository.load();
      } catch (e) {
        _log.severe('Projeto não abriu: $e');
      }
      _project = saved ?? DemoProject.build();
      await runtime.apply(_project);
      _loaded = true;
      if (saved == null && saveFirstDemo) {
        try {
          await repository.save(_project);
        } catch (e) {
          _log.severe('Não gravou a demonstração: $e');
        }
      }
      notifyListeners();
      return;
    }
    await lib.load();
    final id = lib.lastOpen ?? lib.entries.firstOrNull?.id ?? await lib.add(DemoProject.build());
    final repo = lib.repositoryFor(id);
    _repository = repo;
    _openId = id;
    _project = await _read(repo, id);
    await _loadReferenced();
    _refreshLive();
    await runtime.apply(liveProject);
    await lib.setOpen(id);
    _loaded = true;
    notifyListeners();
  }

  /// Projeto da pasta; ilegível (a cópia `.corrompido-…` fica na pasta) vira
  /// um projeto vazio com o mesmo nome, para a lista não mentir.
  Future<Project> _read(ProjectRepository repo, String id) async =>
      await repo.load() ?? Project(name: library?.entry(id)?.name ?? 'Meu projeto');

  /// Troca o conteúdo do projeto aberto inteiro (testes e bancada montam o
  /// cenário assim). Na tela, criar e importar acrescentam projetos.
  Future<void> replace(Project next) async {
    _project = next;
    _refreshLive();
    await runtime.apply(liveProject);
    notifyListeners();
    await _saveNow();
  }

  // ── Vários projetos ──────────────────────────────────────────────────────────

  PlantStore get _lib {
    final lib = library;
    if (lib == null) throw StateError('Sem biblioteca: um projeto só');
    return lib;
  }

  /// Uma troca de projeto por vez (dois toques seguidos não se misturam).
  Future<T> _serial<T>(Future<T> Function() f) {
    final run = _switching.then((_) => f());
    _switching = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Abre o projeto [id]: grava o que estava pendente no atual, e cada
  /// [ProjectScoped] (alarmes, regras, registro) guarda o do projeto que sai
  /// e passa a ler o do que entra — o histórico de um nunca vai para o outro.
  Future<void> open(String id) => _serial(() => _open(id));

  Future<void> _open(String id) async {
    final lib = _lib;
    if (id == _openId || lib.entry(id) == null) return;
    await flush();
    for (final s in [..._scoped]) {
      await _bounded(s.beforeSwitch, 'gravar o pendente');
    }
    final repo = lib.repositoryFor(id);
    final next = await _read(repo, id);
    // Daqui até o aviso é síncrono: nada do projeto que sai acontece depois
    // que os motores esquecem dele.
    for (final s in _scoped) {
      s.onSwitch();
    }
    _saveTimer?.cancel();
    _saveTimer = null;
    final leaving = _openId;
    if (leaving != null) _others[leaving] = _project;
    _others.remove(id);
    _repository = repo;
    _openId = id;
    _project = next;
    _refreshLive();
    // O motor recebe o projeto novo antes do aviso (a parte síncrona do
    // apply já troca o projeto dele): quem se inscreve ao ouvir o aviso
    // (regras, alarmes) encontra as variáveis — sem isso a regra da planta
    // via "variável apagada" por um instante e registrava "parada" a cada troca.
    final applying = runtime.apply(liveProject);
    notifyListeners();
    await applying;
    await _loadReferenced();
    _refreshLive();
    await runtime.apply(liveProject);
    await lib.setOpen(id);
    for (final s in [..._scoped]) {
      await _bounded(s.afterSwitch, 'ler o projeto novo');
    }
  }

  /// Um motor travado (disco cheio, banco preso) não pode prender a troca
  /// de projeto para sempre: espera um pouco e segue, registrando no log.
  static Future<void> _bounded(Future<void> Function() step, String what) async {
    try {
      await step().timeout(const Duration(seconds: 5));
    } catch (e) {
      _log.warning('Troca de projeto: não deu para $what: $e');
    }
  }

  /// Cria um projeto (em branco ou a demonstração) e abre. Nunca substitui
  /// outro: é o "Começar do zero" das versões antigas, sem perder nada.
  Future<String> createProject(Project p) => _serial(() async {
        final id = await _lib.add(p.copyWith(name: _lib.uniqueName(p.name)));
        await _open(id);
        return id;
      });

  /// Acrescenta um projeto vindo de arquivo e abre. O nome ganha "(2)" se já
  /// existir; senha de câmera não vem no arquivo, então cada câmera ganha
  /// uma chave nova no cofre e pede a senha de novo (CM-5).
  Future<String> importProject(Project p) => createProject(p.withFreshCameraSecrets());

  /// Cópia de um projeto, com "(cópia)" no nome. Não abre. Os históricos
  /// (alarmes, regras, receitas, registro) não vão junto: são do aparelho e
  /// do projeto de origem. As senhas das câmeras vão, em chaves novas.
  Future<String> duplicateProject(String id) => _serial(() async {
        final lib = _lib;
        final source = await _snapshot(id);
        if (source == null) throw StateError('Projeto não encontrado');
        final copy = source.withFreshCameraSecrets();
        final vault = CameraVault.instance;
        for (var i = 0; i < source.cameras.length; i++) {
          final from = source.cameras[i].secretRef, to = copy.cameras[i].secretRef;
          if (from == null || to == null) continue;
          final password = await vault.read(from);
          if (password != null) await vault.write(to, password);
        }
        final copyId = await lib.add(copy.copyWith(name: lib.uniqueName('${source.name} (cópia)')));
        notifyListeners();
        return copyId;
      });

  /// Renomeia um projeto da lista (aberto ou não).
  Future<void> renameProject(String id, String name) => _serial(() async {
        if (id == _openId) {
          rename(name);
          await flush();
          return;
        }
        final repo = _lib.repositoryFor(id);
        final p = await repo.load();
        if (p == null) return;
        final next = p.copyWith(name: name);
        await repo.save(next);
        await _lib.touch(id, next);
        if (_others.containsKey(id)) _others[id] = next;
        _refreshLive();
        notifyListeners();
      });

  /// Regras da planta ligadas que citam o projeto [id] (na condição ou no
  /// destino) — as que apagar o projeto desliga.
  List<LogicRule> plantRulesUsing(String id) => [
        for (final r in plantRules)
          if (r.enabled && PlantRef.projectsOf(r).contains(id)) r,
      ];

  /// Apaga um projeto e o que é dele no aparelho (históricos, registro de
  /// dados, senhas das câmeras). O último que sobrou não se apaga: o app
  /// precisa de um projeto aberto. Apagar o aberto abre outro antes.
  ///
  /// As regras da planta que citam o projeto são **desligadas** (não
  /// apagadas): sem isso viravam o alarme "Regra X parada" em todos os
  /// projetos até alguém apagar a regra. O diálogo de apagar avisa quantas.
  Future<void> deleteProject(String id) => _serial(() async {
        final lib = _lib;
        if (lib.entries.length <= 1 || lib.entry(id) == null) return;
        // Antes de abrir outro: o motor nunca chega a ler as máquinas de
        // quem está saindo por causa dessas regras.
        final using = {for (final r in plantRulesUsing(id)) r.id};
        if (using.isNotEmpty) {
          await lib.setRules([for (final r in plantRules) using.contains(r.id) ? r.copyWith(enabled: false) : r]);
        }
        final doomed = await _snapshot(id);
        if (id == _openId) await _open(lib.entries.firstWhere((e) => e.id != id).id);
        await lib.remove(id);
        _others.remove(id);
        _refreshLive();
        unawaited(runtime.apply(liveProject));
        notifyListeners();
        for (final ref in doomed?.cameraSecretRefs ?? const <String>{}) {
          await CameraVault.instance.delete(ref);
        }
      });

  /// O arquivo do projeto [id] para enviar ou salvar (mesmo formato do
  /// `.ihm.json` guardado). O aberto vai como está agora.
  Future<Project?> exportProject(String id) async {
    if (!manyProjects || id == _openId) {
      await flush();
      return _project;
    }
    return _lib.read(id);
  }

  // ── Planta ───────────────────────────────────────────────────────────────────

  Future<void> renamePlant(String name) async {
    await _lib.setName(name);
    notifyListeners();
  }

  /// A planta inteira para enviar ou salvar (`schemaVersion` 2).
  Future<Plant> exportPlant() => _serial(() async {
        await flush();
        return _lib.export();
      });

  /// Grava uma regra da planta vinda do editor (ids da visão com este
  /// projeto aberto) com as referências qualificadas.
  Future<void> savePlantRule(LogicRule viewRule) async {
    final stored = PlantRef.ruleToStored(viewRule, _openId!);
    final list = [...plantRules];
    final i = list.indexWhere((r) => r.id == stored.id);
    if (i < 0) {
      list.add(stored);
    } else {
      list[i] = stored;
    }
    await _setPlantRules(list);
  }

  Future<void> deletePlantRule(String id) => _setPlantRules([for (final r in plantRules) if (r.id != id) r]);

  Future<void> _setPlantRules(List<LogicRule> rules) async {
    await _lib.setRules(rules);
    await _loadReferenced();
    _refreshLive();
    // Motor antes do aviso, como em [_open].
    final applying = runtime.apply(liveProject);
    notifyListeners();
    await applying;
  }

  /// Todas as variáveis da planta, para o editor das regras da planta (lê
  /// os projetos que ainda não estão na memória).
  Future<Project> plantEditorView() async {
    final lib = _lib, id = _openId!;
    for (final e in lib.entries) {
      if (e.id == id || _others.containsKey(e.id)) continue;
      final p = await lib.read(e.id);
      if (p != null) _others[e.id] = p;
    }
    return PlantView.editor(openId: id, open: _project, others: _othersButOpen, rules: plantRules);
  }

  /// Marca "aceita escrita por regra" numa variável da visão da planta — do
  /// projeto aberto ou de outro (gravado no arquivo dele).
  Future<void> allowRuleWrite(String viewTagId) async {
    final ref = PlantRef.parse(viewTagId);
    if (ref == null) {
      final t = _project.tag(viewTagId);
      if (t != null) saveTag(t.copyWith(ruleWritable: true));
      return;
    }
    final (pid, tid) = ref;
    final repo = _lib.repositoryFor(pid);
    final p = _others[pid] ?? await repo.load();
    final t = p?.tag(tid);
    if (p == null || t == null) return;
    final next = p.upsertTag(t.copyWith(ruleWritable: true));
    await repo.save(next);
    _others[pid] = next;
    _refreshLive();
    notifyListeners();
    await runtime.apply(liveProject);
  }

  /// Soma os projetos de uma planta (arquivo) a esta, sem tirar nada. Cada
  /// um ganha id novo (e "(2)" no nome se já existir); as regras da planta
  /// do arquivo vêm junto, apontando para os projetos novos. Não troca o
  /// projeto aberto. Devolve quantos projetos entraram.
  Future<int> addPlantProjects(Plant p) => _serial(() async {
        final ids = await _addAll(p);
        await _lib.setRules([...plantRules, ..._remapRules(p.rules, ids)]);
        await _loadReferenced();
        _refreshLive();
        notifyListeners();
        await runtime.apply(liveProject);
        return ids.length;
      });

  /// Troca a planta inteira (Nova planta, importar uma planta). Antes, a
  /// planta atual vai inteira para `copias/` — devolve esse arquivo. Os
  /// projetos que saem levam os históricos, o registro de dados e as
  /// senhas das câmeras deles.
  Future<File> replacePlant(Plant p) => _serial(() async {
        final lib = _lib;
        await flush();
        final backup = await lib.backup();
        final old = [for (final e in lib.entries) e.id];
        final oldSecrets = <String>{};
        for (final id in old) {
          oldSecrets.addAll((await _snapshot(id))?.cameraSecretRefs ?? const <String>{});
        }
        final ids = await _addAll(p.projects.isEmpty ? Plant(name: p.name, projects: const [PlantProject('novo', Project(name: 'Meu projeto'))]) : p);
        await lib.setName(p.name);
        await lib.setRules(_remapRules(p.rules, ids));
        await _open(ids.values.first);
        for (final id in old) {
          await lib.remove(id);
          _others.remove(id);
        }
        for (final ref in oldSecrets) {
          await CameraVault.instance.delete(ref);
        }
        _refreshLive();
        notifyListeners();
        return backup;
      });

  /// As cópias automáticas da planta, da mais nova para a mais antiga (sem
  /// planta, nenhuma).
  List<PlantBackup> backups() => library?.backups() ?? const [];

  /// Abre uma cópia: os projetos dela entram **somados** à planta (como
  /// "Somar" ao importar uma planta), nunca no lugar dos atuais. Devolve
  /// quantos projetos entraram.
  Future<int> restoreBackup(PlantBackup b) async {
    final plant = ProjectRepository.decodePlant(await b.file.readAsBytes());
    return addPlantProjects(plant);
  }

  /// "Nova planta": uma planta com um projeto vazio (cópia da atual antes).
  Future<File> newPlant() => replacePlant(const Plant(projects: [PlantProject('novo', Project(name: 'Meu projeto'))]));

  /// Guarda os projetos de [p] com ids novos; devolve id do arquivo → id novo.
  Future<Map<String, String>> _addAll(Plant p) async {
    final ids = <String, String>{};
    for (final pp in p.projects) {
      final project = pp.project.withFreshCameraSecrets();
      ids[pp.id] = await _lib.add(project.copyWith(name: _lib.uniqueName(project.name)));
    }
    return ids;
  }

  /// Regras de uma planta de arquivo apontando para os projetos novos; regra
  /// com id que já existe ganha id novo.
  List<LogicRule> _remapRules(List<LogicRule> rules, Map<String, String> ids) {
    final taken = {for (final r in plantRules) r.id};
    return [
      for (final r in rules)
        PlantRef.mapRule(
          taken.contains(r.id) ? LogicRule.fromJson({...r.toJson(), 'id': newId('r')}) : r,
          (ref) {
            final q = PlantRef.parse(ref);
            return q == null ? ref : PlantRef.of(ids[q.$1] ?? q.$1, q.$2);
          },
        ),
    ];
  }

  Future<Project?> _snapshot(String id) async {
    if (id == _openId) {
      await flush();
      return _project;
    }
    return _lib.read(id);
  }

  void _commit(Project next) {
    _project = next;
    _refreshLive();
    unawaited(runtime.apply(liveProject));
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () => unawaited(_saveNow()));
  }

  Future<void> _saveNow() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      await repository.save(_project);
      final id = _openId;
      if (id != null) await library?.touch(id, _project);
    } catch (e) {
      _log.severe('Falha ao salvar o projeto: $e');
    }
  }

  /// Garante que nada ficou pendente (app indo para segundo plano).
  Future<void> flush() async {
    if (_saveTimer != null) await _saveNow();
  }

  // ── Edições ──────────────────────────────────────────────────────────────────

  void rename(String name) => _commit(_project.copyWith(name: name));
  void saveDevice(Device d) => _commit(_project.upsertDevice(d));
  void deleteDevice(String id) => _commit(_project.removeDevice(id));
  void saveTag(Tag t) => _commit(_project.upsertTag(t));

  /// Grava várias variáveis com **um** commit: uma aplicação no runtime, um
  /// aviso às telas, uma gravação. Com [saveTag] em laço, criar mil variáveis
  /// eram mil replanejamentos da varredura e mil reconstruções da lista.
  void saveTags(List<Tag> tags) {
    if (tags.isEmpty) return;
    _commit(_project.upsertTags(tags));
  }
  void deleteTag(String id) => _commit(_project.removeTag(id));
  void saveScreen(HmiScreen s) => _commit(_project.upsertScreen(s));
  void deleteScreen(String id) => _commit(_project.removeScreen(id));
  void saveLogGroup(LogGroup g) => _commit(_project.upsertLogGroup(g));
  void deleteLogGroup(String id) => _commit(_project.removeLogGroup(id));
  void saveRecipeType(RecipeType t) => _commit(_project.upsertRecipeType(t));
  void deleteRecipeType(String id) => _commit(_project.removeRecipeType(id));
  void saveRecipe(Recipe r) => _commit(_project.upsertRecipe(r));
  void deleteRecipe(String id) => _commit(_project.removeRecipe(id));
  void saveRule(LogicRule r) => _commit(_project.upsertRule(r));
  void deleteRule(String id) => _commit(_project.removeRule(id));
  void saveCamera(IpCamera c) => _commit(_project.upsertCamera(c));
  void deleteCamera(String id) => _commit(_project.removeCamera(id));

  /// Move a tela [id] para a posição [index] na lista.
  void reorderScreen(String id, int index) {
    final list = [..._project.screens];
    final i = list.indexWhere((s) => s.id == id);
    if (i < 0) return;
    final s = list.removeAt(i);
    list.insert(index.clamp(0, list.length), s);
    _commit(_project.copyWith(screens: list));
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}

/// Quem guarda dado do projeto aberto **fora** do arquivo dele — histórico
/// de alarmes e de regras, banco do registro de dados — e por isso precisa
/// acompanhar a troca de projeto ([ProjectController.open]).
abstract interface class ProjectScoped {
  /// Ainda no projeto que sai: grava o que estiver pendente.
  Future<void> beforeSwitch();

  /// No instante da troca (síncrono, antes do aviso às telas): esquece o
  /// estado do projeto que saiu.
  void onSwitch();

  /// Já no projeto novo: lê o que é dele (histórico, pasta do registro).
  Future<void> afterSwitch();
}
