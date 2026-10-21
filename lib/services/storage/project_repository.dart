import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/utils/ids.dart';
import '../../models/plant.dart';
import '../../models/project.dart';

/// Arquivo de projeto que não é do app ou é de versão mais nova.
class ProjectFormatError implements Exception {
  const ProjectFormatError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Leitura, gravação e troca de arquivo do projeto.
///
/// O projeto vive num único JSON na pasta privada do app. A gravação é
/// **atômica** (escreve num `.tmp` e renomeia): se a bateria acabar no meio,
/// sobra o arquivo antigo inteiro, nunca um meio-arquivo corrompido.
///
/// O mesmo formato serve para exportar/importar (`.ihm.json`), então o arquivo
/// que o integrador manda por WhatsApp é idêntico ao que o app guarda.
///
/// Um repositório é **um** projeto numa pasta. O app guarda vários
/// (`PlantStore`): cada um ganha o seu repositório, na sua pasta.
class ProjectRepository {
  ProjectRepository({Directory? directory, Directory? logsDirectory})
      : _dirOverride = directory,
        _logsOverride = logsDirectory;

  static final Logger _log = Logger('ProjectRepository');
  static const fileName = 'projeto.ihm.json';
  static const exportExtension = 'ihm.json';

  /// Pasta dos bancos do registro de dados (§6.10).
  static const logsFolder = 'registros';

  final Directory? _dirOverride;
  final Directory? _logsOverride;

  Future<File> _file() => sidecar(fileName);

  /// Arquivo ao lado do projeto, na mesma pasta privada (ex.: histórico de
  /// alarmes — que é do aparelho, não do projeto, e não vai na exportação).
  /// Com vários projetos, cada um tem a sua pasta: o histórico de um nunca
  /// se mistura com o de outro.
  Future<File> sidecar(String name) async {
    final dir = _dirOverride ?? await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  /// Pasta dos bancos do registro de dados deste projeto. Sozinho, é
  /// `registros/` ao lado do arquivo; na biblioteca, `registros/<projeto>/`
  /// na raiz — a regra de backup do Android só exclui caminho fixo, e o
  /// histórico tem de ficar fora do backup (passa de 25 MB e derrubaria o
  /// backup do projeto junto).
  Future<Directory> logsDirectory() async => _logsOverride ?? Directory((await sidecar(logsFolder)).path);

  /// Projeto salvo, ou `null` na primeira abertura do app.
  Future<Project?> load() async {
    final file = await _file();
    if (!await file.exists()) return null;
    try {
      return decode(await file.readAsBytes());
    } catch (e) {
      // Arquivo ilegível: preserva uma cópia para análise em vez de apagar.
      _log.severe('Projeto ilegível, guardando cópia: $e');
      keepCorruptCopy(file);
      return null;
    }
  }

  /// Guarda `<arquivo>.corrompido-<hora>` ao lado do arquivo ilegível — uma
  /// vez só: o mesmo arquivo estragado é lido de novo a cada abertura, e
  /// cada leitura deixava mais uma cópia igual na pasta. Já existe cópia com
  /// o mesmo conteúdo: devolve essa. Nunca lança (sem cópia, segue); devolve
  /// nulo quando não deu para copiar.
  static File? keepCorruptCopy(File file) {
    try {
      final bytes = file.readAsBytesSync();
      final prefix = '${file.uri.pathSegments.last}.corrompido-';
      for (final f in file.parent.listSync().whereType<File>()) {
        if (!f.uri.pathSegments.last.startsWith(prefix)) continue;
        if (f.lengthSync() == bytes.length && sameBytes(f.readAsBytesSync(), bytes)) return f;
      }
      final copy = File('${file.path}.corrompido-${DateTime.now().millisecondsSinceEpoch}');
      copy.writeAsBytesSync(bytes, flush: true);
      return copy;
    } catch (e) {
      _log.warning('Não guardou a cópia de $file: $e');
      return null;
    }
  }

  /// Mesmo conteúdo, byte a byte.
  static bool sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> save(Project project) async {
    final file = await _file();
    // Projeto novo da biblioteca: a pasta dele nasce na primeira gravação.
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(encode(project), flush: true);
    await tmp.rename(file.path);
  }

  // ── Formato ──────────────────────────────────────────────────────────────────

  static Uint8List encode(Project p) =>
      Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(p.toJson())));

  /// Arquivo da planta inteira (`schemaVersion` 2, [Plant]).
  static Uint8List encodePlant(Plant p) =>
      Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(p.toJson())));

  /// Lê e valida um arquivo de projeto avulso. Lança [ProjectFormatError]
  /// com mensagem para o usuário — inclusive quando o arquivo é de uma
  /// planta inteira (para esse, [decodeFile] ou [decodePlant]).
  static Project decode(List<int> bytes) => switch (decodeFile(bytes)) {
        ProjectFile(:final project) => project,
        PlantFile() => throw const ProjectFormatError('Este arquivo é de uma planta inteira, não de um projeto.'),
      };

  /// Lê um arquivo do app: projeto avulso (`schemaVersion` 1, o formato de
  /// sempre) ou planta inteira (`schemaVersion` 2, `"kind": "planta"`).
  static ProjectOrPlant decodeFile(List<int> bytes) {
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw const ProjectFormatError('O arquivo não é um projeto válido (JSON ilegível).');
    }
    if (raw is! Map || raw['format'] != 'celiware-ihm') {
      throw const ProjectFormatError('Este arquivo não é um projeto do Ware IoT.');
    }
    final version = raw['schemaVersion'];
    if (version is! int || version > Plant.schemaVersion) {
      throw const ProjectFormatError(
          'Projeto criado numa versão mais nova do app. Atualize o app para abrir.');
    }
    final json = Map<String, dynamic>.from(raw);
    if (version >= 2 && raw['kind'] == Plant.kind) return PlantFile(Plant.fromJson(json));
    return ProjectFile(Project.fromJson(json));
  }

  /// Qualquer arquivo do app como planta (§10.4): o projeto avulso das
  /// versões até a 1.4.0 vira uma planta com UM projeto — com as regras
  /// dele como regras do projeto, o que mantém o comportamento igual.
  static Plant decodePlant(List<int> bytes, {String Function()? newProjectId}) => switch (decodeFile(bytes)) {
        PlantFile(:final plant) => plant,
        ProjectFile(:final project) => Plant(projects: [PlantProject((newProjectId ?? () => newId('p'))(), project)]),
      };

  /// "fabrica-2026-10-20.ihm.json" para a planta inteira.
  static String plantExportName(Plant p) => exportName(Project(name: p.name.trim().isEmpty ? 'planta' : 'planta ${p.name}'));

  /// Nome sugerido para exportação: "cortadora-2026-09-25.ihm.json".
  static String exportName(Project p) {
    final slug = p.name
        .toLowerCase()
        .replaceAll(RegExp(r'[áàâã]'), 'a')
        .replaceAll(RegExp(r'[éê]'), 'e')
        .replaceAll(RegExp(r'[í]'), 'i')
        .replaceAll(RegExp(r'[óôõ]'), 'o')
        .replaceAll(RegExp(r'[ú]'), 'u')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    final d = DateTime.now();
    final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return '${slug.isEmpty ? 'projeto' : slug}-$date.$exportExtension';
  }
}

/// O que um arquivo do app contém.
sealed class ProjectOrPlant {
  const ProjectOrPlant();
}

/// Um projeto avulso (uma máquina).
class ProjectFile extends ProjectOrPlant {
  const ProjectFile(this.project);
  final Project project;
}

/// A planta inteira: vários projetos e as regras da planta.
class PlantFile extends ProjectOrPlant {
  const PlantFile(this.plant);
  final Plant plant;
}
