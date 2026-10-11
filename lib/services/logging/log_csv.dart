import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:clock/clock.dart';

import '../../models/log_group.dart';
import 'log_store.dart';

/// Resultado de uma exportação.
class LogExport {
  const LogExport(this.file, this.rows);
  final File file;
  final int rows;
}

/// Planilha do registro (RG-6), no jeito que o **Excel em português** abre
/// com dois cliques, sem assistente de importação:
///
/// - separador `;` (no Excel pt-BR a vírgula é a casa decimal);
/// - vírgula decimal ("75,2");
/// - data e hora `dd/MM/aaaa HH:mm:ss` na hora local (gravado em UTC);
/// - cabeçalho com nome e unidade ("Temperatura do motor (°C)");
/// - UTF-8 **com BOM** — sem ele o Excel lê "Â°C" no lugar de "°C";
/// - fim de linha CRLF; célula vazia = lacuna (sem comunicação).
///
/// Sem a linha `sep=;`: com ela o Excel ignora o BOM e estraga os acentos.
class LogCsv {
  LogCsv._();

  static const separator = ';';
  static const newline = '\r\n';
  static const bom = '﻿';

  /// Acima disto a página é formatada num isolate (a interface não trava
  /// numa semana de dados); abaixo, abrir um isolate custa mais que formatar.
  static const isolateFrom = 2000;

  static String header(List<LogColumn> cols) =>
      ['Data e hora', for (final c in cols) _cell(title(c))].join(separator) + newline;

  /// "Temperatura do motor (°C)"; liga/desliga vira "Porta fechada (1 = ligado)".
  static String title(LogColumn c) => c.isBool ? '${c.name} (1 = ligado)' : (c.unit.isEmpty ? c.name : '${c.name} (${c.unit})');

  /// "11/10/2026 14:02:05" na hora local do aparelho.
  static String dateTime(int utcMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(utcMs);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  /// Número com vírgula decimal. Com casas definidas na variável, sempre
  /// elas ("75,0"); sem, o inteiro limpo ou até 6 casas sem zeros sobrando —
  /// uma variável de ponto flutuante sem casas configuradas não pode perder
  /// a vírgula na planilha.
  static String number(double v, {int decimals = 0, bool isBool = false}) {
    if (isBool) return v != 0 ? '1' : '0';
    final x = v == 0 ? 0.0 : v; // -0,0 confunde quem lê a planilha
    final String s;
    if (decimals > 0) {
      s = x.toStringAsFixed(decimals);
    } else if (x == x.roundToDouble() && x.abs() < 1e15) {
      s = x.toStringAsFixed(0);
    } else {
      s = x.toStringAsFixed(6).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return s.replaceAll('.', ',');
  }

  /// Linhas prontas (sem cabeçalho) a partir de `[t, v1, v2…]`. Pura e
  /// estática para rodar num isolate.
  static String rows(List<List<Object?>> rows, List<int> decimals, List<bool> bools) {
    final out = StringBuffer();
    for (final r in rows) {
      out.write(dateTime(r[0] as int));
      for (var i = 1; i < r.length; i++) {
        out.write(separator);
        final v = r[i];
        if (v is num) out.write(number(v.toDouble(), decimals: decimals[i - 1], isBool: bools[i - 1]));
      }
      out.write(newline);
    }
    return out.toString();
  }

  static Uint8List encodeRows(List<List<Object?>> page, List<int> decimals, List<bool> bools) =>
      Uint8List.fromList(utf8.encode(rows(page, decimals, bools)));

  /// Formata fora da thread da interface. Função à parte para o isolate
  /// levar só os três argumentos (um fecho maior arrastaria junto o banco).
  static Future<Uint8List> _encodeInIsolate(List<List<Object?>> page, List<int> decimals, List<bool> bools) =>
      Isolate.run(() => encodeRows(page, decimals, bools));

  /// Aspas só quando precisa (nome com `;`, aspas ou quebra de linha).
  static String _cell(String s) =>
      s.contains(separator) || s.contains('"') || s.contains('\n') ? '"${s.replaceAll('"', '""')}"' : s;

  /// "registro-forno-2026-10-11.csv".
  static String fileName(LogGroup g) {
    const from = 'áàâãäéèêëíìîïóòôõöúùûüç';
    const to = 'aaaaaeeeeiiiiooooouuuuc';
    var slug = g.name.toLowerCase();
    for (var i = 0; i < from.length; i++) {
      slug = slug.replaceAll(from[i], to[i]);
    }
    slug = slug.replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');
    final d = clock.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'registro-${slug.isEmpty ? 'dados' : slug}-${d.year}-${two(d.month)}-${two(d.day)}.csv';
  }

  /// Escreve o CSV do período em [dir], página por página: memória limitada
  /// mesmo numa semana a 1 s (604.800 linhas).
  static Future<LogExport> export({
    required LogStore store,
    required LogGroup group,
    required DateTime from,
    required DateTime to,
    required Directory dir,
    int pageSize = 5000,
    int isolateFrom = LogCsv.isolateFrom,
  }) async {
    final cols = await store.exportColumns(group.id, from: from, to: to, order: group.tagIds);
    final decimals = [for (final c in cols) c.decimals];
    final bools = [for (final c in cols) c.isBool];
    final file = File('${dir.path}${Platform.pathSeparator}${fileName(group)}');
    final sink = file.openWrite();
    var total = 0;
    try {
      sink.add(utf8.encode(bom + header(cols)));
      if (cols.isNotEmpty) {
        var after = from.millisecondsSinceEpoch - 1;
        final toMs = to.millisecondsSinceEpoch;
        while (true) {
          final page = await store.page(group.id, cols, afterMs: after, toMs: toMs, limit: pageSize);
          if (page.isEmpty) break;
          sink.add(page.length >= isolateFrom ? await _encodeInIsolate(page, decimals, bools) : encodeRows(page, decimals, bools));
          total += page.length;
          after = page.last[0] as int;
          if (page.length < pageSize) break;
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    return LogExport(file, total);
  }
}
