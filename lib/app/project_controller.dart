import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../models/device.dart';
import '../models/hmi_screen.dart';
import '../models/log_group.dart';
import '../models/project.dart';
import '../models/tag.dart';
import '../services/demo/demo_project.dart';
import '../services/runtime/hmi_runtime.dart';
import '../services/storage/project_repository.dart';

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
class ProjectController extends ChangeNotifier {
  ProjectController({required this.repository, required this.runtime});

  static final Logger _log = Logger('ProjectController');

  final ProjectRepository repository;
  final HmiRuntime runtime;

  Project _project = const Project();
  Timer? _saveTimer;
  bool _loaded = false;

  Project get project => _project;
  bool get loaded => _loaded;

  /// Abre o projeto salvo, ou a demonstração na primeira vez.
  Future<void> load() async {
    final saved = await repository.load();
    _project = saved ?? DemoProject.build();
    await runtime.apply(_project);
    _loaded = true;
    if (saved == null) await repository.save(_project);
    notifyListeners();
  }

  /// Troca o projeto inteiro (importar, restaurar demonstração).
  Future<void> replace(Project next) async {
    _project = next;
    await runtime.apply(next);
    notifyListeners();
    await _saveNow();
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
  void deleteTag(String id) => _commit(_project.removeTag(id));
  void saveScreen(HmiScreen s) => _commit(_project.upsertScreen(s));
  void deleteScreen(String id) => _commit(_project.removeScreen(id));
  void saveLogGroup(LogGroup g) => _commit(_project.upsertLogGroup(g));
  void deleteLogGroup(String id) => _commit(_project.removeLogGroup(id));

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
