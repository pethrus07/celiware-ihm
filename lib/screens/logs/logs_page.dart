import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../models/log_group.dart';
import '../../models/tag.dart';
import '../../widgets/common/adaptive.dart';
import '../../widgets/common/common.dart';
import 'log_history_page.dart';
import '../tours.dart';
import '../../widgets/tour/tour.dart';

/// Ferramentas → Registros: os grupos de variáveis gravadas no aparelho.
///
/// Uma linha por grupo com o essencial — ritmo, quantas variáveis, quanto
/// ocupa — e a chave liga/desliga. Tocar abre o histórico; ajustar fica lá
/// dentro, onde se percebe o efeito.
class LogsPage extends StatelessWidget {
  const LogsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.watch(context);
    final groups = scope.controller.project.logGroups;
    // "?" explica a página (não abre sozinho).
    return TourHost(
      spec: Tours.registros(),
      autoStart: false,
      child: ListenableBuilder(
      listenable: scope.logger,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Registros'), actions: const [HelpButton()]),
        floatingActionButton: groups.isEmpty
            ? null
            : FloatingActionButton.extended(
                key: const ValueKey('novo-registro'),
                onPressed: () => LogGroupSheet.show(context),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Novo registro'),
              ),
        body: groups.isEmpty
            ? EmptyState(
                icon: Icons.timeline_rounded,
                title: 'Nenhum registro',
                body: 'Grave variáveis no aparelho para ver o histórico em gráfico e enviar a planilha.',
                action: FilledButton.icon(
                  key: const ValueKey('criar-registro'),
                  onPressed: () => LogGroupSheet.show(context),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Criar registro'),
                ),
              )
            // No tablet, a coluna dos registros não estica até a borda (TB-3).
            : FormWidth(child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 100),
                children: [
                  if (scope.logger.problem != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Ind.page, 4, Ind.page, 12),
                      child: Text(scope.logger.problem!, style: TextStyle(color: Ind.textFor(Ind.alarm), fontWeight: FontWeight.w600)),
                    ),
                  for (final g in groups) _GroupTile(group: g),
                  // Limite dito na tela, não descoberto no histórico.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Ind.page, 20, Ind.page, 0),
                    child: Text('Grava com o app aberto, em qualquer tela. Com o app fechado o histórico mostra o intervalo vazio.',
                        style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.4)),
                  ),
                ],
              )),
      ),
    ));
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({required this.group});
  final LogGroup group;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final g = group;
    final count = g.tagIds.where((id) => scope.controller.project.tag(id) != null).length;
    final bytes = scope.logger.usageOf(g.id);
    final summary = [
      if (!g.enabled) 'Desligado' else if (g.mode == LogMode.onChange) 'Ao mudar' else 'A cada ${LogGroup.durationLabel(g.intervalSec)}',
      count == 1 ? '1 variável' : '$count variáveis',
      if (bytes > 0) LogGroup.sizeLabel(bytes.toDouble()),
    ].join(' · ');
    return ListTile(
      key: ValueKey('registro-${g.id}'),
      leading: Icon(g.enabled ? Icons.timeline_rounded : Icons.pause_circle_outline_rounded, color: g.enabled ? Ind.accent : Ind.textMuted),
      title: Text(g.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
      subtitle: Padding(padding: const EdgeInsets.only(top: 3), child: Text(summary)),
      trailing: Switch(
        key: ValueKey('ligar-${g.id}'),
        value: g.enabled,
        onChanged: (v) => scope.controller.saveLogGroup(g.copyWith(enabled: v)),
      ),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LogHistoryPage(groupId: g.id))),
    );
  }
}

/// Folha de criar/ajustar um registro. À vista: nome, variáveis, ritmo e
/// quanto tempo guardar (com o tamanho estimado). O resto — "ao mudar",
/// banda morta, máximo entre amostras — em "Mais opções".
class LogGroupSheet extends StatefulWidget {
  const LogGroupSheet({super.key, this.group});
  final LogGroup? group;

  /// Abre a folha. Devolve `true` se o registro foi apagado.
  static Future<bool> show(BuildContext context, {LogGroup? group}) async =>
      await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => LogGroupSheet(group: group),
      ) ??
      false;

  @override
  State<LogGroupSheet> createState() => _LogGroupSheetState();
}

class _LogGroupSheetState extends State<LogGroupSheet> {
  late final _name = TextEditingController(text: widget.group?.name ?? '');
  late final _deadband = TextEditingController(text: _num(widget.group?.deadband ?? 0));
  late final Set<String> _tags = {...?widget.group?.tagIds};
  late int _interval = widget.group?.intervalSec ?? 1;
  late int _retention = widget.group?.retentionDays ?? 7;
  late LogMode _mode = widget.group?.mode ?? LogMode.periodic;
  late int _maxGap = widget.group?.maxGapSec ?? 600;
  final _moreKey = GlobalKey();
  String? _error;

  bool get _editing => widget.group != null;

  @override
  void dispose() {
    _name.dispose();
    _deadband.dispose();
    super.dispose();
  }

  static String _num(double v) => v == 0 ? '' : (v == v.roundToDouble() ? v.round().toString() : v.toString()).replaceAll('.', ',');

  double get _deadbandValue => double.tryParse(_deadband.text.trim().replaceAll(',', '.')) ?? 0;

  LogGroup _draft(List<String> ids, String name) => (widget.group ?? LogGroup(id: newId('lg'))).copyWith(
        name: name,
        tagIds: ids,
        intervalSec: _interval,
        retentionDays: _retention,
        mode: _mode,
        deadband: _deadbandValue,
        maxGapSec: _maxGap,
      );

  void _save(List<Tag> loggable) {
    final c = AppScope.of(context).controller;
    final ids = [for (final t in loggable) if (_tags.contains(t.id)) t.id];
    if (ids.isEmpty) {
      setState(() => _error = 'Escolha ao menos uma variável.');
      return;
    }
    final name = _name.text.trim().isEmpty ? 'Registro ${c.project.logGroups.length + (_editing ? 0 : 1)}' : _name.text.trim();
    c.saveLogGroup(_draft(ids, name));
    Navigator.pop(context, false);
  }

  Future<void> _delete() async {
    final g = widget.group!;
    final logger = AppScope.of(context).logger;
    final bytes = logger.usageOf(g.id);
    final ok = await confirmDelete(
      context,
      title: 'Apagar o registro?',
      body: bytes > 0 ? 'O histórico gravado (${LogGroup.sizeLabel(bytes.toDouble())}) também é apagado.' : 'Nada foi gravado ainda.',
    );
    if (!ok || !mounted) return;
    await logger.deleteGroup(g.id);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final project = AppScope.of(context).controller.project;
    final loggable = [for (final t in project.tags) if (LogGroup.canLog(t)) t];
    final chosen = [for (final t in loggable) if (_tags.contains(t.id)) t];
    final estimate = _draft(chosen.map((t) => t.id).toList(), '').estimateBytes(chosen);
    final multiDevice = loggable.map((t) => t.deviceId).toSet().length > 1;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.86,
      maxChildSize: 0.96,
      builder: (context, scroll) => Column(children: [
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 24),
            children: [
              Text(_editing ? 'Registro' : 'Novo registro', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Ind.space),
              TextField(
                key: const ValueKey('nome-registro'),
                controller: _name,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Nome', hintText: 'Ex.: Temperaturas do forno'),
              ),
              const SizedBox(height: Ind.spaceLarge),
              _label('Variáveis'),
              if (loggable.isEmpty)
                Text('Cadastre uma variável de número ou liga/desliga primeiro.', style: TextStyle(color: Ind.textDim))
              else
                for (final d in project.devices)
                  if (loggable.any((t) => t.deviceId == d.id)) ...[
                    if (multiDevice) Padding(padding: const EdgeInsets.only(top: 4, bottom: 8), child: Text(d.name, style: TextStyle(color: Ind.textMuted, fontSize: 13))),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final t in loggable.where((t) => t.deviceId == d.id))
                        FilterChip(
                          key: ValueKey('var-registro-${t.id}'),
                          label: Text(t.name),
                          selected: _tags.contains(t.id),
                          onSelected: (on) => setState(() {
                            on ? _tags.add(t.id) : _tags.remove(t.id);
                            _error = null;
                          }),
                        ),
                    ]),
                    const SizedBox(height: 8),
                  ],
              const SizedBox(height: Ind.spaceLarge - 8),
              _label('Registrar a cada'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final s in LogGroup.intervalChoices)
                  ChoiceChip(
                    key: ValueKey('intervalo-$s'),
                    label: Text(LogGroup.durationLabel(s)),
                    selected: _interval == s,
                    onSelected: (_) => setState(() {
                      _interval = s;
                      if (_maxGap < s) _maxGap = s;
                    }),
                  ),
              ]),
              const SizedBox(height: Ind.spaceLarge),
              _label('Guardar'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final d in LogGroup.retentionChoices)
                  ChoiceChip(
                    key: ValueKey('guardar-$d'),
                    label: Text(LogGroup.daysLabel(d)),
                    selected: _retention == d,
                    onSelected: (_) => setState(() => _retention = d),
                  ),
              ]),
              if (chosen.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  '${_mode == LogMode.onChange ? 'Até ' : ''}~${LogGroup.sizeLabel(estimate)} no aparelho',
                  key: const ValueKey('estimativa-registro'),
                  style: TextStyle(color: Ind.textMuted, fontSize: 13),
                ),
              ],
              const SizedBox(height: Ind.space),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: _moreKey,
                  onExpansionChanged: (open) => revealAfterExpand(_moreKey, open),
                  initiallyExpanded: _mode == LogMode.onChange,
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  title: const Text('Mais opções'),
                  subtitle: Text(_modeSummary(), style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                  children: [
                    ChoiceCards<LogMode>(
                      options: const [
                        ChoiceOption(value: LogMode.periodic, title: 'Sempre', subtitle: 'Uma linha a cada intervalo', icon: Icons.av_timer_rounded),
                        ChoiceOption(value: LogMode.onChange, title: 'Ao mudar', subtitle: 'Economiza com valor parado', icon: Icons.show_chart_rounded),
                      ],
                      selected: _mode,
                      onChanged: (m) => setState(() => _mode = m),
                    ),
                    if (_mode == LogMode.onChange) ...[
                      const SizedBox(height: Ind.space),
                      TextField(
                        key: const ValueKey('banda-morta'),
                        controller: _deadband,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: Ind.number(20),
                        decoration: const InputDecoration(
                          labelText: 'Ignorar mudança menor que',
                          hintText: '0 = qualquer mudança',
                          helperText: 'Na unidade de cada variável. Liga/desliga grava sempre que troca.',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: Ind.space),
                      const SectionHeader('Gravar ao menos a cada', padding: EdgeInsets.zero),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final s in LogGroup.maxGapChoices)
                          if (s >= _interval)
                            ChoiceChip(
                              key: ValueKey('maximo-$s'),
                              label: Text(LogGroup.durationLabel(s)),
                              selected: _maxGap == s,
                              onSelected: (_) => setState(() => _maxGap = s),
                            ),
                      ]),
                    ],
                  ],
                ),
              ),
              if (_editing) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('apagar-registro'),
                    onPressed: _delete,
                    style: TextButton.styleFrom(foregroundColor: Ind.textFor(Ind.alarm)),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Apagar registro'),
                  ),
                ),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Ind.page, 8, Ind.page, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              // Junto do botão, sempre à vista: no meio da folha, abaixo de
              // uma lista longa de variáveis, o aviso ficava fora da tela.
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: Ind.textFor(Ind.alarm), fontWeight: FontWeight.w600)),
                ),
              FilledButton.icon(
                key: const ValueKey('salvar-registro'),
                onPressed: () => _save(loggable),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Salvar'),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  String _modeSummary() {
    if (_mode == LogMode.periodic) return 'Grava sempre, mudando ou não';
    final band = _deadbandValue;
    return [
      band > 0 ? 'Ao mudar mais que ${_num(band)}' : 'A cada mudança',
      'ao menos a cada ${LogGroup.durationLabel(_maxGap)}',
    ].join(' · ');
  }

  static Widget _label(String text) => SectionHeader(text, padding: const EdgeInsets.only(bottom: 10));
}
