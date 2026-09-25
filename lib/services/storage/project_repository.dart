import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

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
class ProjectRepository {
  ProjectRepository({Directory? directory}) : _dirOverride = directory;

  static final Logger _log = Logger('ProjectRepository');
  static const fileName = 'projeto.ihm.json';
  static const exportExtension = 'ihm.json';

  final Directory? _dirOverride;

  Future<File> _file() async {
    final dir = _dirOverride ?? await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  /// Projeto salvo, ou `null` na primeira abertura do app.
  Future<Project?> load() async {
    final file = await _file();
    if (!await file.exists()) return null;
    try {
      return decode(await file.readAsBytes());
    } catch (e) {
      // Arquivo ilegível: preserva uma cópia para análise em vez de apagar.
      _log.severe('Projeto ilegível, guardando cópia: $e');
      await file.copy('${file.path}.corrompido-${DateTime.now().millisecondsSinceEpoch}');
      return null;
    }
  }

  Future<void> save(Project project) async {
    final file = await _file();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(encode(project), flush: true);
    await tmp.rename(file.path);
  }

  // ── Formato ──────────────────────────────────────────────────────────────────

  static Uint8List encode(Project p) =>
      Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(p.toJson())));

  /// Lê e valida um arquivo de projeto. Lança [ProjectFormatError] com
  /// mensagem para o usuário.
  static Project decode(List<int> bytes) {
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw const ProjectFormatError('O arquivo não é um projeto válido (JSON ilegível).');
    }
    if (raw is! Map || raw['format'] != 'celiware-ihm') {
      throw const ProjectFormatError('Este arquivo não é um projeto do Celiware IHM.');
    }
    final version = raw['schemaVersion'];
    if (version is! int || version > Project.schemaVersion) {
      throw const ProjectFormatError(
          'Projeto criado numa versão mais nova do app. Atualize o app para abrir.');
    }
    return Project.fromJson(Map<String, dynamic>.from(raw));
  }

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
