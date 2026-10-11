import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/modbus/modbus_memory.dart';
import '../../core/theme/app_theme.dart';
import '../../models/device.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../../models/vendor_profiles.dart';
import '../../services/import/tag_batch.dart';
import '../../widgets/common/common.dart';

/// Arquivo escolhido para importar: o nome (para mostrar) e o conteúdo.
typedef CsvFile = ({String name, Uint8List bytes});

/// "Criar várias": muitas variáveis de uma vez, numa tela só.
///
/// Quarenta variáveis eram quarenta formulários. Aqui a pessoa diz a faixa como
/// está no manual ("de D0 até D99"), confere a prévia — quantas são, as
/// primeiras e as últimas, quanto custam por ciclo de leitura, quais já
/// existem — e cria tudo num toque, gravado de uma vez só
/// (`ProjectController.saveTags`). A segunda opção é importar um CSV no
/// modelo Celiware.
///
/// À vista só o essencial: área, de/até, tipo e nome. Gravável, ordem de bytes
/// e EEPROM ficam em "Mais opções".
class BulkTagsPage extends StatefulWidget {
  const BulkTagsPage({super.key, this.preferDeviceId, this.pickCsv});

  /// Equipamento já marcado; sem ele, o último cadastrado (como no cadastro
  /// de uma variável).
  final String? preferDeviceId;

  /// Troca o seletor de arquivo do sistema (testes).
  final Future<CsvFile?> Function()? pickCsv;

  @override
  State<BulkTagsPage> createState() => _BulkTagsPageState();
}

enum _Mode { range, csv }

class _BulkTagsPageState extends State<BulkTagsPage> {
  final _moreKey = GlobalKey();
  final _from = TextEditingController();
  final _to = TextEditingController();
  final _prefix = TextEditingController();

  String? _deviceId;
  _Mode _mode = _Mode.range;
  String? _areaKey;
  TagDataType _type = TagDataType.uint16;
  bool _writable = false;

  /// Nulo = a ordem padrão da marca.
  ByteOrder? _order;
  bool _noEeprom = false;
  final Set<String> _skippedTemplates = {};
  ConflictPolicy _policy = ConflictPolicy.skip;
  CsvFile? _csv;
  String? _csvError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final project = AppScope.of(context).controller.project;
    final preferred = widget.preferDeviceId;
    final devices = _devices(project);
    _deviceId ??= preferred != null && devices.any((d) => d.id == preferred) ? preferred : devices.lastOrNull?.id;
  }

  @override
  void dispose() {
    for (final c in [_from, _to, _prefix]) {
      c.dispose();
    }
    super.dispose();
  }

  /// A área marcada; se ela não existe no equipamento atual (trocou de
  /// equipamento ou de marca), volta para a padrão com a faixa sugerida.
  BatchArea _area(List<BatchArea> areas) {
    final a = areas.where((x) => x.key == _areaKey).firstOrNull;
    if (a != null) return a;
    final d = TagBatchBuilder.defaultArea(areas);
    _selectArea(d, notify: false);
    return d;
  }

  void _selectArea(BatchArea a, {bool notify = true}) {
    _areaKey = a.key;
    final (from, to) = TagBatchBuilder.defaultRange(a);
    _from.text = from;
    _to.text = to;
    final types = _types(a);
    if (a case ProfileArea(rule: AreaRule(forcedType: final forced?))) {
      _type = forced;
    } else if (types.isNotEmpty && !types.contains(_type)) {
      _type = TagDataType.uint16;
    }
    if (!_canWrite(a)) _writable = false;
    if (a is! ParameterArea) _noEeprom = false;
    if (notify) setState(() {});
  }

  /// Tipos oferecidos: área de bit é sempre liga/desliga e contador de 32 bits
  /// é sempre INT32 — nesses, nem pergunta.
  static List<TagDataType> _types(BatchArea a) => switch (a) {
        ProfileArea(:final rule) when rule.isBit || rule.forcedType != null => const [],
        ModbusAreaChoice(:final area) when area.isBit => const [],
        TemplateArea() => const [],
        ParameterArea() => const [TagDataType.uint16, TagDataType.int16],
        _ => const [TagDataType.uint16, TagDataType.int16, TagDataType.uint32, TagDataType.int32, TagDataType.float32],
      };

  static bool _canWrite(BatchArea a) => switch (a) {
        ProfileArea(:final rule) => rule.area.isWritable && !rule.readOnly,
        ModbusAreaChoice(:final area) => area.isWritable,
        _ => true,
      };

  (TagBatch?, String?) _compute(Project project, Device device, BatchArea area) {
    try {
      if (_mode == _Mode.csv) {
        final csv = _csv;
        return (csv == null ? null : TagBatchBuilder.csv(project: project, device: device, bytes: csv.bytes), null);
      }
      if (area is TemplateArea) {
        return (
          TagBatchBuilder.templates(project: project, device: device, templates: [
            for (final t in area.templates)
              if (!_skippedTemplates.contains(t.key)) t,
          ]),
          null,
        );
      }
      return (
        TagBatchBuilder.range(
          project: project,
          device: device,
          area: area,
          from: _from.text,
          to: _to.text,
          type: _type,
          namePrefix: _prefix.text,
          writable: _writable,
          byteOrder: _order,
          noEeprom: _noEeprom,
        ),
        null,
      );
    } on BatchError catch (e) {
      return (null, e.message);
    }
  }

  void _create(TagBatch batch, List<Tag> tags) {
    AppScope.of(context).controller.saveTags(tags);
    final replaced = _policy == ConflictPolicy.replace ? batch.conflicts : 0;
    final created = tags.length - replaced;
    final parts = [
      if (created > 0) created == 1 ? '1 variável criada' : '$created variáveis criadas',
      if (replaced > 0) replaced == 1 ? '1 substituída' : '$replaced substituídas',
    ];
    Navigator.pop(context, parts.join(' · '));
  }

  Future<void> _pickCsv() async {
    try {
      final f = await (widget.pickCsv ?? _systemPicker)();
      if (f == null || !mounted) return;
      setState(() {
        _csv = f;
        _csvError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _csvError = 'Não consegui abrir o arquivo: $e');
    }
  }

  static Future<CsvFile?> _systemPicker() async {
    // Qualquer tipo: o filtro por extensão do Android esconde CSV que o
    // aparelho rotula com outro tipo (text/comma-separated-values). O conteúdo
    // é conferido linha a linha de qualquer jeito.
    final f = await FilePicker.pickFile(dialogTitle: 'Arquivo CSV de variáveis');
    if (f == null) return null;
    return (name: f.name, bytes: await f.readAsBytes());
  }

  /// Só equipamento com memória Modbus: faixa e CSV geram área + endereço.
  static List<Device> _devices(Project project) => [for (final d in project.devices) if (d.usesModbusMemory) d];

  @override
  Widget build(BuildContext context) {
    final project = AppScope.watch(context).controller.project;
    final devices = _devices(project);
    final device = devices.where((d) => d.id == _deviceId).firstOrNull;
    if (device == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Criar várias')),
        body: const EmptyState(icon: Icons.router_outlined, title: 'Falta o equipamento', body: 'As variáveis moram num equipamento. Cadastre ele primeiro.'),
      );
    }
    final profile = VendorProfiles.of(device);
    final areas = TagBatchBuilder.areasFor(profile);
    final area = _area(areas);
    final (batch, error) = _compute(project, device, area);
    final toCreate = batch?.resolve(_policy) ?? const <Tag>[];
    final replacing = _policy == ConflictPolicy.replace ? batch?.conflicts ?? 0 : 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Criar várias')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            key: const ValueKey('criar-lote'),
            onPressed: toCreate.isEmpty ? null : () => _create(batch!, toCreate),
            icon: const Icon(Icons.check_rounded),
            label: Text(toCreate.isEmpty
                ? ((batch?.count ?? 0) > 0 ? 'Nada novo para criar' : 'Criar')
                : replacing > 0
                    ? 'Criar ${toCreate.length - replacing} · substituir $replacing'
                    : 'Criar ${toCreate.length} ${toCreate.length == 1 ? 'variável' : 'variáveis'}'),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Ind.page, 12, Ind.page, 32),
        children: [
          // Um equipamento só (o caso comum): nem pergunta.
          if (devices.length > 1) ...[
            const SectionHeader('Equipamento', padding: EdgeInsets.fromLTRB(0, 16, 0, 12)),
            ChoiceCards<String>(
              options: [
                for (final d in devices) ChoiceOption(value: d.id, title: d.name, icon: d.isDemo ? Icons.smart_toy_outlined : Icons.router_outlined),
              ],
              selected: device.id,
              onChanged: (id) => setState(() => _deviceId = id),
            ),
            const SizedBox(height: Ind.space),
          ],
          // A marca manda na notação; discreta, com a origem da tabela.
          Text(
            profile == null ? 'Modbus genérico · escolha a marca no cadastro do equipamento' : '${profile.name} · ${profile.origin.caption}',
            key: const ValueKey('lote-perfil'),
            style: TextStyle(color: Ind.textMuted, fontSize: 13),
          ),
          const SizedBox(height: Ind.space),
          SegmentedButton<_Mode>(
            segments: const [
              ButtonSegment(value: _Mode.range, icon: Icon(Icons.linear_scale_rounded), label: Text('Faixa', key: ValueKey('modo-faixa'))),
              ButtonSegment(value: _Mode.csv, icon: Icon(Icons.upload_file_rounded), label: Text('Arquivo CSV', key: ValueKey('modo-csv'))),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          if (_mode == _Mode.range) ..._rangeFields(area, areas, profile, error) else ..._csvFields(profile, error),
          if (batch != null && (batch.count > 0 || batch.errors.isNotEmpty)) ...[
            const SizedBox(height: Ind.spaceLarge),
            _Preview(batch: batch, policy: _policy, device: device, onPolicy: (p) => setState(() => _policy = p)),
          ],
        ],
      ),
    );
  }

  /// [error] aparece logo abaixo de De/Até: é ali que a pessoa está olhando
  /// quando digita "X8".
  List<Widget> _rangeFields(BatchArea area, List<BatchArea> areas, VendorProfile? profile, String? error) {
    final types = _types(area);
    final muted = TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.35);
    final pairs = types.isNotEmpty && _type.is32Bit && !(area is ProfileArea && area.rule.wordsPerItem > 1);
    return [
      const SectionHeader('Área', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final a in areas) ChoiceChip(key: ValueKey(a.key), label: Text(a.chip), selected: a.key == area.key, onSelected: (_) => _selectArea(a)),
      ]),
      const SizedBox(height: 8),
      Text(area.hint, key: const ValueKey('area-dica'), style: muted),
      if (area is TemplateArea) ...[
        const SizedBox(height: Ind.spaceSmall),
        for (final t in area.templates)
          CheckboxListTile(
            key: ValueKey('modelo-${t.key}'),
            contentPadding: EdgeInsets.zero,
            value: !_skippedTemplates.contains(t.key),
            onChanged: (v) => setState(() => v == true ? _skippedTemplates.remove(t.key) : _skippedTemplates.add(t.key)),
            title: Text(t.name),
            subtitle: Text(t.description, style: muted),
          ),
        if (error != null) _ErrorLine(error),
      ] else ...[
        const SizedBox(height: Ind.spaceLarge),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _rangeField(_from, 'De', area, const ValueKey('faixa-de'))),
          const SizedBox(width: 12),
          Expanded(child: _rangeField(_to, 'Até', area, const ValueKey('faixa-ate'))),
        ]),
        if (error != null) _ErrorLine(error),
        if (types.isNotEmpty) ...[
          const SectionHeader('Tipo', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final t in types)
              ChoiceChip(key: ValueKey('tipo-${t.name}'), label: Text('${t.label} · ${t.technical}'), selected: _type == t, onSelected: (_) => setState(() => _type = t)),
          ]),
          if (pairs) ...[
            const SizedBox(height: 8),
            Text('32 bits ocupa dois registradores: a faixa anda de 2 em 2 (${_pairExample(area)}).', style: muted),
          ],
        ],
        const SizedBox(height: Ind.spaceLarge),
        TextField(
          key: const ValueKey('nome-prefixo'),
          controller: _prefix,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Nome', hintText: 'Vazio = a própria memória', helperText: 'Com texto, vira o texto + o número: "Temperatura 200".'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Ind.spaceSmall),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: _moreKey,
            tilePadding: EdgeInsets.zero,
            onExpansionChanged: (open) => revealAfterExpand(_moreKey, open),
            childrenPadding: const EdgeInsets.only(bottom: 8),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            title: const Text('Mais opções'),
            subtitle: Text(_moreSummary(area, profile, pairs), style: TextStyle(color: Ind.textMuted, fontSize: 13)),
            children: [
              SwitchListTile(
                key: const ValueKey('lote-gravavel'),
                contentPadding: EdgeInsets.zero,
                value: (_writable || _noEeprom) && _canWrite(area),
                onChanged: _canWrite(area) && !_noEeprom ? (v) => setState(() => _writable = v) : null,
                title: const Text('Podem ser alteradas pela tela'),
                subtitle: _canWrite(area) ? null : const Text('Esta área é só de leitura.'),
              ),
              if (pairs) ...[
                const SectionHeader('Ordem dos bytes', padding: EdgeInsets.fromLTRB(0, 16, 0, 10)),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final o in ByteOrder.values)
                    ChoiceChip(
                      label: Text(o == (profile?.defaultByteOrder ?? ByteOrder.abcd) ? '${o.label} · padrão${profile == null ? '' : ' da marca'}' : '${o.label} · ${o.hint}'),
                      selected: (_order ?? profile?.defaultByteOrder ?? ByteOrder.abcd) == o,
                      onSelected: (_) => setState(() => _order = o),
                    ),
                ]),
              ],
              if (area is ParameterArea)
                SwitchListTile(
                  key: const ValueKey('sem-eeprom'),
                  contentPadding: EdgeInsets.zero,
                  value: _noEeprom,
                  onChanged: (v) => setState(() => _noEeprom = v),
                  title: const Text('Não gravar na EEPROM'),
                  subtitle: Text('Grava só na RAM do inversor, sem gastar a memória dele. Esse endereço não pode ser lido: a variável fica só para gravar.', style: muted),
                ),
            ],
          ),
        ),
      ],
    ];
  }

  Widget _rangeField(TextEditingController c, String label, BatchArea area, Key key) {
    final prefix = area is ProfileArea ? area.rule.prefix : null;
    return TextField(
      key: key,
      controller: c,
      // Número puro abre o teclado numérico, que é o que se usa de luva.
      keyboardType: area is ParameterArea ? TextInputType.text : TextInputType.number,
      textCapitalization: TextCapitalization.characters,
      style: Ind.number(20),
      decoration: InputDecoration(labelText: label, prefixText: prefix),
      onChanged: (_) => setState(() {}),
    );
  }

  /// "D100, D102, D104…" a partir do que está no "De" (área de registrador é
  /// sempre decimal).
  String _pairExample(BatchArea area) {
    final digits = _from.text.replaceAll(RegExp(r'\D'), '');
    if (area case ProfileArea(:final rule)) {
      final n = int.tryParse(digits) ?? rule.firstNumber;
      return '${rule.text(n)}, ${rule.text(n + 2)}, ${rule.text(n + 4)}…';
    }
    final raw = _from.text.trim().toLowerCase();
    final n = (raw.startsWith('0x') ? int.tryParse(raw.substring(2), radix: 16) : int.tryParse(digits)) ?? 0;
    return '$n, ${n + 2}, ${n + 4}…';
  }

  String _moreSummary(BatchArea area, VendorProfile? profile, bool pairs) => [
        if (_noEeprom) 'Sem EEPROM' else if (_writable && _canWrite(area)) 'Podem ser alteradas' else 'Só leitura',
        if (pairs) (_order ?? profile?.defaultByteOrder ?? ByteOrder.abcd).label,
      ].join(' · ');

  List<Widget> _csvFields(VendorProfile? profile, String? error) {
    final muted = TextStyle(color: Ind.textMuted, fontSize: 12.5, height: 1.4);
    return [
      const SizedBox(height: Ind.spaceLarge),
      Text('Uma variável por linha. O cabeçalho do modelo:', style: TextStyle(color: Ind.textDim, height: 1.35)),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Ind.surfaceHigh, borderRadius: BorderRadius.circular(Ind.radiusSmall)),
        child: SelectableText(TagCsv.template, style: const TextStyle(fontFamily: Ind.mono, fontSize: 13)),
      ),
      const SizedBox(height: 8),
      Text(
        '${profile == null ? 'Memória: HR 200, COIL 5 ou 40201' : 'Memória como no manual (${profile.example}) ou HR 200'}. '
        'Separador ; ou , · escala 0,1 ou ÷10 · gravavel sim ou não. Só a memória é obrigatória.',
        style: muted,
      ),
      const SizedBox(height: Ind.space),
      OutlinedButton.icon(
        key: const ValueKey('escolher-csv'),
        onPressed: _pickCsv,
        icon: const Icon(Icons.upload_file_rounded),
        label: Text(_csv == null ? 'Escolher arquivo' : 'Trocar arquivo'),
      ),
      if (_csv != null) ...[
        const SizedBox(height: 8),
        Text(_csv!.name, key: const ValueKey('csv-nome'), style: muted),
      ],
      if (_csvError != null) _ErrorLine(_csvError!),
      if (error != null) _ErrorLine(error),
    ];
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Ind.space),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.error_outline_rounded, color: Ind.alarm, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, key: const ValueKey('erro-lote'), style: TextStyle(color: Ind.textFor(Ind.alarm), fontWeight: FontWeight.w600, height: 1.35))),
        ]),
      );
}

/// Prévia do lote: quantas, as primeiras e as últimas, custo de leitura,
/// avisos, conflitos e linhas recusadas do CSV.
class _Preview extends StatelessWidget {
  const _Preview({required this.batch, required this.policy, required this.device, required this.onPolicy});
  final TagBatch batch;
  final ConflictPolicy policy;
  final Device device;
  final ValueChanged<ConflictPolicy> onPolicy;

  @override
  Widget build(BuildContext context) {
    final items = batch.items;
    final sample = items.length <= 10 ? <BatchItem?>[...items] : <BatchItem?>[...items.take(5), null, ...items.skip(items.length - 5)];
    final reads = items.isEmpty ? 0 : batch.readsPerCycle;
    final conflicts = batch.conflicts;
    final errors = batch.errors;
    final muted = TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.35);
    final warn = TextStyle(color: Ind.textFor(Ind.warn), fontSize: 13, height: 1.35, fontWeight: FontWeight.w600);
    // Atrás de gateway RS-485, 125 registradores a 19200 bps levam ~150 ms
    // por leitura (conta da pesquisa): oito leituras já passam do ciclo.
    final slowLink = device.kind == DeviceKind.modbusRtuTcp && reads * 150 > device.pollMs;

    return Container(
      key: const ValueKey('previa'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Ind.surface, borderRadius: BorderRadius.circular(Ind.radius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text('${batch.count}', key: const ValueKey('previa-contagem'), style: Ind.number(30)),
          const SizedBox(width: 8),
          Text(batch.count == 1 ? 'variável' : 'variáveis', style: TextStyle(color: Ind.textDim)),
        ]),
        if (items.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final i in sample)
            if (i == null)
              Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text('…', style: muted))
            else
              _SampleRow(item: i),
          const SizedBox(height: 12),
          Row(children: [
            Icon(Icons.speed_rounded, size: 18, color: Ind.textMuted),
            const SizedBox(width: 8),
            Expanded(child: Text('Todas na tela: $reads ${reads == 1 ? 'leitura' : 'leituras'} por ciclo', key: const ValueKey('previa-leituras'), style: muted)),
          ]),
        ],
        if (slowLink) ...[
          const SizedBox(height: 8),
          Text('Pelo gateway RS-485 cada leitura leva até ~150 ms: com todas na tela, o ciclo passa de ${reads * 150} ms.', style: warn),
        ],
        if (batch.large) ...[
          const SizedBox(height: 8),
          Text('São muitas de uma vez. A lista aguenta, mas confira se precisa de todas: cada tela que usar muitas lê mais devagar.',
              key: const ValueKey('previa-aviso'), style: warn),
        ],
        if (conflicts > 0) ...[
          const SizedBox(height: 16),
          Text('$conflicts já ${conflicts == 1 ? 'existe' : 'existem'} neste equipamento', key: const ValueKey('previa-conflitos'), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<ConflictPolicy>(
            segments: const [
              ButtonSegment(value: ConflictPolicy.skip, label: Text('Pular', key: ValueKey('conflito-pular'))),
              ButtonSegment(value: ConflictPolicy.replace, label: Text('Substituir', key: ValueKey('conflito-substituir'))),
            ],
            selected: {policy},
            onSelectionChanged: (s) => onPolicy(s.first),
          ),
          const SizedBox(height: 6),
          Text(policy == ConflictPolicy.skip ? 'As que já existem ficam como estão.' : 'As que já existem ganham a definição nova; as telas e os alarmes continuam ligados a elas.',
              style: muted),
        ],
        if (errors.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('${errors.length} ${errors.length == 1 ? 'linha ficou' : 'linhas ficaram'} de fora:',
              key: const ValueKey('csv-erros'), style: TextStyle(color: Ind.textFor(Ind.alarm), fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          for (final e in errors.take(20))
            Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(e.text, style: TextStyle(color: Ind.textFor(Ind.alarm), fontSize: 13, height: 1.35))),
          if (errors.length > 20) Text('e mais ${errors.length - 20}', style: muted),
        ],
      ]),
    );
  }
}

class _SampleRow extends StatelessWidget {
  const _SampleRow({required this.item});
  final BatchItem item;

  @override
  Widget build(BuildContext context) {
    final t = item.tag;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        if (t.memory != null) SizedBox(width: 78, child: Text(t.memory!, overflow: TextOverflow.ellipsis, style: Ind.number(14))),
        Expanded(child: Text(t.name, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 8),
        Text(t.addressLabel, style: TextStyle(color: Ind.textMuted, fontSize: 12.5)),
        // Já cadastrada: marca discreta, a escolha pular/substituir fica embaixo.
        if (item.conflict) ...[
          const SizedBox(width: 6),
          Tooltip(message: 'Já existe', child: Icon(Icons.repeat_rounded, size: 15, color: Ind.textFor(Ind.warn))),
        ],
      ]),
    );
  }
}
