import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../models/camera.dart';
import '../models/device.dart';
import '../models/hmi_screen.dart';
import '../models/log_group.dart';
import '../models/logic_rule.dart';
import '../models/project.dart';
import '../models/recipe.dart';
import '../models/tag.dart';
import '../services/cameras/camera_vault.dart';
import '../services/demo/demo_project.dart';
import '../services/runtime/hmi_runtime.dart';
import '../services/storage/project_library.dart';
import '../services/storage/project_repository.dart';

export '../services/storage/project_library.dart' show ProjectEntry, ProjectLibrary;

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
/// **Vários projetos** ([library]): o app guarda muitos, cada um na sua
/// pasta, e o controlador cuida do que está **aberto** — é dele que
/// Equipamentos, Variáveis, Ferramentas e Alarmes mostram as coisas. Criar e
/// importar sempre acrescentam um projeto; nada substitui outro. Sem
/// biblioteca (testes, bancada), o controlador cuida de um projeto só, no
/// [ProjectRepository] dado — o comportamento das versões até a 1.4.0.
class ProjectController extends ChangeNotifier {
  ProjectController({ProjectRepository? repository, this.library, required this.runtime})
      : assert(repository != null || library != null, 'repository ou library'),
        _repository = repository;

  static final Logger _log = Logger('ProjectController');

  /// Os projetos guardados no aparelho. Nulo = um projeto só ([repository]).
  final ProjectLibrary? library;
  final HmiRuntime runtime;

  ProjectRepository? _repository;
  String? _openId;
  Project _project = const Project();
  Timer? _saveTimer;
  bool _loaded = false;
  Future<void> _switching = Future.value();
  final List<ProjectScoped> _scoped = [];

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
  /// vira o primeiro da lista, com os históricos dele ([ProjectLibrary.load]).
  Future<void> load() async {
    final lib = library;
    if (lib == null) {
      final saved = await repository.load();
      _project = saved ?? DemoProject.build();
      await runtime.apply(_project);
      _loaded = true;
      if (saved == null) await repository.save(_project);
      notifyListeners();
      return;
    }
    await lib.load();
    final id = lib.lastOpen ?? lib.entries.firstOrNull?.id ?? await lib.add(DemoProject.build());
    final repo = lib.repositoryFor(id);
    _repository = repo;
    _openId = id;
    _project = await _read(repo, id);
    await runtime.apply(_project);
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
    await runtime.apply(next);
    notifyListeners();
    await _saveNow();
  }

  // ── Vários projetos ──────────────────────────────────────────────────────────

  ProjectLibrary get _lib {
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
    _repository = repo;
    _openId = id;
    _project = next;
    notifyListeners();
    await runtime.apply(next);
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
        notifyListeners();
      });

  /// Apaga um projeto e o que é dele no aparelho (históricos, registro de
  /// dados, senhas das câmeras). O último que sobrou não se apaga: o app
  /// precisa de um projeto aberto. Apagar o aberto abre outro antes.
  Future<void> deleteProject(String id) => _serial(() async {
        final lib = _lib;
        if (lib.entries.length <= 1 || lib.entry(id) == null) return;
        final doomed = await _snapshot(id);
        if (id == _openId) await _open(lib.entries.firstWhere((e) => e.id != id).id);
        await lib.remove(id);
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

  Future<Project?> _snapshot(String id) async {
    if (id == _openId) {
      await flush();
      return _project;
    }
    return _lib.read(id);
  }

  void _commit(Project next) {
    _project = next;
    unawaited(runtime.apply(next));
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
