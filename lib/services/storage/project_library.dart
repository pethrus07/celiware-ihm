// Biblioteca de projetos: o app guarda VÁRIOS projetos, cada um na sua pasta.
//
// Até a 1.4.0 havia um projeto só (`projeto.ihm.json`), e "Começar do zero"
// ou "Importar projeto" o substituíam — na reunião de 19–20/10/2026 o cliente
// perdeu um projeto assim. Agora criar e importar sempre ACRESCENTAM.
//
// Disposição na pasta privada do app:
//
//   projetos/indice.json              lista (nome e contagens) + o último aberto
//   projetos/<id>/projeto.ihm.json    o projeto, no mesmo formato da exportação
//   projetos/<id>/historico-*.json    alarmes, regras e receitas DESTE projeto
//   registros/<id>/<grupo>.db         registro de dados (fora do backup, §6.10)
//
// O índice é só um atalho para a lista abrir sem ler cada projeto inteiro: a
// verdade são as pastas. Índice perdido ou ilegível se refaz lendo as pastas.

import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/utils/ids.dart';
import '../../models/project.dart';
import 'project_repository.dart';

/// Um projeto na lista: o que a lista mostra sem abrir o arquivo.
class ProjectEntry {
  const ProjectEntry({required this.id, required this.name, this.equipment = 0, this.tags = 0, this.screens = 0});

  factory ProjectEntry.of(String id, Project p) =>
      ProjectEntry(id: id, name: p.name, equipment: p.equipment.length, tags: p.tags.length, screens: p.screens.length);

  final String id;
  final String name;
  final int equipment;
  final int tags;
  final int screens;

  /// "3 equipamentos · 12 variáveis · 4 telas"; projeto vazio diz que está vazio.
  String get summary {
    if (equipment == 0 && tags == 0 && screens == 0) return 'Projeto vazio';
    String n(int v, String one, String many) => v == 1 ? '1 $one' : '$v $many';
    return [
      n(equipment, 'equipamento', 'equipamentos'),
      n(tags, 'variável', 'variáveis'),
      n(screens, 'tela', 'telas'),
    ].join(' · ');
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'equipment': equipment, 'tags': tags, 'screens': screens};

  static ProjectEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'];
    if (id is! String || name is! String || !ProjectLibrary.validId(id)) return null;
    int count(Object? v) => v is int && v >= 0 ? v : 0;
    return ProjectEntry(id: id, name: name, equipment: count(j['equipment']), tags: count(j['tags']), screens: count(j['screens']));
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectEntry && other.id == id && other.name == name && other.equipment == equipment && other.tags == tags && other.screens == screens;

  @override
  int get hashCode => Object.hash(id, name, equipment, tags, screens);
}

/// Os projetos guardados neste aparelho.
///
/// Chame [load] uma vez antes de tudo (resolve a pasta, migra o projeto único
/// das versões antigas e lê o índice). Depois disso, [repositoryFor] é
/// síncrono.
class ProjectLibrary {
  ProjectLibrary({Directory? root}) : _rootOverride = root;

  static final Logger _log = Logger('ProjectLibrary');

  static const folder = 'projetos';
  static const indexName = 'indice.json';

  /// Pasta do projeto único das versões até a 1.4.0, depois de migrado. Fixa
  /// (e não sorteada) para a migração poder ser retomada se o app fechar no
  /// meio: a segunda tentativa cai na mesma pasta.
  static const legacyId = 'p_inicial';

  /// O que morava ao lado do projeto único e é dele (vai junto na migração).
  static const legacySidecars = ['historico-alarmes.json', 'historico-regras.json', 'historico-receitas.json'];

  final Directory? _rootOverride;
  Directory? _root;
  final List<ProjectEntry> _entries = [];
  String? _lastOpen;

  /// Os projetos, em ordem alfabética (sem diferenciar acento nem maiúscula).
  List<ProjectEntry> get entries => List.unmodifiable(_entries);

  /// O último projeto aberto (abre de novo na próxima vez).
  String? get lastOpen => _lastOpen != null && entry(_lastOpen!) != null ? _lastOpen : null;

  ProjectEntry? entry(String id) => _entries.where((e) => e.id == id).firstOrNull;

  /// Nome de pasta aceito: o que o próprio app gera (letras, números, `_`, `-`).
  static bool validId(String id) => RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id);

  Directory get _rootDir {
    final r = _root;
    if (r == null) throw StateError('ProjectLibrary.load() ainda não foi chamado');
    return r;
  }

  String get _sep => Platform.pathSeparator;
  Directory _projectsDir() => Directory('${_rootDir.path}$_sep$folder');
  Directory _projectDir(String id) => Directory('${_projectsDir().path}$_sep$id');
  Directory _logsDir(String id) => Directory('${_rootDir.path}$_sep${ProjectRepository.logsFolder}$_sep$id');
  File _indexFile() => File('${_projectsDir().path}$_sep$indexName');

  /// O repositório (pasta) de um projeto.
  ProjectRepository repositoryFor(String id) {
    if (!validId(id)) throw ArgumentError.value(id, 'id', 'id de projeto inválido');
    return ProjectRepository(directory: _projectDir(id), logsDirectory: _logsDir(id));
  }

  // ── Abrir ───────────────────────────────────────────────────────────────────

  Future<void> load() async {
    _root ??= _rootOverride ?? await getApplicationDocumentsDirectory();
    _projectsDir().createSync(recursive: true);
    await _migrateLegacy();
    _readIndex();
    await _reconcile();
  }

  /// Versões até a 1.4.0: um projeto só, solto na raiz. Vira o primeiro
  /// projeto da lista, com os históricos e o registro de dados dele — nada
  /// se perde. Move (renomeia) em vez de copiar: rápido e sem dobrar o disco.
  /// O arquivo do projeto vai por último; se o app fechar no meio, a próxima
  /// abertura acha o arquivo antigo ainda lá e termina o serviço.
  Future<void> _migrateLegacy() async {
    final legacy = File('${_rootDir.path}$_sep${ProjectRepository.fileName}');
    if (!legacy.existsSync()) return;
    var id = legacyId;
    // Já existe um projeto nessa pasta (não devia): o antigo vai para uma
    // pasta nova em vez de sobrescrever.
    if (File('${_projectDir(id).path}$_sep${ProjectRepository.fileName}').existsSync()) id = newId('p');
    final dir = _projectDir(id)..createSync(recursive: true);
    for (final name in legacySidecars) {
      final f = File('${_rootDir.path}$_sep$name');
      final target = File('${dir.path}$_sep$name');
      if (f.existsSync() && !target.existsSync()) _move(f, target.path);
    }
    // Bancos do registro: só os arquivos soltos em registros/ (as subpastas
    // já são de projetos da biblioteca).
    final logs = Directory('${_rootDir.path}$_sep${ProjectRepository.logsFolder}');
    if (logs.existsSync()) {
      final files = logs.listSync().whereType<File>().toList();
      if (files.isNotEmpty) {
        final target = _logsDir(id)..createSync(recursive: true);
        for (final f in files) {
          final name = f.uri.pathSegments.last;
          if (!File('${target.path}$_sep$name').existsSync()) _move(f, '${target.path}$_sep$name');
        }
      }
    }
    _move(legacy, '${dir.path}$_sep${ProjectRepository.fileName}');
    _log.info('Projeto único das versões antigas migrado para $folder/$id');
    // O índice se refaz em _reconcile, que acha a pasta nova; lá o migrado
    // vira o "último aberto" — quem atualiza o app abre no projeto de sempre.
    _pendingOpen = id;
  }

  /// Projeto migrado nesta abertura.
  String? _pendingOpen;

  static void _move(File f, String to) {
    try {
      f.renameSync(to);
    } on FileSystemException {
      // Outro volume ou arquivo preso: copia e apaga.
      f.copySync(to);
      f.deleteSync();
    }
  }

  void _readIndex() {
    _entries.clear();
    final f = _indexFile();
    if (!f.existsSync()) return;
    try {
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map) return;
      final open = raw['open'];
      if (open is String) _lastOpen = open;
      final list = raw['projects'];
      if (list is List) {
        for (final j in list) {
          final e = ProjectEntry.fromJson(j);
          if (e != null && entry(e.id) == null) _entries.add(e);
        }
      }
    } catch (e) {
      _log.warning('Índice dos projetos ilegível, refazendo pelas pastas: $e');
      _entries.clear();
    }
  }

  /// Confere o índice com as pastas: pasta sem entrada ganha entrada (lendo o
  /// projeto), entrada sem pasta sai.
  Future<void> _reconcile() async {
    final found = <String>{};
    for (final d in _projectsDir().listSync().whereType<Directory>()) {
      final id = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!validId(id)) continue;
      if (!File('${d.path}$_sep${ProjectRepository.fileName}').existsSync()) continue;
      found.add(id);
      if (entry(id) != null) continue;
      final p = await repositoryFor(id).load();
      _entries.add(p == null ? ProjectEntry(id: id, name: 'Projeto sem nome') : ProjectEntry.of(id, p));
    }
    _entries.removeWhere((e) => !found.contains(e.id));
    if (_pendingOpen != null) {
      _lastOpen = _pendingOpen;
      _pendingOpen = null;
    }
    _sort();
    await _writeIndex();
  }

  static String _key(String s) => s
      .toLowerCase()
      .replaceAll(RegExp('[áàâã]'), 'a')
      .replaceAll(RegExp('[éê]'), 'e')
      .replaceAll('í', 'i')
      .replaceAll(RegExp('[óôõ]'), 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ç', 'c');

  void _sort() => _entries.sort((a, b) {
        final c = _key(a.name).compareTo(_key(b.name));
        return c != 0 ? c : a.id.compareTo(b.id);
      });

  Future<void> _writeIndex() async {
    final f = _indexFile();
    final tmp = File('${f.path}.tmp');
    try {
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'format': 'ware-iot-projetos',
          'version': 1,
          'open': ?_lastOpen,
          'projects': [for (final e in _entries) e.toJson()],
        }),
        flush: true,
      );
      await tmp.rename(f.path);
    } catch (e) {
      // Sem índice a lista se refaz pelas pastas na próxima abertura.
      _log.warning('Não gravou o índice dos projetos: $e');
    }
  }

  // ── Mudar ───────────────────────────────────────────────────────────────────

  /// Guarda um projeto novo na sua própria pasta e devolve o id. Nunca
  /// substitui outro projeto.
  Future<String> add(Project p) async {
    var id = newId('p');
    while (_projectDir(id).existsSync()) {
      id = newId('p');
    }
    await repositoryFor(id).save(p);
    _entries.add(ProjectEntry.of(id, p));
    _sort();
    await _writeIndex();
    return id;
  }

  /// Lê um projeto da lista (exportar, duplicar, renomear sem abrir).
  Future<Project?> read(String id) => repositoryFor(id).load();

  /// Atualiza a linha da lista depois de uma gravação. Só reescreve o índice
  /// quando o que a lista mostra mudou (nome ou contagens).
  Future<void> touch(String id, Project p) async {
    final i = _entries.indexWhere((e) => e.id == id);
    final next = ProjectEntry.of(id, p);
    if (i >= 0 && _entries[i] == next) return;
    if (i >= 0) {
      _entries[i] = next;
    } else {
      _entries.add(next);
    }
    _sort();
    await _writeIndex();
  }

  Future<void> setOpen(String id) async {
    if (_lastOpen == id) return;
    _lastOpen = id;
    await _writeIndex();
  }

  /// Apaga o projeto **e o que é dele neste aparelho**: históricos de
  /// alarmes, regras e receitas (na pasta do projeto) e o registro de dados
  /// (`registros/<id>/`). As senhas das câmeras saem do cofre por quem chama.
  Future<void> remove(String id) async {
    if (!validId(id)) return;
    _entries.removeWhere((e) => e.id == id);
    if (_lastOpen == id) _lastOpen = null;
    await _writeIndex();
    for (final d in [_projectDir(id), _logsDir(id)]) {
      try {
        if (d.existsSync()) await d.delete(recursive: true);
      } catch (e) {
        // Arquivo preso (banco ainda aberto): o que sobrar não volta para a
        // lista se o arquivo do projeto já saiu; se não saiu, o projeto
        // reaparece na próxima abertura em vez de sumir pela metade.
        _log.warning('Não apagou $d: $e');
      }
    }
  }

  /// "Cortadora", "Cortadora (2)", "Cortadora (3)"… — nome que ainda não
  /// existe na lista (importar o mesmo arquivo duas vezes não confunde).
  String uniqueName(String base) {
    final names = {for (final e in _entries) _key(e.name.trim())};
    final clean = base.trim().isEmpty ? 'Meu projeto' : base.trim();
    if (!names.contains(_key(clean))) return clean;
    for (var n = 2;; n++) {
      final candidate = '$clean ($n)';
      if (!names.contains(_key(candidate))) return candidate;
    }
  }
}
