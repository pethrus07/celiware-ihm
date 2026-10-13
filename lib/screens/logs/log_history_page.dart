import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_info.dart';
import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/log_group.dart';
import '../../models/tag.dart';
import '../../services/logging/log_csv.dart';
import '../../services/logging/log_store.dart';
import '../../services/runtime/tag_codec.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/write_actions.dart';
import '../../widgets/logs/history_chart.dart';
import 'logs_page.dart';

enum _Period { hour, today, week, custom }

/// Histórico de um registro (RG-5): período, gráfico com pinça e arrastar,
/// valor sob o dedo — e a planilha do que está à vista (RG-6).
///
/// O banco devolve no máximo uma fatia por pixel (mín./máx.); durante o
/// gesto as fatias já carregadas se reposicionam na hora e a consulta da
/// janela nova chega logo depois.
class LogHistoryPage extends StatefulWidget {
  const LogHistoryPage({super.key, required this.groupId});
  final String groupId;

  /// Até 3 curvas por vez: são 3 as cores de dado da paleta, e mais que isso
  /// vira novelo.
  static const maxSeries = 3;

  @override
  State<LogHistoryPage> createState() => _LogHistoryPageState();
}

class _LogHistoryPageState extends State<LogHistoryPage> {
  _Period _period = _Period.hour;
  DateTimeRange? _custom;
  int _from = 0, _to = 1;
  int _vFrom = 0, _vTo = 1;
  List<String>? _selected;
  LogWindow? _window;
  int? _cursor;
  bool _exporting = false;
  Timer? _debounce;
  Timer? _live;
  int _gen = 0;
  double _plotWidth = 300;
  int? _gFrom, _gTo;
  double _gFocal = 0;

  bool get _zoomed => _vFrom > _from || _vTo < _to;

  @override
  void initState() {
    super.initState();
    _applyPeriod(_Period.hour);
    // Período que termina "agora" anda sozinho, no ritmo do lote do registro.
    _live = Timer.periodic(const Duration(seconds: 10), (_) => _followNow());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _live?.cancel();
    super.dispose();
  }

  LogGroup? get _group => AppScope.of(context).controller.project.logGroup(widget.groupId);

  void _applyPeriod(_Period p) {
    final now = clock.now();
    final (from, to) = switch (p) {
      _Period.hour => (now.subtract(const Duration(hours: 1)), now),
      _Period.today => (DateTime(now.year, now.month, now.day), now),
      _Period.week => (now.subtract(const Duration(days: 7)), now),
      _Period.custom => (_custom!.start, _minDate(_custom!.end.add(const Duration(days: 1)), now)),
    };
    _period = p;
    _to = to.millisecondsSinceEpoch;
    // Logo depois da meia-noite "Hoje" teria segundos: no mínimo 1 minuto.
    _from = math.min(from.millisecondsSinceEpoch, _to - 60000);
    _vFrom = _from;
    _vTo = _to;
    _cursor = null;
  }

  static DateTime _minDate(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

  void _followNow() {
    if (!mounted || _period == _Period.custom || _zoomed || _gFrom != null) return;
    setState(() => _applyKeepCursor());
    unawaited(_load());
  }

  void _applyKeepCursor() {
    final c = _cursor;
    _applyPeriod(_period);
    _cursor = c;
  }

  Future<void> _load() async {
    final g = _group;
    final ids = _selected;
    if (g == null || ids == null || ids.isEmpty) return;
    final gen = ++_gen;
    final w = await AppScope.of(context).logger.history(
          g,
          from: DateTime.fromMillisecondsSinceEpoch(_vFrom),
          to: DateTime.fromMillisecondsSinceEpoch(_vTo + 1),
          tagIds: ids,
          buckets: _plotWidth.round().clamp(50, 2000),
        );
    if (!mounted || gen != _gen) return;
    setState(() => _window = w);
  }

  /// Consulta nova depois que o gesto assenta (não a cada quadro).
  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () => unawaited(_load()));
  }

  // ── Gestos ──────────────────────────────────────────────────────────────────

  int _timeAt(double dx, Rect plot) {
    final frac = ((dx - plot.left) / plot.width).clamp(0.0, 1.0);
    return (_vFrom + (_vTo - _vFrom) * frac).round();
  }

  /// Pinça aproxima em torno do ponto entre os dedos; arrastar anda no tempo.
  /// Nunca sai do período escolhido nem fica mais curto que 30 s (ou 5
  /// amostras, em registro lento) — menos que isso é um ponto só na tela.
  void _onScale(ScaleUpdateDetails d, Rect plot, LogGroup g) {
    final f0 = _gFrom, t0 = _gTo;
    if (f0 == null || t0 == null) return;
    final span0 = (t0 - f0).toDouble();
    final full = (_to - _from).toDouble();
    final minSpan = math.min(full, math.max(30000.0, g.intervalSec * 5000.0));
    final scale = d.horizontalScale > 0 ? d.horizontalScale : 1.0;
    final span = (span0 / scale).clamp(minSpan, full);
    final frac = ((_gFocal - plot.left) / plot.width).clamp(0.0, 1.0);
    final focus = f0 + span0 * frac;
    final drag = -(d.localFocalPoint.dx - _gFocal) / plot.width * span;
    final from = (focus - span * frac + drag).clamp(_from.toDouble(), _to - span);
    setState(() {
      _vFrom = from.round();
      _vTo = (from + span).round();
    });
    _schedule();
  }

  void _showAll() {
    setState(() {
      _vFrom = _from;
      _vTo = _to;
    });
    unawaited(_load());
  }

  /// Dias escolhidos numa folha própria, não no calendário do Material: o
  /// app não carrega as traduções do Flutter e o calendário sairia em
  /// inglês, com data no formato americano.
  Future<void> _pickRange() async {
    final r = await showModalBottomSheet<DateTimeRange>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _DaysSheet(days: _group?.retentionDays ?? 7),
    );
    if (r == null || !mounted) return;
    setState(() {
      _custom = r;
      _applyPeriod(_Period.custom);
    });
    unawaited(_load());
  }

  // ── Planilha ────────────────────────────────────────────────────────────────

  Future<void> _export(LogGroup g) async {
    setState(() => _exporting = true);
    try {
      final dir = await getTemporaryDirectory();
      if (!mounted) return;
      final r = await AppScope.of(context).logger.exportCsv(
            g,
            from: DateTime.fromMillisecondsSinceEpoch(_vFrom),
            to: DateTime.fromMillisecondsSinceEpoch(_vTo + 1),
            dir: dir,
          );
      if (!mounted) return;
      if (r.rows == 0) {
        WriteActions.toast(context, 'Nada gravado neste período.');
        return;
      }
      await SharePlus.instance.share(ShareParams(
        files: [XFile(r.file.path, mimeType: 'text/csv')],
        subject: 'Registro ${g.name} — ${AppInfo.name}',
        text: 'Registro "${g.name}": ${r.rows} linhas, de ${LogCsv.dateTime(_vFrom)} a ${LogCsv.dateTime(_vTo)}.',
      ));
    } catch (e) {
      if (mounted) WriteActions.toast(context, 'Não consegui exportar: $e', error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ── Tela ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.watch(context);
    final project = scope.controller.project;
    final g = project.logGroup(widget.groupId);
    if (g == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(icon: Icons.timeline_rounded, title: 'Registro apagado', body: 'Este registro não existe mais.'),
      );
    }
    final tags = [
      for (final id in g.tagIds)
        if (project.tag(id) case final t? when LogGroup.canLog(t)) t,
    ];
    // Começa com as primeiras curvas; variável que saiu do grupo sai da seleção.
    final ids = tags.map((t) => t.id).toSet();
    final before = _selected;
    final selected = (before ?? tags.take(LogHistoryPage.maxSeries).map((t) => t.id).toList()).where(ids.contains).toList();
    if (before == null || selected.length != before.length) {
      _selected = selected.isEmpty ? tags.take(1).map((t) => t.id).toList() : selected;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load());
      });
    }
    final series = [
      for (var i = 0; i < _selected!.length; i++)
        if (project.tag(_selected![i]) case final t?) HistorySeries(tag: t, color: Ind.series[i % Ind.series.length], index: i),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(g.name),
        actions: [
          IconButton(
            key: const ValueKey('exportar-csv'),
            tooltip: 'Enviar planilha',
            onPressed: _exporting || tags.isEmpty ? null : () => _export(g),
            icon: _exporting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.share_rounded),
          ),
          IconButton(
            key: const ValueKey('ajustar-registro'),
            tooltip: 'Ajustar registro',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () async {
              final deleted = await LogGroupSheet.show(context, group: g);
              if (deleted && context.mounted) Navigator.pop(context);
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: tags.isEmpty
          ? const EmptyState(icon: Icons.timeline_rounded, title: 'Sem variáveis', body: 'Toque em ajustar (no alto) e escolha o que gravar.')
          : LayoutBuilder(
              builder: (context, box) {
                final top = [
                  _periodChips(),
                  if (tags.length > 1) ...[const SizedBox(height: 12), _seriesChips(tags)],
                  const SizedBox(height: Ind.space),
                  _readout(g, series),
                  const SizedBox(height: 8),
                ];
                final bottom = [
                  const SizedBox(height: 8),
                  _footer(),
                  if (!g.enabled)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('Registro desligado: nada novo está sendo gravado.', style: TextStyle(color: Ind.textDim, fontSize: 13)),
                    ),
                ];
                const pad = EdgeInsets.fromLTRB(Ind.page, 4, Ind.page, 16);
                // Em pé: o gráfico ocupa o que sobra e os controles ficam
                // sempre à vista. Deitado (pouca altura): rola, com o gráfico
                // num tamanho legível.
                if (box.maxHeight < 520) {
                  return ListView(padding: pad, children: [...top, SizedBox(height: 260, child: _chart(g, series)), ...bottom]);
                }
                return Padding(
                  padding: pad,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...top, Expanded(child: _chart(g, series)), ...bottom]),
                );
              },
            ),
    );
  }

  Widget _footer() => Row(children: [
        Expanded(
          child: Text(
            _zoomed ? 'Arraste para os lados para andar no tempo.' : 'Pinça aproxima · toque lê o valor',
            style: TextStyle(color: Ind.textMuted, fontSize: 12.5),
          ),
        ),
        // Reserva a altura do botão: aparecer e sumir não pula o gráfico.
        SizedBox(
          height: Ind.minTouch,
          child: _zoomed
              ? TextButton.icon(
                  key: const ValueKey('mostrar-tudo'),
                  onPressed: _showAll,
                  icon: const Icon(Icons.zoom_out_map_rounded, size: 18),
                  label: const Text('Mostrar tudo'),
                )
              : null,
        ),
      ]);

  Widget _periodChips() {
    final options = [
      (_Period.hour, 'Última hora'),
      (_Period.today, 'Hoje'),
      (_Period.week, '7 dias'),
      (_Period.custom, _period == _Period.custom && _custom != null ? _rangeLabel(_custom!) : 'Escolher'),
    ];
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final (p, label) in options)
        ChoiceChip(
          key: ValueKey('periodo-${p.name}'),
          label: Text(label),
          selected: _period == p,
          onSelected: (_) {
            if (p == _Period.custom) {
              unawaited(_pickRange());
              return;
            }
            setState(() => _applyPeriod(p));
            unawaited(_load());
          },
        ),
    ]);
  }

  static String _rangeLabel(DateTimeRange r) {
    String d(DateTime t) => '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}';
    return r.start == r.end ? d(r.start) : '${d(r.start)} a ${d(r.end)}';
  }

  Widget _seriesChips(List<Tag> tags) {
    final selected = _selected!;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final t in tags)
        FilterChip(
          key: ValueKey('curva-${t.id}'),
          label: Text(t.name),
          selected: selected.contains(t.id),
          showCheckmark: false,
          avatar: selected.contains(t.id)
              ? Container(
                  margin: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: Ind.series[selected.indexOf(t.id) % Ind.series.length], shape: BoxShape.circle),
                )
              : null,
          onSelected: (on) {
            setState(() {
              if (on) {
                selected.add(t.id);
                // Uma quarta curva tira a mais antiga.
                if (selected.length > LogHistoryPage.maxSeries) selected.removeAt(0);
              } else if (selected.length > 1) {
                selected.remove(t.id);
              }
              _window = null;
            });
            unawaited(_load());
          },
        ),
    ]);
  }

  /// O que o dedo marca: hora e o valor de cada curva — o valor exato quando
  /// a fatia é uma linha só, mínimo a máximo quando junta várias.
  ///
  /// Área de **altura fixa**: uma linha para a hora e uma por curva, com ou
  /// sem toque. Sem toque, a mesma área é a legenda (cor e nome de cada
  /// curva) e a linha da hora mostra o trecho à vista. Antes a leitura
  /// entrava em cima do gráfico só depois do toque e o empurrava ~44 dp para
  /// baixo — o gráfico fugia do dedo, e no arrasto do toque longo o ponto lido
  /// não era mais o que estava sob ele. Uma curva por linha: o valor que muda
  /// nunca faz a legenda quebrar em mais uma linha.
  Widget _readout(LogGroup g, List<HistorySeries> series) {
    final line = MediaQuery.textScalerOf(context).scale(20);
    Widget row(Widget child) => SizedBox(height: line, child: Align(alignment: Alignment.centerLeft, child: child));
    final c = _cursor;
    final w = _window;
    final span = _vTo - _vFrom;
    if (c == null || w == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        row(Text('${_clock(_vFrom, span)} – ${_clock(_vTo, span)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Ind.number(15, color: Ind.textMuted))),
        for (final s in series) row(_legend(s, null)),
      ]);
    }
    final b = HistoryPainter.nearBucket(w, c, g.gapThreshold.inMilliseconds);
    final when = b == null
        ? _clock(c, span)
        : b.rows == 1 || b.lastMs - b.firstMs < 1000
            ? _clock(b.firstMs, span)
            : '${_clock(b.firstMs, span)} – ${_clock(b.lastMs, span)}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      row(Text(when, key: const ValueKey('hora-cursor'), maxLines: 1, overflow: TextOverflow.ellipsis, style: Ind.number(15, color: Ind.text))),
      for (final s in series)
        row(_legend(
          s,
          b == null
              ? 'sem registro'
              : b.counts[s.index] == 0
                  ? 'sem comunicação'
                  : _range(s.tag, b.min[s.index]!, b.max[s.index]!),
        )),
    ]);
  }

  static String _clock(int ms, int spanMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    final t = '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
    return spanMs > 20 * 3600 * 1000 ? '${two(d.day)}/${two(d.month)} $t' : t;
  }

  static String _range(Tag t, double lo, double hi) {
    if (t.dataType == TagDataType.bool) return lo == hi ? TagCodec.format(t, lo != 0) : 'ligou e desligou';
    if ((hi - lo).abs() < 1e-9) return TagCodec.format(t, lo);
    return '${TagCodec.format(t, lo, withUnit: false)} a ${TagCodec.format(t, hi)}';
  }

  /// Cor e nome da curva; com o toque, o valor ao lado. Nome longo é que
  /// encolhe ("Temperatura do mo…: 74,0 °C"), nunca o valor.
  Widget _legend(HistorySeries s, String? value) => Row(children: [
        Container(width: 12, height: 3, decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Flexible(
          child: Text(value == null ? s.tag.name : '${s.tag.name}: ',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Ind.textDim, fontSize: 13)),
        ),
        if (value != null) Text(value, maxLines: 1, style: Ind.number(14, color: Ind.textFor(s.color))),
      ]);

  Widget _chart(LogGroup g, List<HistorySeries> series) {
    final w = _window;
    return Container(
      decoration: Ind.card(),
      padding: const EdgeInsets.fromLTRB(8, 12, 10, 6),
      child: LayoutBuilder(builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        final plot = HistoryPainter.plotFor(size, dual: HistoryPainter.isDual(series));
        _plotWidth = plot.width;
        return Stack(children: [
          GestureDetector(
            key: const ValueKey('grafico-historico'),
            behavior: HitTestBehavior.opaque,
            onScaleStart: (d) {
              _gFrom = _vFrom;
              _gTo = _vTo;
              _gFocal = d.localFocalPoint.dx;
            },
            onScaleUpdate: (d) => _onScale(d, plot, g),
            onScaleEnd: (_) {
              _gFrom = null;
              _gTo = null;
              _schedule();
            },
            onTapUp: (d) => setState(() => _cursor = _timeAt(d.localPosition.dx, plot)),
            onLongPressStart: (d) => setState(() => _cursor = _timeAt(d.localPosition.dx, plot)),
            onLongPressMoveUpdate: (d) => setState(() => _cursor = _timeAt(d.localPosition.dx, plot)),
            child: CustomPaint(
              size: size,
              painter: HistoryPainter(
                window: w ?? LogWindow(fromMs: _vFrom, toMs: _vTo, tagIds: const [], buckets: const []),
                series: series,
                fromMs: _vFrom,
                toMs: _vTo,
                gapMs: g.gapThreshold.inMilliseconds,
                cursorMs: _cursor,
              ),
            ),
          ),
          if (w != null && w.isEmpty)
            IgnorePointer(
              child: Center(
                child: Text('Nada gravado neste período', style: TextStyle(color: Ind.textMuted, fontWeight: FontWeight.w600)),
              ),
            ),
        ]);
      }),
    );
  }
}

/// Escolher dias: toque no primeiro e no último (o mesmo dia duas vezes =
/// só ele). Lista do hoje para trás até a retenção do registro — antes disso
/// não há o que ver.
class _DaysSheet extends StatefulWidget {
  const _DaysSheet({required this.days});
  final int days;

  @override
  State<_DaysSheet> createState() => _DaysSheetState();
}

class _DaysSheetState extends State<_DaysSheet> {
  DateTime? _first;

  static const _weekdays = ['seg', 'ter', 'qua', 'qui', 'sex', 'sáb', 'dom'];

  static String _label(DateTime d, int ago) {
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${two(d.day)}/${two(d.month)}';
    if (ago == 0) return 'Hoje · $date';
    if (ago == 1) return 'Ontem · $date';
    return '${_weekdays[d.weekday - 1]} · $date';
  }

  void _tap(DateTime d) {
    final first = _first;
    if (first == null) {
      setState(() => _first = d);
      return;
    }
    Navigator.pop(context, first.isAfter(d) ? DateTimeRange(start: d, end: first) : DateTimeRange(start: first, end: d));
  }

  @override
  Widget build(BuildContext context) {
    final now = clock.now();
    final today = DateTime(now.year, now.month, now.day);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView.builder(
        controller: scroll,
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: widget.days + 2,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 4),
              child: Text('Escolher dias', style: Theme.of(context).textTheme.titleLarge),
            );
          }
          if (i == 1) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 12),
              child: Text(_first == null ? 'Toque no primeiro dia e depois no último.' : 'Agora o último dia (o mesmo de novo = só ele).',
                  style: TextStyle(color: Ind.textDim)),
            );
          }
          final ago = i - 2;
          final d = DateTime(today.year, today.month, today.day - ago);
          final selected = _first == d;
          return ListTile(
            key: ValueKey('dia-$ago'),
            selected: selected,
            selectedColor: Ind.accent,
            selectedTileColor: Ind.accent.withValues(alpha: 0.10),
            leading: Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded),
            title: Text(_label(d, ago)),
            onTap: () => _tap(d),
          );
        },
      ),
    );
  }
}
