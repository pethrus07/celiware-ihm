import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/comm/comm_error.dart';
import '../../core/modbus/modbus_memory.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../core/utils/validators.dart';
import '../../models/alarm.dart';
import '../../models/narration.dart';
import '../../models/tag.dart';
import '../../services/runtime/hmi_runtime.dart';
import '../../services/runtime/tag_codec.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/element_catalog.dart';
import '../devices/device_form_page.dart';
import 'alarm_editor.dart';
import 'narration_editor.dart';

/// Onde o dado mora, em palavras de quem opera — cada opção vira uma
/// combinação área Modbus + tipo.
enum _Where { coil, discrete, bitInRegister, holding, input }

/// Cadastro/edição de variável.
///
/// Três recursos para errar menos:
///   1. **Lendo agora**: enquanto o formulário está aberto, o app lê o
///      endereço digitado a cada segundo e mostra o valor (ou "endereço
///      inexistente"). Se aparecer o número que a máquina mostra, está certo;
///   2. **Tradutor de notação de manual**: "40101" vira a sugestão "use 100"
///      (manuais contam a partir de 1 e com o prefixo da área);
///   3. **Escolhas em palavras**: "Liga/desliga", "Lê e grava", "Só leitura"
///      no lugar de BOOL/holding/input register — com o nome técnico ao lado
///      para quem conhece.
///
/// Aberto pelo editor (folha de configuração), vem com [fit] — só os tipos
/// que servem ao elemento — e devolve a variável criada para já ligar nele.
class TagFormPage extends StatefulWidget {
  const TagFormPage({super.key, this.tag, this.fit, this.preferWritable = false, this.preferDeviceId});

  final Tag? tag;
  final TagFit? fit;
  final bool preferWritable;

  /// Equipamento já marcado numa variável nova (o da tela que está sendo
  /// montada). Sem ele, vale o último cadastrado.
  final String? preferDeviceId;

  @override
  State<TagFormPage> createState() => _TagFormPageState();
}

class _TagFormPageState extends State<TagFormPage> {
  final _form = GlobalKey<FormState>();
  final _moreKey = GlobalKey();
  late final String _id = widget.tag?.id ?? newId('t');

  String? _deviceId;
  late TagDataType _type;
  late _Where _where;
  late ByteOrder _order;
  late bool _writable;

  /// Alarmes da variável — gravados junto com ela em Salvar.
  late List<AlarmRule> _alarms = widget.tag?.alarms ?? const [];
  late List<EventNarration> _narrations = widget.tag?.narrations ?? const [];

  late final _name = TextEditingController(text: widget.tag?.name ?? '');
  late final _address = TextEditingController(text: '${widget.tag?.address ?? 0}');
  late final _bit = TextEditingController(text: '${widget.tag?.bitIndex ?? 0}');
  late final _length = TextEditingController(text: '${widget.tag?.length ?? (widget.fit == TagFit.numberList ? 8 : 1)}');
  late final _unit = TextEditingController(text: widget.tag?.unit ?? '');
  late final _decimals = TextEditingController(text: '${widget.tag?.decimals ?? 0}');
  late final _description = TextEditingController(text: widget.tag?.description ?? '');
  late final _scale = TextEditingController(text: _numText(widget.tag?.scale ?? 1));
  late final _offset = TextEditingController(text: _numText(widget.tag?.offset ?? 0));

  /// Atalhos de escala: o caso comum é "o manual manda dividir por 10/100".
  static const _scalePresets = [(1.0, 'Sem escala'), (0.1, '÷ 10'), (0.01, '÷ 100'), (0.001, '÷ 1000'), (10.0, '× 10')];

  /// Escala fora dos atalhos (ou com deslocamento): mostra os dois campos.
  late bool _customScale = (widget.tag?.offset ?? 0) != 0 || !_scalePresets.any((p) => p.$1 == (widget.tag?.scale ?? 1));

  static String _numText(double v) => (v == v.roundToDouble() ? v.round().toString() : v.toString()).replaceAll('.', ',');
  static double? _parseNum(String t) => double.tryParse(t.trim().replaceAll(',', '.'));
  double get _scaleValue => _parseNum(_scale.text) ?? 1;
  double get _offsetValue => _parseNum(_offset.text) ?? 0;

  HmiRuntime? _runtime;
  Timer? _liveTimer;
  Object? _liveValue;
  String? _liveError;
  bool _liveBusy = false;

  bool get _editing => widget.tag != null;

  @override
  void initState() {
    super.initState();
    final t = widget.tag;
    final fit = widget.fit;
    _type = t?.dataType ??
        switch (fit) {
          TagFit.boolean => TagDataType.bool,
          TagFit.number || TagFit.numberList => TagDataType.uint16,
          _ => TagDataType.uint16,
        };
    _where = t == null
        ? (_type == TagDataType.bool ? _Where.coil : _Where.holding)
        : switch (t.area) {
            ModbusArea.coil => _Where.coil,
            ModbusArea.discreteInput => _Where.discrete,
            ModbusArea.inputRegister => _Where.input,
            ModbusArea.holdingRegister => t.dataType == TagDataType.bool ? _Where.bitInRegister : _Where.holding,
          };
    _order = t?.byteOrder ?? ByteOrder.abcd;
    _writable = t?.writable ?? widget.preferWritable;
    _liveTimer = Timer.periodic(const Duration(seconds: 1), (_) => _readLive());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runtime = AppScope.of(context).runtime;
    final project = AppScope.of(context).controller.project;
    // Variável nova: o equipamento da tela em montagem ou, fora do editor, o
    // último cadastrado — quem acabou de cadastrar a Prensa quer criar as
    // variáveis dela, não as da demonstração que vem primeiro na lista.
    final preferred = widget.preferDeviceId;
    _deviceId ??= widget.tag?.deviceId ??
        (preferred != null && project.device(preferred) != null ? preferred : project.devices.lastOrNull?.id);
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _runtime?.releaseIdle();
    for (final c in [_name, _address, _bit, _length, _unit, _decimals, _description, _scale, _offset]) {
      c.dispose();
    }
    super.dispose();
  }

  ModbusArea get _area => switch (_where) {
        _Where.coil => ModbusArea.coil,
        _Where.discrete => ModbusArea.discreteInput,
        _Where.input => ModbusArea.inputRegister,
        _Where.bitInRegister || _Where.holding => ModbusArea.holdingRegister,
      };

  /// Variável como está no formulário agora (nula se faltar o essencial).
  Tag? _current() {
    final dev = _deviceId;
    final address = int.tryParse(_address.text.trim());
    if (dev == null || address == null || address < 0 || address > 65535) return null;
    return Tag(
      id: _id,
      name: _name.text.trim().isEmpty ? 'Variável' : _name.text.trim(),
      deviceId: dev,
      area: _area,
      address: address,
      dataType: _type,
      byteOrder: _order,
      bitIndex: (int.tryParse(_bit.text) ?? 0).clamp(0, 15),
      length: _type == TagDataType.bool ? 1 : (int.tryParse(_length.text) ?? 1).clamp(1, 120),
      writable: _writable,
      unit: _unit.text.trim(),
      decimals: (int.tryParse(_decimals.text) ?? 0).clamp(0, 6),
      scale: _scaleValue,
      offset: _offsetValue,
      description: _description.text.trim(),
      alarms: _alarms,
      narrations: _narrations,
    ).normalized();
  }

  Future<void> _readLive() async {
    if (_liveBusy || !mounted) return;
    final t = _current();
    if (t == null) return;
    _liveBusy = true;
    try {
      final v = await _runtime!.readNow(t);
      if (mounted) {
        setState(() {
          _liveValue = v;
          _liveError = null;
        });
      }
    } on CommError catch (e) {
      if (mounted) setState(() => _liveError = e.userMessage);
    } on TagValueError catch (e) {
      if (mounted) setState(() => _liveError = e.message);
    } catch (e) {
      if (mounted) setState(() => _liveError = '$e');
    } finally {
      _liveBusy = false;
    }
  }

  /// Os três formatos que cobrem quase todo caso — os únicos à vista.
  static bool _isMainType(TagDataType t) =>
      t == TagDataType.bool || t == TagDataType.uint16 || t == TagDataType.float32;

  void _setType(TagDataType t) {
    // Texto de 1 registrador (2 letras) quase nunca é o que se quer.
    if (t == TagDataType.string && (int.tryParse(_length.text) ?? 1) <= 1) _length.text = '10';
    if (t == TagDataType.string) _writable = false;
    _type = t;
    if (t == TagDataType.bool && (_where == _Where.holding || _where == _Where.input)) _where = _Where.coil;
    if (t != TagDataType.bool && (_where == _Where.coil || _where == _Where.discrete || _where == _Where.bitInRegister)) _where = _Where.holding;
    _onFieldChanged();
  }

  /// Resumo do que está em "Mais opções", para ninguém precisar abrir só
  /// para conferir.
  String _moreSummary() {
    if (_type == TagDataType.bool) return 'Observação';
    if (_type == TagDataType.string) return _order == ByteOrder.abcd ? 'Texto · STRING' : 'Texto · bytes trocados';
    final parts = <String>[
      if (_scaleLabel() != null) _scaleLabel()!,
      if (_unit.text.trim().isNotEmpty) _unit.text.trim(),
      if ((int.tryParse(_decimals.text) ?? 0) > 0) _decimals.text == '1' ? '1 casa decimal' : '${_decimals.text} casas decimais',
      if (!_isMainType(_type)) _type.technical,
      if (_order != ByteOrder.abcd) _order.label,
      if ((int.tryParse(_length.text) ?? 1) > 1) 'lista de ${_length.text}',
    ];
    return parts.isEmpty ? 'Escala, unidade, decimais, formato' : parts.join(' · ');
  }

  /// "÷ 10", "× 0,5 + 3"... ou nulo sem escala.
  String? _scaleLabel() {
    final s = _scaleValue, o = _offsetValue;
    if (s == 1 && o == 0) return null;
    final preset = _scalePresets.where((p) => p.$1 == s && o == 0).firstOrNull;
    if (preset != null) return preset.$2;
    return '× ${_numText(s)}${o == 0 ? '' : ' ${o < 0 ? '−' : '+'} ${_numText(o.abs())}'}';
  }

  /// Escolheu um atalho: fator certo, deslocamento zero e, se ninguém tinha
  /// pedido casas decimais, as que a divisão cria (÷ 100 → 2 casas).
  void _pickScale(double f) {
    _scale.text = _numText(f);
    _offset.text = '0';
    final implied = f >= 1 ? 0 : (-math.log(f) / math.ln10).round();
    if ((int.tryParse(_decimals.text) ?? 0) < implied) _decimals.text = '$implied';
    _onFieldChanged();
  }

  void _onFieldChanged() => setState(() {
        _liveValue = null;
        _liveError = null;
      });

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final address = int.tryParse(_address.text.trim()) ?? -1;
    if (address > 65535) {
      final s = _manualNotation();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(s != null
            ? 'Endereço acima de 65535. Pela notação de manual, o certo é $s — toque na sugestão azul.'
            : 'O endereço Modbus vai de 0 a 65535.'),
      ));
      return;
    }
    final t = _current();
    if (t == null) return;
    AppScope.of(context).controller.saveTag(t);
    Navigator.pop(context, t);
  }

  Future<void> _delete() async {
    final c = AppScope.of(context).controller;
    final uses = c.project.screensUsingTag(_id);
    if (!await confirmDelete(context,
        title: 'Apagar "${widget.tag!.name}"?',
        body: uses.isEmpty
            ? 'A variável sai do projeto.'
            : 'Ela é usada em: ${uses.map((s) => s.name).join(', ')}. Esses elementos vão ficar pedindo "Escolha a variável".')) {
      return;
    }
    c.deleteTag(_id);
    if (mounted) Navigator.pop(context);
  }

  /// "40101" → 100 (holding), "30001" → 0 (input)... Devolve a sugestão, ou nulo.
  int? _manualNotation() {
    final v = int.tryParse(_address.text.trim());
    if (v == null) return null;
    final prefix = switch (_area) {
      ModbusArea.holdingRegister => 4,
      ModbusArea.inputRegister => 3,
      ModbusArea.discreteInput => 1,
      ModbusArea.coil => 0,
    };
    if (prefix == 0) return null; // "00001" não dá para distinguir de 1
    if (v >= prefix * 10000 + 1 && v <= prefix * 10000 + 9999) return v - prefix * 10000 - 1;
    if (v >= prefix * 100000 + 1 && v <= prefix * 100000 + 65536) return v - prefix * 100000 - 1;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final project = AppScope.watch(context).controller.project;
    final fit = widget.fit;
    final allowArray = fit == null || fit == TagFit.numberList;
    final typeOptions = TagDataType.values.where((t) {
      if (fit == TagFit.boolean) return t == TagDataType.bool;
      if (fit == TagFit.number || fit == TagFit.numberList) return t.isNumeric;
      if (fit == TagFit.scalar) return t != TagDataType.string;
      return true;
    }).toList();
    final isText = _type == TagDataType.string;
    final suggestion = _manualNotation();

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Variável' : 'Nova variável'),
        actions: [
          if (_editing) IconButton(tooltip: 'Apagar', icon: Icon(Icons.delete_outline_rounded, color: Ind.alarm), onPressed: _delete),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            key: const ValueKey('salvar-variavel'),
            onPressed: project.devices.isEmpty ? null : _save,
            icon: const Icon(Icons.check_rounded),
            label: const Text('Salvar'),
          ),
        ),
      ),
      body: project.devices.isEmpty
          ? EmptyState(
              icon: Icons.router_outlined,
              title: 'Falta o equipamento',
              body: 'A variável mora num equipamento. Cadastre ele primeiro.',
              action: FilledButton.icon(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DeviceFormPage())),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Cadastrar equipamento'),
              ),
            )
          : Form(
              key: _form,
              // Só o essencial à vista (equipamento, nome, tipo, onde, endereço,
              // permissão). Apresentação, lista, formatos raros e ordem de
              // bytes ficam em "Mais opções" — a maioria nunca precisa abrir.
              // "Lendo agora" preso no topo: é a resposta a cada campo mexido
              // (endereço, formato, escala) — rolando junto, sumia justo quando
              // se ajustava a escala lá embaixo.
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Ind.page, 12, Ind.page, 8),
                  child: _LivePanel(value: _liveValue, error: _liveError, tag: _current()),
                ),
                Expanded(
                child: ListView(
                padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
                children: [
                  // Um equipamento só (o caso comum): nem pergunta.
                  if (project.devices.length > 1) ...[
                    const SectionHeader('Equipamento', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)),
                    ChoiceCards<String>(
                      options: [
                        for (final d in project.devices)
                          ChoiceOption(value: d.id, title: d.name, icon: d.isDemo ? Icons.smart_toy_outlined : Icons.router_outlined),
                      ],
                      selected: _deviceId ?? '',
                      onChanged: (id) {
                        _deviceId = id;
                        _onFieldChanged();
                      },
                    ),
                  ],
                  const SizedBox(height: Ind.spaceLarge),
                  TextFormField(
                    key: const ValueKey('campo-nome-variavel'),
                    controller: _name,
                    validator: Validators.name,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(labelText: 'Nome', hintText: 'Ex.: Velocidade da faca'),
                  ),
                  const SectionHeader('O que é', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)),
                  ChoiceCards<TagDataType>(
                    options: [
                      for (final t in typeOptions.where(_isMainType))
                        ChoiceOption(value: t, title: t.label),
                    ],
                    // Formato raro escolhido em "Mais opções": nenhum cartão
                    // principal fica marcado (o chip de lá mostra qual é).
                    selected: _type,
                    columns: 3,
                    onChanged: _setType,
                  ),
                  const SectionHeader('Onde fica', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)),
                  ChoiceCards<_Where>(
                    options: _type == TagDataType.bool
                        ? const [
                            ChoiceOption(value: _Where.coil, title: 'Bit', subtitle: 'Lê e grava'),
                            ChoiceOption(value: _Where.discrete, title: 'Entrada', subtitle: 'Só leitura'),
                            ChoiceOption(value: _Where.bitInRegister, title: 'Bit de palavra', subtitle: 'Dentro de um registrador'),
                          ]
                        : const [
                            ChoiceOption(value: _Where.holding, title: 'Registrador', subtitle: 'Lê e grava'),
                            ChoiceOption(value: _Where.input, title: 'Registrador de entrada', subtitle: 'Só leitura'),
                          ],
                    selected: _where,
                    columns: _type == TagDataType.bool ? 3 : 2,
                    onChanged: (w) {
                      _where = w;
                      if (!_area.isWritable) _writable = false;
                      _onFieldChanged();
                    },
                  ),
                  const SizedBox(height: Ind.spaceLarge),
                  StepperField(
                    fieldKey: const ValueKey('campo-endereco'),
                    label: 'Endereço',
                    controller: _address,
                    min: 0,
                    max: 499999,
                    onChanged: _onFieldChanged,
                  ),
                  if (suggestion != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Material(
                        color: Ind.info.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(Ind.radiusSmall),
                        child: InkWell(
                          key: const ValueKey('sugestao-endereco'),
                          borderRadius: BorderRadius.circular(Ind.radiusSmall),
                          onTap: () {
                            _address.text = '$suggestion';
                            _onFieldChanged();
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(children: [
                              Icon(Icons.auto_fix_high_rounded, color: Ind.info),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text('Parece a notação de manual (${_address.text}). No Modbus isso é o endereço $suggestion. Toque para usar.',
                                    style: const TextStyle(height: 1.35)),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  if (_where == _Where.bitInRegister) ...[
                    const SizedBox(height: Ind.space),
                    StepperField(label: 'Qual bit (0 a 15)', controller: _bit, min: 0, max: 15, onChanged: _onFieldChanged),
                  ],
                  // Lista é obrigatória para o gráfico de barras: aí fica à vista.
                  if (_type != TagDataType.bool && fit == TagFit.numberList) ...[
                    const SizedBox(height: Ind.space),
                    StepperField(label: 'Quantos valores seguidos', controller: _length, min: 1, max: 120, onChanged: _onFieldChanged),
                  ],
                  // Texto: o tamanho é o essencial (quantos registradores ler).
                  if (isText) ...[
                    const SizedBox(height: Ind.space),
                    StepperField(
                      fieldKey: const ValueKey('campo-tamanho-texto'),
                      label: 'Tamanho em registradores',
                      controller: _length,
                      min: 1,
                      max: 120,
                      helper: '2 letras por registrador: ${_length.text} = até ${(int.tryParse(_length.text) ?? 1) * 2} letras.',
                      onChanged: _onFieldChanged,
                    ),
                  ],
                  const SizedBox(height: Ind.spaceSmall),
                  SwitchListTile(
                    key: const ValueKey('pode-gravar'),
                    contentPadding: EdgeInsets.zero,
                    value: _writable && _area.isWritable && !isText,
                    onChanged: _area.isWritable && !isText ? (v) => setState(() => _writable = v) : null,
                    title: const Text('Pode ser alterada pela tela'),
                    subtitle: isText
                        ? const Text('Texto é só leitura nesta versão.')
                        : _area.isWritable
                            ? null
                            : const Text('Esta memória é só de leitura.'),
                  ),
                  // Alarme: uma linha só, à vista (é segurança, não detalhe); o
                  // editor abre numa folha. Texto e lista não alarmam.
                  if (!isText && (int.tryParse(_length.text) ?? 1) <= 1 && _current() != null) ...[
                    const SizedBox(height: Ind.spaceSmall),
                    AlarmsRow(tag: _current()!, alarms: _alarms, onChanged: (a) => setState(() => _alarms = a)),
                    const SizedBox(height: Ind.spaceSmall),
                    NarrationsRow(tag: _current()!, narrations: _narrations, onChanged: (n) => setState(() => _narrations = n)),
                  ],
                  const SizedBox(height: Ind.spaceSmall),
                  Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      key: _moreKey,
                      tilePadding: EdgeInsets.zero,
                      onExpansionChanged: (open) => revealAfterExpand(_moreKey, open),
                      childrenPadding: const EdgeInsets.only(bottom: 8),
                      // Formato raro escolhido: abre sozinho, para não esconder a escolha.
                      initiallyExpanded: !_isMainType(_type) || _order != ByteOrder.abcd,
                      title: const Text('Mais opções'),
                      subtitle: Text(_moreSummary(), style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_type.isNumeric) ...[
                          // Escala primeiro: é o que mais se usa aqui ("o
                          // manual diz para dividir por 10").
                          const SectionHeader('Escala do equipamento', padding: EdgeInsets.fromLTRB(0, 8, 0, 6)),
                          Text('O equipamento manda sem vírgula? Ex.: vem 752 e é 75,2 °C → ÷ 10.',
                              style: TextStyle(color: Ind.textDim, height: 1.35)),
                          const SizedBox(height: 10),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final (f, label) in _scalePresets)
                              ChoiceChip(
                                key: ValueKey('escala-$label'),
                                label: Text(label),
                                selected: !_customScale && _scaleValue == f && _offsetValue == 0,
                                onSelected: (_) {
                                  _customScale = false;
                                  _pickScale(f);
                                },
                              ),
                            ChoiceChip(
                              key: const ValueKey('escala-outra'),
                              label: const Text('Outra'),
                              selected: _customScale,
                              onSelected: (_) => setState(() => _customScale = true),
                            ),
                          ]),
                          if (_customScale) ...[
                            const SizedBox(height: 12),
                            Row(children: [
                              Expanded(
                                child: TextFormField(
                                  key: const ValueKey('campo-fator'),
                                  controller: _scale,
                                  keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                                  decoration: const InputDecoration(labelText: 'Multiplica por'),
                                  validator: (t) => (_parseNum(t ?? '') ?? 0) == 0 ? 'Não pode ser zero' : null,
                                  onChanged: (_) => _onFieldChanged(),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextFormField(
                                  key: const ValueKey('campo-deslocamento'),
                                  controller: _offset,
                                  keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                                  decoration: const InputDecoration(labelText: 'Depois soma'),
                                  onChanged: (_) => _onFieldChanged(),
                                ),
                              ),
                            ]),
                            const SizedBox(height: 6),
                            Text('Valor na tela = valor do equipamento × fator + soma. Ao gravar, o app faz a conta ao contrário.',
                                style: TextStyle(color: Ind.textMuted, fontSize: 12.5, height: 1.35)),
                          ],
                          const SizedBox(height: Ind.space),
                        ],
                        if (_type != TagDataType.bool) ...[
                          if (!isText) Row(children: [
                            Expanded(
                              child: TextFormField(
                                controller: _unit,
                                decoration: const InputDecoration(labelText: 'Unidade', hintText: '°C, m/min'),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            const SizedBox(width: 12),
                            SizedBox(
                              width: 120,
                              child: TextFormField(
                                controller: _decimals,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(labelText: 'Decimais'),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                          ]),
                          if (allowArray && fit != TagFit.numberList && !isText) ...[
                            const SizedBox(height: Ind.space),
                            StepperField(label: 'Quantos valores seguidos', controller: _length, min: 1, max: 120, helper: 'Mais que 1 forma uma lista (gráfico de barras).', onChanged: _onFieldChanged),
                          ],
                          const SectionHeader('Outros formatos', padding: EdgeInsets.fromLTRB(0, 24, 0, 10)),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final t in typeOptions.where((t) => !_isMainType(t)))
                              ChoiceChip(label: Text('${t.label} · ${t.technical}'), selected: _type == t, onSelected: (_) => _setType(t)),
                          ]),
                          const SectionHeader('Ordem dos bytes', padding: EdgeInsets.fromLTRB(0, 24, 0, 10)),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final o in ByteOrder.values)
                              if (_type.is32Bit || o == ByteOrder.abcd || o == ByteOrder.badc)
                                ChoiceChip(
                                  label: Text(o == ByteOrder.abcd ? 'Padrão' : '${o.label} · ${o.hint}'),
                                  selected: _order == o,
                                  onSelected: (_) {
                                    _order = o;
                                    _onFieldChanged();
                                  },
                                ),
                          ]),
                          const SizedBox(height: Ind.space),
                        ],
                        TextFormField(
                          controller: _description,
                          maxLines: 2,
                          decoration: const InputDecoration(labelText: 'Observação', hintText: 'Ex.: 0 parada · 1 em ciclo'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
                ),
              ]),
            ),
    );
  }
}

/// Painel "Lendo agora do equipamento".
class _LivePanel extends StatelessWidget {
  const _LivePanel({required this.value, required this.error, required this.tag});
  final Object? value;
  final String? error;
  final Tag? tag;

  @override
  Widget build(BuildContext context) {
    final err = error;
    final color = err != null ? Ind.alarm : (value != null ? Ind.ok : Ind.textMuted);
    final t = tag;
    final text = err != null ? capitalized(err) : (t == null ? 'Complete equipamento e endereço' : value == null ? 'Lendo…' : _fmt(t, value));
    // Com escala, mostrar o número cru ao lado é a prova de que a conta está
    // certa: "vem 752 do equipamento" → "75,2 °C" na tela.
    final v = value;
    final raw = err == null && t != null && t.hasScale && v is num ? (v - t.offset) / t.scale : null;
    return Container(
      key: const ValueKey('lendo-agora'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Ind.bg,
        borderRadius: BorderRadius.circular(Ind.radius),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(children: [
        Icon(err != null ? Icons.error_outline_rounded : Icons.sensors_rounded, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('LENDO AGORA DO EQUIPAMENTO', style: Ind.tag(size: 10.5, color: Ind.textMuted)),
            const SizedBox(height: 4),
            Text(text, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: err != null || value == null
                    ? TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 15)
                    : Ind.number(24, color: Ind.text)),
            if (raw != null) ...[
              const SizedBox(height: 2),
              Text('vem ${_rawText(t!, raw)} do equipamento', key: const ValueKey('valor-bruto'), style: TextStyle(color: Ind.textMuted, fontSize: 12.5)),
            ],
          ]),
        ),
        if (t != null) Text(t.addressLabel, style: Ind.number(12, color: Ind.textMuted)),
      ]),
    );
  }

  static String _rawText(Tag t, double raw) => t.dataType == TagDataType.float32
      ? raw.toStringAsFixed(2).replaceAll('.', ',')
      : raw.round().toString();

  static String _fmt(Tag t, Object? v) {
    if (v is List) return v.map((x) => TagCodec.format(t, x, withUnit: false)).join(' · ');
    return TagCodec.format(t, v);
  }
}
