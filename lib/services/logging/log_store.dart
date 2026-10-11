import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:logging/logging.dart';
import 'package:sqflite/sqflite.dart';

import '../../models/log_group.dart';
import '../../models/tag.dart';
import '../storage/project_repository.dart';

/// Coluna de um registro: liga a variável à coluna da tabela (`c1`, `c2`…) e
/// guarda nome, unidade e casas **do momento da gravação** — o histórico
/// continua legível (e exportável) depois de a variável ser renomeada ou
/// apagada.
class LogColumn {
  const LogColumn({required this.col, required this.tagId, required this.name, this.unit = '', this.decimals = 0, this.isBool = false});

  final String col;
  final String tagId;
  final String name;
  final String unit;
  final int decimals;
  final bool isBool;

  factory LogColumn.fromRow(Map<String, Object?> r) => LogColumn(
        col: r['col'] as String,
        tagId: r['tag_id'] as String,
        name: r['nome'] as String? ?? '',
        unit: r['unidade'] as String? ?? '',
        decimals: (r['casas'] as int?) ?? 0,
        isBool: (r['liga'] as int?) == 1,
      );

  int get number => int.tryParse(col.substring(1)) ?? 0;
}

/// Uma linha para gravar: o instante e o valor de cada variável (pelo id).
/// Nulo = **lacuna** (sem comunicação) — nunca o último valor bom.
class LogRow {
  const LogRow(this.at, this.values);
  final DateTime at;
  final Map<String, double?> values;
}

/// Uma fatia de tempo do gráfico (≈ um pixel): quantas linhas caíram nela e,
/// por variável, mínimo, máximo, média e quantos valores não nulos.
class LogBucket {
  const LogBucket({required this.rows, required this.firstMs, required this.lastMs, required this.min, required this.max, required this.avg, required this.counts});

  final int rows;
  final int firstMs;
  final int lastMs;
  final List<double?> min;
  final List<double?> max;
  final List<double?> avg;

  /// Valores não nulos de cada variável. Zero com [rows] > 0 = a fatia inteira
  /// foi lacuna (sem comunicação) para aquela variável.
  final List<int> counts;

  int get midMs => (firstMs + lastMs) ~/ 2;
}

/// Resultado de uma consulta por período, já reduzida a no máximo uma fatia
/// por pixel.
class LogWindow {
  const LogWindow({required this.fromMs, required this.toMs, required this.tagIds, required this.buckets});

  final int fromMs;
  final int toMs;
  final List<String> tagIds;
  final List<LogBucket> buckets;

  int get rows => buckets.fold(0, (s, b) => s + b.rows);
  bool get isEmpty => buckets.isEmpty;

  /// Fatia mais perto de um instante — o "valor sob o dedo".
  LogBucket? nearest(int ms) {
    LogBucket? best;
    var bestD = 1 << 62;
    for (final b in buckets) {
      final d = ms < b.firstMs ? b.firstMs - ms : (ms > b.lastMs ? ms - b.lastMs : 0);
      if (d < bestD) {
        bestD = d;
        best = b;
      }
    }
    return best;
  }
}

/// Banco do registro de dados (SQLite).
///
/// **Um arquivo por grupo** em `registros/`, ao lado do projeto (mesma pasta
/// privada do histórico de alarmes): o uso de disco de cada grupo é o
/// tamanho do arquivo (sem estimativa), e apagar um grupo devolve o espaço na
/// hora — numa tabela por grupo dentro de um banco só, o espaço só voltaria
/// com VACUUM. O histórico é do aparelho: não vai na exportação do projeto e
/// fica fora do backup do Android (`res/xml/backup_rules.xml`), que desiste
/// do backup inteiro acima de 25 MB.
///
/// Instantes em **UTC** (ms desde 1970): trocar fuso ou horário de verão não
/// embaralha o histórico; a tela e o CSV mostram na hora local.
class LogStore {
  LogStore({required this.directory, this.factory});

  /// Na pasta privada do app, ao lado do projeto.
  factory LogStore.beside(ProjectRepository repository, {DatabaseFactory? factory}) =>
      LogStore(directory: () async => Directory((await repository.sidecar(folder)).path), factory: factory);

  static const folder = 'registros';
  static final Logger _log = Logger('LogStore');
  static const _sidecars = ['', '-wal', '-shm', '-journal'];

  /// Onde ficam os bancos (resolvido uma vez, em [prepare]).
  final Future<Directory> Function() directory;

  /// Android: nulo = o SQLite do próprio sistema (plugin sqflite, 0 MB no
  /// APK). Testes no Windows passam o `sqflite_common_ffi`.
  final DatabaseFactory? factory;

  final Map<String, Future<Database>> _open = {};
  Directory? _dir;

  DatabaseFactory get _dbFactory => factory ?? databaseFactoryOrNull ?? databaseFactorySqflitePlugin;

  /// Resolve a pasta (uma vez). Chame antes de [sizeOf].
  Future<Directory> prepare() async {
    final d = _dir ??= await directory();
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static String fileName(String groupId) => '${groupId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.db';

  Future<String> _path(String groupId) async => '${(await prepare()).path}${Platform.pathSeparator}${fileName(groupId)}';

  /// Já gravou alguma coisa? (Sem criar banco vazio só para perguntar.)
  Future<bool> exists(String groupId) async => File(await _path(groupId)).existsSync();

  Future<Database> _database(String groupId) {
    final open = _open[groupId];
    if (open != null) return open;
    final opening = _openNew(groupId);
    _open[groupId] = opening;
    // Não abriu (disco cheio, plataforma sem SQLite): tenta de novo da próxima vez.
    unawaited(opening.then<void>((_) {}, onError: (Object _) {
      if (identical(_open[groupId], opening)) _open.remove(groupId);
    }));
    return opening;
  }

  Future<Database> _openNew(String groupId) async {
    return _dbFactory.openDatabase(
      await _path(groupId),
      options: OpenDatabaseOptions(
        version: 1,
        // WAL: cada lote de 10 s vira um acréscimo e uma sincronização só (o
        // diário clássico faz três) — menos espera e menos desgaste da
        // memória do celular. NORMAL basta: queda de energia perde no máximo
        // o último lote, que de todo jeito ainda estava na memória.
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.rawQuery('PRAGMA synchronous=NORMAL');
        },
        onCreate: (db, _) async {
          // Tabela larga: uma linha por instante, uma coluna por variável, com
          // o instante como chave da própria tabela (sem índice à parte) — o
          // formato mais econômico na medição: 15,8 MB/dia para 20 variáveis
          // a 1 s, contra 40,7 na tabela estreita.
          await db.execute('CREATE TABLE amostras (t INTEGER PRIMARY KEY)');
          await db.execute('CREATE TABLE colunas (col TEXT PRIMARY KEY, tag_id TEXT NOT NULL UNIQUE, '
              'nome TEXT NOT NULL, unidade TEXT NOT NULL, casas INTEGER NOT NULL, liga INTEGER NOT NULL)');
          await db.execute('CREATE TABLE meta (chave TEXT PRIMARY KEY, valor TEXT NOT NULL)');
        },
      ),
    );
  }

  // ── Gravar ───────────────────────────────────────────────────────────────────

  /// Grava um lote numa transação só (RG-4).
  Future<void> append(LogGroup group, List<Tag> tags, List<LogRow> rows) async {
    if (rows.isEmpty) return;
    final db = await _database(group.id);
    await db.transaction((txn) async {
      final cols = await _ensureColumns(txn, tags);
      for (final (k, v) in [('nome', group.name), ('retencao_dias', '${group.retentionDays}')]) {
        await txn.rawInsert('INSERT OR REPLACE INTO meta (chave, valor) VALUES (?, ?)', [k, v]);
      }
      final batch = txn.batch();
      for (final r in rows) {
        final names = ['t'];
        final args = <Object?>[r.at.millisecondsSinceEpoch];
        for (final e in r.values.entries) {
          final c = cols[e.key];
          if (c == null) continue;
          names.add(c);
          args.add(e.value);
        }
        // Mesmo instante duas vezes (o relógio do celular voltou): fica a última.
        batch.rawInsert('INSERT OR REPLACE INTO amostras (${names.join(', ')}) VALUES (${List.filled(names.length, '?').join(', ')})', args);
      }
      await batch.commit(noResult: true);
    });
  }

  /// Uma coluna por variável (criada na primeira gravação dela) e nome,
  /// unidade e casas sempre atualizados.
  Future<Map<String, String>> _ensureColumns(Transaction txn, List<Tag> tags) async {
    final existing = {for (final r in await txn.query('colunas')) r['tag_id'] as String: LogColumn.fromRow(r)};
    var next = existing.values.fold<int>(0, (m, c) => math.max(m, c.number));
    final out = {for (final c in existing.values) c.tagId: c.col};
    for (final t in tags) {
      final have = existing[t.id];
      final isBool = t.dataType == TagDataType.bool;
      final meta = {'tag_id': t.id, 'nome': t.name, 'unidade': t.unit, 'casas': t.displayDecimals, 'liga': isBool ? 1 : 0};
      if (have == null) {
        final col = 'c${++next}';
        // REAL: valor sem casa decimal vai para o disco como inteiro (o
        // SQLite converte sozinho), então liga/desliga e contadores ocupam
        // 1 a 3 bytes, não 8.
        await txn.execute('ALTER TABLE amostras ADD COLUMN $col REAL');
        await txn.insert('colunas', {'col': col, ...meta});
        out[t.id] = col;
      } else if (have.name != t.name || have.unit != t.unit || have.decimals != t.displayDecimals || have.isBool != isBool) {
        await txn.update('colunas', meta, where: 'col = ?', whereArgs: [have.col]);
      }
    }
    return out;
  }

  /// Apaga o que passou da retenção. O SQLite reaproveita as páginas
  /// liberadas, então o arquivo para de crescer quando a retenção enche.
  Future<int> rotate(String groupId, DateTime cutoff) async {
    if (!await exists(groupId)) return 0;
    final db = await _database(groupId);
    return db.delete('amostras', where: 't < ?', whereArgs: [cutoff.millisecondsSinceEpoch]);
  }

  // ── Ler ──────────────────────────────────────────────────────────────────────

  Future<List<LogColumn>> columns(String groupId) async {
    if (!await exists(groupId)) return const [];
    final db = await _database(groupId);
    final list = [for (final r in await db.query('colunas')) LogColumn.fromRow(r)]..sort((a, b) => a.number.compareTo(b.number));
    return list;
  }

  Future<int> count(String groupId, {DateTime? from, DateTime? to}) async {
    if (!await exists(groupId)) return 0;
    final db = await _database(groupId);
    final r = await db.rawQuery('SELECT COUNT(*) AS n FROM amostras WHERE t >= ? AND t < ?',
        [from?.millisecondsSinceEpoch ?? 0, to?.millisecondsSinceEpoch ?? (1 << 62)]);
    return r.first['n'] as int;
  }

  /// Período reduzido para o gráfico (RG-5): **mínimo e máximo por fatia de
  /// tempo**, calculados no próprio SQLite. Uma semana a 1 s são 604.800
  /// linhas; o gráfico recebe ~400 fatias e mesmo assim mostra todo pico,
  /// porque cada fatia leva o seu extremo.
  Future<LogWindow> query(String groupId, {required DateTime from, required DateTime to, required List<String> tagIds, required int buckets}) async {
    final fromMs = from.millisecondsSinceEpoch, toMs = to.millisecondsSinceEpoch;
    final none = LogWindow(fromMs: fromMs, toMs: toMs, tagIds: tagIds, buckets: const []);
    if (toMs <= fromMs || !await exists(groupId)) return none;
    final cols = {for (final c in await columns(groupId)) c.tagId: c.col};
    final db = await _database(groupId);
    final sql = StringBuffer('SELECT ((t - ?) * ?) / ? AS b, COUNT(*) AS n, MIN(t) AS t0, MAX(t) AS t1');
    for (var i = 0; i < tagIds.length; i++) {
      final c = cols[tagIds[i]];
      sql.write(c == null
          ? ', NULL AS lo$i, NULL AS hi$i, NULL AS av$i, 0 AS n$i'
          : ', MIN($c) AS lo$i, MAX($c) AS hi$i, AVG($c) AS av$i, COUNT($c) AS n$i');
    }
    sql.write(' FROM amostras WHERE t >= ? AND t < ? GROUP BY b ORDER BY b');
    final rows = await db.rawQuery(sql.toString(), [fromMs, math.max(1, buckets), toMs - fromMs, fromMs, toMs]);
    double? d(Object? v) => (v as num?)?.toDouble();
    return LogWindow(fromMs: fromMs, toMs: toMs, tagIds: tagIds, buckets: [
      for (final r in rows)
        LogBucket(
          rows: r['n'] as int,
          firstMs: r['t0'] as int,
          lastMs: r['t1'] as int,
          min: [for (var i = 0; i < tagIds.length; i++) d(r['lo$i'])],
          max: [for (var i = 0; i < tagIds.length; i++) d(r['hi$i'])],
          avg: [for (var i = 0; i < tagIds.length; i++) d(r['av$i'])],
          counts: [for (var i = 0; i < tagIds.length; i++) (r['n$i'] as int?) ?? 0],
        ),
    ]);
  }

  /// Colunas para exportar: as variáveis de [order] (o grupo hoje), nesta
  /// ordem, e depois as que já saíram do grupo mas têm dado no período.
  Future<List<LogColumn>> exportColumns(String groupId, {required DateTime from, required DateTime to, List<String> order = const []}) async {
    final all = await columns(groupId);
    if (all.isEmpty) return all;
    final db = await _database(groupId);
    final counts = (await db.rawQuery('SELECT ${all.map((c) => 'COUNT(${c.col}) AS ${c.col}').join(', ')} FROM amostras WHERE t >= ? AND t < ?',
            [from.millisecondsSinceEpoch, to.millisecondsSinceEpoch]))
        .first;
    int rank(LogColumn c) {
      final i = order.indexOf(c.tagId);
      return i >= 0 ? i : 100000 + c.number;
    }

    return all.where((c) => order.contains(c.tagId) || ((counts[c.col] as int?) ?? 0) > 0).toList()..sort((a, b) => rank(a).compareTo(rank(b)));
  }

  /// Linhas cruas em ordem de tempo, depois de [afterMs]: `[t, valor1, valor2…]`.
  /// Paginação pela chave (rápida em qualquer ponto do arquivo, ao contrário
  /// de OFFSET), para exportar uma semana sem segurar tudo na memória.
  Future<List<List<Object?>>> page(String groupId, List<LogColumn> cols, {required int afterMs, required int toMs, int limit = 5000}) async {
    final db = await _database(groupId);
    final rows = await db.rawQuery('SELECT t${cols.map((c) => ', ${c.col}').join()} FROM amostras WHERE t > ? AND t < ? ORDER BY t LIMIT ?', [afterMs, toMs, limit]);
    return [
      for (final r in rows) [r['t'], for (final c in cols) r[c.col]],
    ];
  }

  // ── Disco ────────────────────────────────────────────────────────────────────

  /// Bytes no disco (banco + diário). É o tamanho do arquivo: instantâneo.
  /// Zero antes de [prepare].
  int sizeOf(String groupId) {
    final d = _dir;
    if (d == null) return 0;
    var total = 0;
    for (final s in _sidecars) {
      final f = File('${d.path}${Platform.pathSeparator}${fileName(groupId)}$s');
      if (f.existsSync()) total += f.lengthSync();
    }
    return total;
  }

  /// Apaga o histórico de um grupo (arquivo inteiro: o espaço volta na hora).
  Future<void> delete(String groupId) async {
    await _close(groupId);
    final path = await _path(groupId);
    for (final s in _sidecars) {
      final f = File('$path$s');
      if (f.existsSync()) f.deleteSync();
    }
  }

  /// Bancos de grupos que **não estão mais no projeto** (outro projeto
  /// importado por cima, por exemplo) continuam valendo até a retenção que
  /// tinham — e depois somem sozinhos. Um projeto trocado por engano não
  /// perde o histórico na hora, e nada fica ocupando o disco para sempre.
  Future<void> sweep(Set<String> keep, DateTime now) async {
    final dir = await prepare();
    final keepFiles = {for (final id in keep) fileName(id)};
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.db') || keepFiles.contains(name)) continue;
      final id = name.substring(0, name.length - 3);
      try {
        final db = await _database(id);
        final meta = {for (final r in await db.query('meta')) r['chave'] as String: r['valor'] as String};
        final days = int.tryParse(meta['retencao_dias'] ?? '') ?? 7;
        await db.delete('amostras', where: 't < ?', whereArgs: [now.subtract(Duration(days: days)).millisecondsSinceEpoch]);
        final left = (await db.rawQuery('SELECT COUNT(*) AS n FROM amostras')).first['n'] as int;
        if (left == 0) {
          await delete(id);
        } else {
          await _close(id);
        }
      } catch (e) {
        _log.warning('Registro antigo $name ilegível, ficou como está: $e');
        await _close(id);
      }
    }
  }

  Future<void> _close(String groupId) async {
    final open = _open.remove(groupId);
    if (open == null) return;
    try {
      await (await open).close();
    } catch (_) {/* já fechado ou nunca abriu */}
  }

  Future<void> close() async {
    for (final id in [..._open.keys]) {
      await _close(id);
    }
  }
}
