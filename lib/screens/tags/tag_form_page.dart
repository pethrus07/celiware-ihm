import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/comm/comm_error.dart';
import '../../core/modbus/modbus_memory.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../core/utils/validators.dart';
import '../../models/alarm.dart';
import '../../models/device.dart';
import '../../models/project.dart';
import '../../models/narration.dart';
import '../../models/tag.dart';
import '../../models/vendor_profiles.dart';
import '../../services/runtime/hmi_runtime.dart';
import '../../services/runtime/mqtt_codec.dart';
import '../../services/runtime/raw_codec.dart';
import '../../services/runtime/tag_codec.dart';
import '../../widgets/common/adaptive.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/element_catalog.dart';
import '../devices/device_form_page.dart';
import 'address_field.dart';
import 'alarm_editor.dart';
import 'device_pick.dart';
import 'mqtt_tag_fields.dart';
import 'opcua_tag_fields.dart';
import 'raw_tag_fields.dart';
import 'reading_hints.dart';
import 's7_tag_fields.dart';
import 'tag_uses.dart';
import 'narration_editor.dart';

/// Onde o dado mora, em palavras de quem opera — cada opção vira uma
/// combinação área Modbus + tipo.
enum _Where { coil, discrete, bitInRegister, bitInInput, holding, input }

/// O que fazer com alterações não salvas ao voltar.
enum _Leave { save, discard, keep }

/// Cadastro/edição de variável.
///
/// Três recursos para errar menos:
///   1. **Lendo agora**: enquanto o formulário está aberto, o app lê o
///      endereço digitado a cada segundo e mostra o valor (ou "endereço
///      inexistente"). Se aparecer o número que a máquina mostra, está certo.
///      Valor com cara de formato errado (65531 que deveria ser −5, número com
///      vírgula com as palavras trocadas) ganha a sugestão de um toque;
///   2. **Tradutor de notação de manual**: "40101" vira a sugestão "use 100"
///      (manuais contam a partir de 1 e com o prefixo da área); hexadecimal
///      ("0x2000") também é aceito;
///   3. **Escolhas em palavras**: "Liga/desliga", "Lê e grava", "Só leitura"
///      no lugar de BOOL/holding/input register — com o nome técnico ao lado
///      para quem conhece.
///
/// Nada se perde calado: voltar com alteração pendente pergunta; trocar o
/// tipo avisa na hora os alarmes que deixam de valer e os elementos de tela
/// que deixam de funcionar; erro de validação em "Mais opções" abre o painel
/// e rola até o campo.
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
  final _more = ExpansibleController();
  final _scroll = ScrollController();
  late final String _id = widget.tag?.id ?? newId('t');

  // Âncoras para levar a pessoa até o primeiro campo com erro.
  final _nameAnchor = GlobalKey();
  final _addressAnchor = GlobalKey();
  final _memoryAnchor = GlobalKey();
  final _bitAnchor = GlobalKey();
  final _lengthAnchor = GlobalKey();
  final _scaleAnchor = GlobalKey();

  String? _deviceId;
  late TagDataType _type;
  late _Where _where;
  late ByteOrder _order;

  /// O que a pessoa marcou em "Pode ser alterada pela tela". Vale de fato só
  /// onde a memória permite ([Tag.normalized]); por isso passar por "Só
  /// leitura" ou por Texto e voltar devolve a escolha como estava.
  late bool _writable;
  late int _decimals = widget.tag?.decimals ?? 0;

  /// "Aceita escrita por regra" (LG-5): sem ela, nenhuma regra grava aqui.
  late bool _ruleWritable = widget.tag?.ruleWritable ?? false;

  /// Endereço digitado em hexadecimal ("2000" = 8192). Só do formulário.
  bool _hex = false;

  /// Perfil de fabricante do equipamento escolhido (nulo = Modbus genérico).
  /// Com ele, a memória entra como no manual do CLP ("D200") e a sugestão de
  /// notação de manual (40001…) sai — lá esses números são endereços (MP-4).
  VendorProfile? _profile;

  /// A memória como no manual ("D200"), quando há perfil (MP-3).
  late final _memory = TextEditingController(text: widget.tag?.memory ?? '');

  /// A mudança veio do próprio campo da memória: não reescrever o campo.
  bool _fromMemory = false;
  bool _memoryStarted = false;

  /// Alarmes da variável — gravados junto com ela em Salvar. Os que não
  /// casam com o tipo escolhido agora ficam guardados aqui (voltando ao tipo,
  /// voltam) e saem no Salvar.
  late List<AlarmRule> _alarms = widget.tag?.alarms ?? const [];
  late List<EventNarration> _narrations = widget.tag?.narrations ?? const [];

  late final _name = TextEditingController(text: widget.tag?.name ?? '');
  // Variável de modelo de tela com o endereço a configurar: abre vazio — o 0
  // do padrão não é endereço de verdade, e Salvar exige o que falta.
  late final _address = TextEditingController(text: widget.tag?.addressPending ?? false ? '' : '${widget.tag?.address ?? 0}');
  late final _bit = TextEditingController(text: '${widget.tag?.bitIndex ?? 0}');
  late final _length = TextEditingController(text: '${widget.tag?.length ?? (widget.fit == TagFit.numberList ? 8 : 1)}');
  late final _unit = TextEditingController(text: widget.tag?.unit ?? '');
  late final _description = TextEditingController(text: widget.tag?.description ?? '');
  late final _scale = TextEditingController(text: _numText(widget.tag?.scale ?? 1));
  late final _offset = TextEditingController(text: _numText(widget.tag?.offset ?? 0));

  /// Tamanho de antes de virar Texto (Texto pede vários registradores).
  String? _lengthBeforeText;

  /// Retrato do formulário ao abrir: diferente dele = alteração pendente.
  late final String _initialSnapshot;
  late final String _initialAlarms;
  String? _initialDeviceId;

  /// Atalhos de escala: o caso comum é "o manual manda dividir por 10/100".
  static const _scalePresets = [(1.0, 'Sem escala'), (0.1, '÷ 10'), (0.01, '÷ 100'), (0.001, '÷ 1000'), (10.0, '× 10')];

  /// Atalhos de unidade: as que aparecem em quase toda máquina.
  static const _unitPresets = ['°C', '%', 'bar', 'rpm', 'm/min', 'A', 'V', 'Hz'];

  /// Escala fora dos atalhos (ou com deslocamento): mostra os dois campos.
  late bool _customScale = (widget.tag?.offset ?? 0) != 0 || !_scalePresets.any((p) => p.$1 == (widget.tag?.scale ?? 1));

  static String _numText(double v) => (v == v.roundToDouble() ? v.round().toString() : v.toString()).replaceAll('.', ',');
  static double? _parseNum(String t) => double.tryParse(t.trim().replaceAll(',', '.'));
  double get _scaleValue => _parseNum(_scale.text) ?? 1;
  double get _offsetValue => _parseNum(_offset.text) ?? 0;

  /// Tópico, campo do JSON e comando — o endereço quando o equipamento é MQTT.
  late final MqttTagFields _mq = MqttTagFields(widget.tag?.mqtt);

  /// Endereço como no TIA Portal — o endereço quando o equipamento é S7.
  late final S7TagFields _s7 = S7TagFields(widget.tag?.s7);
  /// Campo da mensagem e comando — o endereço quando o equipamento é cru.
  late final RawTagFields _rw = RawTagFields(widget.tag?.raw);

  /// NodeId — o endereço quando o equipamento é um servidor OPC UA.
  late final OpcUaTagFields _ua = OpcUaTagFields(widget.tag?.opcua);

  HmiRuntime? _runtime;
  Timer? _liveTimer;
  Object? _liveValue;
  String? _liveError;

  /// "Esperando mensagem…": no MQTT, tópico calado não é erro.
  String? _liveNote;
  bool _liveBusy = false;

  /// Ordens de bytes que já leram lixo neste endereço — a sugestão não manda
  /// tentar de novo o que já falhou.
  final Set<ByteOrder> _absurdOrders = {};
  String? _absurdKey;

  /// "Onde fica" mudou sozinho com o tipo: realce por um instante.
  bool _whereChanged = false;
  Timer? _whereTimer;

  Timer? _revealTimer;
  bool _revealingError = false;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  bool get _editing => widget.tag != null;

  Device? get _device => AppScope.of(context).controller.project.device(_deviceId ?? '');
  bool get _isMqtt => _device?.kind == DeviceKind.mqtt;
  bool get _isS7 => _device?.kind == DeviceKind.s7;
  // Arduino pela rede ou pelo cabo USB: campo da mensagem.
  bool get _isRaw => _device?.speaksRaw ?? false;
  bool get _isOpcUa => _device?.kind == DeviceKind.opcua;

  /// MQTT, cru e OPC UA não têm área, endereço, ordem de bytes nem
  /// registrador (no OPC UA o servidor diz o tipo).
  bool get _notModbus => _isMqtt || _isRaw || _isOpcUa;

  /// Pode virar "Lê e grava": no MQTT e no cru qualquer variável (publica no
  /// tópico de comando, manda o comando do modelo); no S7, menos as entradas;
  /// no Modbus, só onde a área aceita escrita. Texto é só leitura.
  bool get _canWrite => (_notModbus || (_isS7 ? _s7.canWrite : _area.isWritable)) && _type != TagDataType.string && !_memoryReadOnly;

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
            ModbusArea.inputRegister => t.dataType == TagDataType.bool ? _Where.bitInInput : _Where.input,
            ModbusArea.holdingRegister => t.dataType == TagDataType.bool ? _Where.bitInRegister : _Where.holding,
          };
    _order = t?.byteOrder ?? ByteOrder.abcd;
    _writable = t?.writable ?? widget.preferWritable;
    _initialSnapshot = _snapshot();
    _initialAlarms = _alarmsJson();
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
    // Só equipamento de verdade: o das calculadas tem cadastro próprio.
    final preferred = widget.preferDeviceId;
    final equipment = project.equipment;
    _deviceId ??= widget.tag?.deviceId ??
        (preferred != null && equipment.any((d) => d.id == preferred) ? preferred : equipment.lastOrNull?.id);
    _initialDeviceId ??= _deviceId;
    _profile = VendorProfiles.of(project.device(_deviceId ?? ''));
    // Variável de antes do perfil: o campo já abre com o nome do endereço dela.
    if (!_memoryStarted) {
      _memoryStarted = true;
      if (widget.tag != null && widget.tag!.memory == null) _syncMemory();
    }
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _whereTimer?.cancel();
    _revealTimer?.cancel();
    _runtime?.releaseIdle();
    _more.dispose();
    _scroll.dispose();
    for (final c in [_name, _address, _bit, _length, _unit, _description, _scale, _offset, _memory]) {
      c.dispose();
    }
    _mq.dispose();
    _s7.dispose();
    _rw.dispose();
    _ua.dispose();
    super.dispose();
  }

  ModbusArea get _area => switch (_where) {
        _Where.coil => ModbusArea.coil,
        _Where.discrete => ModbusArea.discreteInput,
        _Where.input || _Where.bitInInput => ModbusArea.inputRegister,
        _Where.bitInRegister || _Where.holding => ModbusArea.holdingRegister,
      };

  bool get _isBitOfWord => _where == _Where.bitInRegister || _where == _Where.bitInInput;

  AddressReading get _addressReading => AddressInput.read(_address.text, area: _area, hex: _hex, manual: _profile == null);

  // ── Memória do CLP (perfil de fabricante) ─────────────────────────────────

  /// A memória digitada, lida no perfil (nula sem perfil, vazia ou inválida).
  MemoryRef? get _memoryRef {
    final p = _profile;
    final text = _memory.text.trim();
    if (p == null || text.isEmpty) return null;
    try {
      return VendorProfiles.parseMemory(text, profile: p, bit: _type == TagDataType.bool);
    } on MemoryError {
      return null;
    }
  }

  /// Bit dentro do registrador, quando a variável é um.
  int? get _wordBit => _isBitOfWord ? (int.tryParse(_bit.text) ?? 0).clamp(0, 15) : null;

  /// A memória digitada aponta para o endereço que está no formulário.
  bool _memoryMatches(MemoryRef ref) => ref.area == _area && ref.address == _addressReading.address && ref.bit == _wordBit;

  /// O que vai em [Tag.memory]: o texto digitado, se ainda aponta para o
  /// endereço do formulário; senão, o nome que o perfil dá a esse endereço.
  /// Quem mexeu no endereço Modbus à mão não fica com um "D200" falso — e
  /// editar outro campo de uma variável feita em Criar várias não apaga o dela.
  String? _memoryForDraft() {
    final p = _profile;
    final address = _addressReading.address;
    if (p == null || address == null) return null;
    final ref = _memoryRef;
    if (ref != null && !ref.raw && _memoryMatches(ref)) return ref.text;
    return p.format(_area, address, bit: _wordBit);
  }

  /// Entrada física exposta como coil (o X da Inovance e do WEG): o perfil
  /// diz que é só leitura, mesmo a área aceitando escrita.
  bool get _memoryReadOnly {
    final ref = _memoryRef;
    return ref != null && _memoryMatches(ref) && ref.readOnly;
  }

  /// Mexeram no endereço Modbus, em "Onde fica", no bit ou no equipamento: o
  /// campo da memória passa a mostrar o nome que o perfil dá ao endereço — ou
  /// fica vazio, se o perfil não tem nome para ele.
  void _syncMemory() {
    final p = _profile;
    final address = _addressReading.address;
    if (p == null || address == null) return;
    final ref = _memoryRef;
    if (ref != null && _memoryMatches(ref)) return;
    _memory.text = p.format(_area, address, bit: _wordBit) ?? '';
  }

  /// A pessoa digitou a memória como no manual ("D200", "X10", "D100.3"):
  /// onde fica, endereço, bit e tipo seguem. Enquanto o texto não é memória
  /// válida, o resto fica como estava.
  void _onMemoryChanged(String _) {
    final ref = _memoryRef;
    _fromMemory = true;
    try {
      if (ref != null) {
        // Bit (M, X, "D100.3") é liga/desliga; contador de 32 bits é INT32;
        // registrador sem bit deixa de ser liga/desliga.
        final type = ref.forcedType ?? (_type == TagDataType.bool ? TagDataType.uint16 : _type);
        if (type != _type) _setType(type);
        _where = switch (ref.area) {
          ModbusArea.coil => _Where.coil,
          ModbusArea.discreteInput => _Where.discrete,
          ModbusArea.holdingRegister => ref.bit != null ? _Where.bitInRegister : _Where.holding,
          ModbusArea.inputRegister => ref.bit != null ? _Where.bitInInput : _Where.input,
        };
        if (ref.bit != null) _bit.text = '${ref.bit}';
        _hex = false;
        _address.text = '${ref.address}';
        if (ref.readOnly) _writable = false;
      }
      _onFieldChanged();
    } finally {
      _fromMemory = false;
    }
  }

  /// O que está errado na memória, nas palavras do manual ("X8 não existe —
  /// X conta em octal"). Confere também o valor de 32 bits num registrador de
  /// 16, que ocupa a memória seguinte.
  String? _memoryError() {
    final p = _profile;
    final text = _memory.text.trim();
    if (p == null || text.isEmpty) return null;
    final MemoryRef ref;
    try {
      ref = VendorProfiles.parseMemory(text, profile: p, bit: _type == TagDataType.bool);
    } on MemoryError catch (e) {
      return e.message;
    }
    final rule = ref.rule, n = ref.number;
    if (_type.is32Bit && rule != null && n != null && rule.wordsPerItem == 1) {
      final next = rule.addressOf(n + 1);
      if (next != ref.address + 1) {
        return '${ref.text} com 32 bits ocuparia ${rule.text(n + 1)}, que ${next == null ? 'não existe neste CLP' : 'não fica logo depois no Modbus'}.';
      }
    }
    return null;
  }

  /// "Memória do CLP" (ou "Parâmetro do inversor"): o texto do manual e,
  /// embaixo, a prova da tradução ("D200 → Holding 200") ou o que está errado.
  Widget _memoryField() {
    final p = _profile!;
    final error = _memoryError();
    return TextFormField(
      key: const ValueKey('campo-memoria'),
      controller: _memory,
      autocorrect: false,
      enableSuggestions: false,
      // Letras e números à vista, sem corretor.
      keyboardType: TextInputType.visiblePassword,
      textCapitalization: TextCapitalization.characters,
      style: Ind.number(20),
      decoration: InputDecoration(
        labelText: p.kind == ProfileKind.drive ? 'Parâmetro do inversor' : 'Memória do CLP',
        hintText: 'Ex.: ${p.example}',
        helperText: error == null ? _memoryRef?.proof : null,
        errorText: error,
        errorMaxLines: 3,
      ),
      onChanged: _onMemoryChanged,
      validator: (_) => _memoryError(),
    );
  }

  /// Onde o campo "quantos valores" aparece: à vista (Texto, ou lista pedida
  /// pelo gráfico de barras) ou em "Mais opções" (lista opcional).
  bool get _lengthInMain => _type != TagDataType.bool && !_isRaw && (widget.fit == TagFit.numberList || _type == TagDataType.string);
  bool get _lengthInMore => _type != TagDataType.bool && !_isRaw && widget.fit == null && _type != TagDataType.string;

  /// Variável como está no formulário, mesmo incompleta (endereço inválido
  /// vira 0) — serve para avisos e prévias.
  Tag _draft() {
    // MQTT: o endereço é o tópico; S7, o do TIA; cru, o campo da mensagem.
    // Nos três, área e endereço Modbus ficam no padrão.
    final mqtt = _isMqtt ? _mq.build() : null;
    final s7 = _isS7 ? _s7.build() : null;
    final raw = _isRaw ? _rw.build() : null;
    final opcua = _isOpcUa ? _ua.build() : null;
    final other = mqtt != null || s7 != null || raw != null || opcua != null;
    return Tag(
      id: _id,
      name: _name.text.trim().isEmpty ? 'Variável' : _name.text.trim(),
      deviceId: _deviceId ?? '',
      mqtt: mqtt,
      s7: s7,
      raw: raw,
      opcua: opcua,
      area: other ? ModbusArea.holdingRegister : _area,
      address: other ? 0 : _addressReading.address ?? 0,
      dataType: _type,
      byteOrder: other ? ByteOrder.abcd : _order,
      bitIndex: other ? 0 : (int.tryParse(_bit.text) ?? 0).clamp(0, 15),
      // Texto S7: o tamanho vem da faixa (P#… BYTE 22), não de registradores;
      // no OPC UA o texto vem inteiro do servidor; o cru não tem lista.
      length: _type == TagDataType.bool || ((s7 != null || opcua != null) && _type == TagDataType.string) || raw != null ? 1 : (int.tryParse(_length.text) ?? 1).clamp(1, 120),
      writable: _writable && !_memoryReadOnly,
      ruleWritable: _ruleWritable,
      unit: _unit.text.trim(),
      decimals: _decimals,
      scale: _scaleValue,
      offset: _offsetValue,
      description: _description.text.trim(),
      alarms: _alarms,
      narrations: _narrations,
      memory: other ? null : _memoryForDraft(),
    ).normalized();
  }

  /// Variável como está no formulário agora (nula se faltar o essencial:
  /// equipamento e endereço — ou tópico, no MQTT).
  Tag? _current() {
    if (_deviceId == null) return null;
    if (_isMqtt) return _mq.build() == null ? null : _draft();
    if (_isS7) return _s7Error() == null ? _draft() : null;
    if (_isRaw) return _rw.build() == null ? null : _draft();
    if (_isOpcUa) return _ua.error() == null ? _draft() : null;
    return _addressReading.address == null ? null : _draft();
  }

  /// O que a leitura depende: mudou durante a ida ao equipamento, o valor
  /// que voltou é de outra configuração e não vale.
  static String _readKey(Tag t) =>
      '${t.deviceId}|${t.area.name}|${t.address}|${t.dataType.name}|${t.byteOrder.name}|${t.bitIndex}|${t.length}|${t.scale}|${t.offset}|${t.mqtt == null ? '' : jsonEncode(t.mqtt!.toJson())}|${t.s7?.address ?? ''}|${t.raw == null ? '' : jsonEncode(t.raw!.toJson())}|${t.opcua?.nodeId ?? ''}';

  /// O mesmo, sem a ordem dos bytes: as ordens que falharam valem para ele.
  static String _decodeKey(Tag t) => '${t.deviceId}|${t.area.name}|${t.address}|${t.dataType.name}|${t.length}';

  Future<void> _readLive() async {
    if (_liveBusy || !mounted) return;
    final t = _current();
    if (t == null) return;
    _liveBusy = true;
    try {
      final v = await _runtime!.readNow(t);
      final now = mounted ? _current() : null;
      if (now == null || _readKey(now) != _readKey(t)) return;
      if (ReadingHints.looksAbsurd(t, v)) {
        if (_absurdKey != _decodeKey(t)) {
          _absurdOrders.clear();
          _absurdKey = _decodeKey(t);
        }
        _absurdOrders.add(t.byteOrder);
      }
      setState(() {
        _liveValue = v;
        _liveError = null;
        _liveNote = null;
      });
    } on MqttNoMessageYet catch (e) {
      if (mounted) {
        setState(() {
          _liveValue = null;
          _liveError = null;
          _liveNote = e.message;
        });
      }
    } on RawNoMessageYet catch (e) {
      if (mounted) {
        setState(() {
          _liveValue = null;
          _liveError = null;
          _liveNote = e.message;
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

  // ── Alteração pendente ────────────────────────────────────────────────────

  String _alarmsJson() => jsonEncode([for (final a in _alarms) a.toJson()]);

  /// Tudo que vai para a variável, como está nos campos. O endereço entra
  /// pelo número (ligar o hexadecimal muda o texto, não o endereço).
  String _snapshot() => jsonEncode([
        _name.text.trim(),
        _addressReading.address ?? _address.text.trim(),
        _bit.text.trim(),
        _length.text.trim(),
        _unit.text.trim(),
        _decimals,
        _description.text.trim(),
        _scaleValue,
        _offsetValue,
        _type.name,
        _where.name,
        _order.name,
        _writable,
        _ruleWritable,
        _alarmsJson(),
        _mq.build()?.toJson() ?? _mq.topic.text.trim(),
        _s7.address.text.trim(),
        _rw.build()?.toJson() ?? '',
        _ua.nodeId.text.trim(),
      ]);

  bool get _dirty => (_initialDeviceId != null && _deviceId != _initialDeviceId) || _snapshot() != _initialSnapshot;

  /// Voltar (seta ou gesto do sistema): sem alteração, sai direto; com
  /// alteração — inclusive alarmes recém-configurados, que só gravam no
  /// Salvar —, pergunta antes de jogar fora.
  Future<void> _leave() async {
    if (!_dirty) {
      Navigator.pop(context);
      return;
    }
    final alarmsChanged = _alarmsJson() != _initialAlarms;
    final choice = await showDialog<_Leave>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('descartar-alteracoes'),
        title: const Text('Descartar alterações?'),
        content: Text(
          alarmsChanged
              ? 'O que foi mudado nesta variável, inclusive os alarmes, ainda não foi salvo.'
              : 'O que foi mudado nesta variável ainda não foi salvo.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(key: const ValueKey('continuar-editando'), onPressed: () => Navigator.pop(ctx, _Leave.keep), child: const Text('Continuar editando')),
          TextButton(
            key: const ValueKey('descartar'),
            style: TextButton.styleFrom(foregroundColor: Ind.textFor(Ind.alarm)),
            onPressed: () => Navigator.pop(ctx, _Leave.discard),
            child: const Text('Descartar'),
          ),
          FilledButton(key: const ValueKey('salvar-e-sair'), onPressed: () => Navigator.pop(ctx, _Leave.save), child: const Text('Salvar')),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case _Leave.save:
        _save();
      case _Leave.discard:
        Navigator.pop(context);
      case _Leave.keep || null:
        break;
    }
  }

  // ── Tipo e onde fica ──────────────────────────────────────────────────────

  /// Os três formatos que cobrem quase todo caso — os únicos à vista.
  static bool _isMainType(TagDataType t) =>
      t == TagDataType.bool || t == TagDataType.uint16 || t == TagDataType.float32;

  void _setType(TagDataType t) {
    if (t == _type) return;
    // Texto pede vários registradores (1 registrador = 2 letras quase nunca é
    // o que se quer); saindo dele, o tamanho volta ao que era.
    if (t == TagDataType.string) {
      _lengthBeforeText = _length.text;
      if ((int.tryParse(_length.text) ?? 1) <= 1) _length.text = '10';
    } else if (_type == TagDataType.string) {
      _length.text = _lengthBeforeText ?? (widget.fit == TagFit.numberList ? '8' : '1');
      _lengthBeforeText = null;
    }
    _type = t;
    // Liga/desliga mora em bit; número, em registrador. A troca mantém o "só
    // leitura" de quem escolheu só leitura.
    final before = _where;
    if (t == TagDataType.bool) {
      if (_where == _Where.holding) _where = _Where.coil;
      if (_where == _Where.input) _where = _Where.discrete;
    } else {
      if (_where == _Where.coil || _where == _Where.bitInRegister) _where = _Where.holding;
      if (_where == _Where.discrete || _where == _Where.bitInInput) _where = _Where.input;
    }
    if (_where != before) _flashWhere();
    _onFieldChanged();
  }

  /// "Onde fica" mudou sem a pessoa tocar nele: o campo acende por um
  /// instante, para a mudança não passar calada.
  void _flashWhere() {
    _whereTimer?.cancel();
    _whereChanged = true;
    _whereTimer = Timer(const Duration(milliseconds: 2000), () {
      if (mounted) setState(() => _whereChanged = false);
    });
  }

  void _setWhere(_Where w) {
    _where = w;
    _onFieldChanged();
  }

  /// Liga/desliga o hexadecimal convertendo o que já foi digitado.
  void _setHex(bool on) {
    final v = AddressInput.parse(_address.text, hex: _hex);
    _hex = on;
    if (v != null) _address.text = AddressInput.format(v, hex: on);
    _onFieldChanged();
  }

  /// Resumo do que está em "Mais opções", para ninguém precisar abrir só
  /// para conferir.
  String _moreSummary() {
    final mqtt = _notModbus;
    final s7 = _isS7;
    final mq = _isMqtt
        ? _mq.summary(writable: _writable, isBool: _type == TagDataType.bool)
        : _isRaw
            ? _rw.summary(writable: _writable && _canWrite)
            : const <String>[];
    // Endereço em hexadecimal só existe no Modbus.
    final hex = _hex && !mqtt && !s7 ? 'endereço em hex' : null;
    // Com perfil, o endereço Modbus mora aqui: o resumo mostra qual é.
    final where = _addressInMore && _addressReading.address != null ? _draft().addressLabel : null;
    if (_type == TagDataType.bool) {
      if (mqtt || s7) return mq.isEmpty ? 'Observação' : mq.join(' · ');
      if (where != null) return [where, ?hex].join(' · ');
      return hex != null ? 'Endereço em hex' : 'Observação, endereço em hex';
    }
    if (_type == TagDataType.string) {
      if (mqtt || s7) return ['Texto', ...mq].join(' · ');
      return [?where, _order == ByteOrder.abcd ? 'Texto · STRING' : 'Texto · bytes trocados', ?hex].join(' · ');
    }
    final parts = <String>[
      ?where,
      ...mq,
      if (_scaleLabel() != null) _scaleLabel()!,
      if (_unit.text.trim().isNotEmpty) _unit.text.trim(),
      if (_decimals > 0) _decimals == 1 ? '1 casa decimal' : '$_decimals casas decimais',
      if (!_isMainType(_type)) s7 ? S7TagFields.technical(_type) : _type.technical,
      if (_order != ByteOrder.abcd) _order.label,
      if ((int.tryParse(_length.text) ?? 1) > 1) 'lista de ${_length.text}',
      ?hex,
    ];
    if (parts.isNotEmpty) return parts.join(' · ');
    return _isOpcUa ? 'Escala, unidade, decimais' : mqtt ? 'Escala, unidade, decimais, validade' : s7 ? 'Escala, unidade, decimais, formato' : 'Escala, unidade, decimais, formato, hex';
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
    if (_decimals < implied) _decimals = implied;
    _onFieldChanged();
  }

  void _onFieldChanged() => setState(() {
        if (!_fromMemory) _syncMemory();
        _liveValue = null;
        _liveError = null;
        _liveNote = null;
      });

  /// Escolheu um tópico (e campo) ouvido no broker: preenche o endereço, o
  /// tipo que combina com o valor e, sem nome ainda, um nome de partida.
  void _onMqttPick(MqttPick p) {
    _mq.topic.text = p.topic;
    _mq.jsonPath.text = p.jsonPath;
    _applyPick(p.suggestedName, p.type);
  }

  /// Escolheu um campo ouvido do equipamento cru: o mesmo, com o campo e as
  /// casas decimais do valor que chegou.
  void _onRawPick(RawPick p) {
    _rw.field.text = p.field;
    if (_decimals == 0) _decimals = p.decimals;
    _applyPick(p.suggestedName, p.type);
  }

  /// Nome de partida (se ainda não tem) e o tipo que combina com o valor
  /// ouvido — se o elemento que pediu a variável aceitar esse tipo.
  void _applyPick(String name, TagDataType type) {
    if (_name.text.trim().isEmpty) _name.text = name;
    final fits = switch (widget.fit) {
      TagFit.boolean => type == TagDataType.bool,
      TagFit.number || TagFit.numberList => type.isNumeric,
      TagFit.scalar => type != TagDataType.string,
      _ => true,
    };
    if (fits) {
      _setType(type);
    } else {
      _onFieldChanged();
    }
  }

  /// Escolheu uma variável navegando no servidor OPC UA: o NodeId, o tipo do
  /// valor e um nome de partida. Nó que o servidor não deixa gravar desliga
  /// o "Pode ser alterada pela tela".
  void _onOpcUaPick(OpcUaPick p) {
    _ua.nodeId.text = p.nodeId;
    if (!p.writable) _writable = false;
    // Lista do servidor (Int16[]…): já com quantos valores ler.
    _length.text = '${p.count.clamp(1, 120)}';
    if (_decimals == 0) _decimals = p.decimals;
    _applyPick(p.suggestedName, p.type);
  }

  /// Endereço S7 digitado: o tamanho dele sugere o tipo, se o de agora não
  /// cabe (DB1.DBX0.3 → liga/desliga, DB1.DBD8 → número com vírgula).
  void _onS7Changed() {
    final t = _s7.suggestedType(_type, widget.fit);
    if (t != null) {
      _setType(t);
    } else {
      _onFieldChanged();
    }
  }

  /// Erro do endereço S7 com o tipo e a lista de agora (nulo = certo).
  String? _s7Error() => _s7.error(_type, length: _draft().length);

  // ── Salvar e erros ────────────────────────────────────────────────────────

  static String? _rangeError(String? text, int min, int max) {
    final v = int.tryParse(text ?? '');
    if (v == null) return 'Número inteiro';
    if (v < min || v > max) return 'De $min a $max';
    return null;
  }

  static String? _scaleError(String? t) => (_parseNum(t ?? '') ?? 0) == 0 ? 'Não pode ser zero' : null;
  static String? _offsetError(String? t) => (t ?? '').trim().isNotEmpty && _parseNum(t!) == null ? 'Número' : null;

  /// Primeiro campo com erro, na ordem da tela, e se ele mora em "Mais
  /// opções". Não depende de o campo estar montado: com "Mais opções" fechado
  /// os campos de lá nem existem, e o erro passava batido (escala zero virava
  /// 1 em silêncio).
  (GlobalKey, bool)? _firstProblem() {
    if (Validators.name(_name.text) != null) return (_nameAnchor, false);
    if (_isMqtt) {
      if (_mq.build() == null) return (_addressAnchor, false);
    } else if (_isS7) {
      if (_s7Error() != null) return (_addressAnchor, false);
    } else if (_isRaw) {
      if (_rw.build() == null) return (_addressAnchor, false);
    } else if (_isOpcUa) {
      if (_ua.error() != null) return (_addressAnchor, false);
    } else {
      if (_memoryError() != null) return (_memoryAnchor, false);
      if (_addressReading.error != null) return (_addressAnchor, _addressInMore);
      if (_isBitOfWord && _rangeError(_bit.text, 0, 15) != null) return (_bitAnchor, _addressInMore);
    }
    if ((_lengthInMain || _lengthInMore) && _rangeError(_length.text, 1, 120) != null) return (_lengthAnchor, _lengthInMore);
    if (_type.isNumeric && _customScale && (_scaleError(_scale.text) != null || _offsetError(_offset.text) != null)) {
      return (_scaleAnchor, true);
    }
    return null;
  }

  void _save() {
    final formOk = _form.currentState?.validate() ?? false;
    final problem = _firstProblem();
    if (!formOk || problem != null) {
      // Daqui em diante cada campo se confere enquanto é corrigido.
      setState(() => _autovalidate = AutovalidateMode.onUserInteraction);
      if (problem != null) _reveal(problem.$1, inMore: problem.$2);
      return;
    }
    final t = _current();
    if (t == null) return;
    AppScope.of(context).controller.saveTag(t);
    Navigator.pop(context, t);
  }

  /// Leva até o campo com erro: abre "Mais opções" se ele mora lá (e espera a
  /// animação, porque fechado o campo não existe), mostra a mensagem e rola.
  void _reveal(GlobalKey anchor, {required bool inMore}) {
    _revealTimer?.cancel();
    // "Mais opções" é o último item da lista: longe da tela, nem está
    // montado — traz para perto antes de abrir.
    if (inMore && _moreKey.currentContext == null && _scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!inMore || _more.isExpanded) {
        _scrollTo(anchor, atEnd: inMore);
        return;
      }
      _revealingError = true;
      _more.expand();
      _revealingError = false;
      _revealTimer = Timer(const Duration(milliseconds: 280), () {
        if (!mounted) return;
        _form.currentState?.validate();
        _scrollTo(anchor, atEnd: true);
      });
    });
  }

  /// Rola até [anchor]. Se a lista ainda não montou aquele trecho (longe da
  /// tela), pula para a ponta onde ele está e tenta no quadro seguinte.
  void _scrollTo(GlobalKey anchor, {required bool atEnd, bool retry = true}) {
    final ctx = anchor.currentContext;
    if (ctx != null && ctx.mounted) {
      Scrollable.ensureVisible(ctx, alignment: 0.2, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
      return;
    }
    if (!retry || !_scroll.hasClients) return;
    _scroll.jumpTo(atEnd ? _scroll.position.maxScrollExtent : 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollTo(anchor, atEnd: atEnd, retry: false);
    });
  }

  /// Antes de apagar, diz o que deixa de funcionar: elementos de tela, contas
  /// de calculadas e regras que usam a variável.
  Future<void> _delete() async {
    final c = AppScope.of(context).controller;
    if (!await confirmDelete(context, title: 'Apagar "${widget.tag!.name}"?', body: TagUse.deleteNotice(c.project, _id))) return;
    c.deleteTag(_id);
    if (mounted) Navigator.pop(context);
  }

  /// Consequências da troca de tipo, ditas na hora: alarmes que deixam de
  /// valer (saem no Salvar) e elementos de tela que deixam de funcionar.
  /// Nulo quando a troca não quebra nada.
  Widget? _typeWarning(Project project, Tag draft, int dormant) {
    final original = widget.tag;
    final broken = original == null ? const <TagUse>[] : TagUse.brokenBy(TagUse.of(project, _id), original, draft);
    if (dormant == 0 && broken.isEmpty) return null;
    final how = draft.isArray ? 'numa lista' : 'com este tipo';
    return _Warning(
      key: const ValueKey('aviso-tipo'),
      lines: [
        if (dormant > 0)
          dormant == 1 ? '1 alarme deixa de valer $how e sai ao salvar.' : '$dormant alarmes deixam de valer $how e saem ao salvar.',
        if (broken.isNotEmpty)
          'Usada em: ${TagUse.describe(broken)}. ${capitalized(how)}, ${broken.length == 1 ? 'esse elemento deixa' : 'esses elementos deixam'} de funcionar.',
      ],
    );
  }

  // ── Tela ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final project = AppScope.watch(context).controller.project;
    final fit = widget.fit;
    final typeOptions = TagDataType.values.where((t) {
      if (fit == TagFit.boolean) return t == TagDataType.bool;
      if (fit == TagFit.number || fit == TagFit.numberList) return t.isNumeric;
      if (fit == TagFit.scalar) return t != TagDataType.string;
      return true;
    }).toList();
    final isText = _type == TagDataType.string;
    final mqtt = _isMqtt;
    final s7 = _isS7;
    final raw = _isRaw;
    final opcua = _isOpcUa;
    final canWrite = _canWrite;
    final draft = _draft();
    final live = _current();
    final dormantAlarms = _alarms.where((a) => !draft.acceptsAlarm(a)).toList();
    final typeWarning = _typeWarning(project, draft, dormantAlarms.length);

    // Sugestões a partir do valor lido (só quando o valor tem cara de errado).
    // Uma de cada vez: inteiro grande sem sinal acima de 2³¹ também passa de
    // 10⁹, e o sinal é a explicação mais comum — se não resolver, a ordem
    // aparece em seguida.
    final readOk = live != null && _liveError == null && _liveValue != null;
    // No OPC UA o servidor manda o número já com sinal e tipo: nada a sugerir.
    final signed = readOk && !opcua ? ReadingHints.signedInstead(live, _liveValue) : null;
    // No S7 não há ordem de bytes para sugerir: é sempre big-endian.
    final betterOrder = readOk && signed == null && !s7 && !opcua && ReadingHints.looksAbsurd(live, _liveValue)
        ? ReadingHints.nextOrder(_order, _absurdKey == _decodeKey(live) ? _absurdOrders : const {})
        : null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_editing ? 'Variável' : 'Nova variável'),
          actions: [
            if (_editing) IconButton(tooltip: 'Apagar', icon: Icon(Icons.delete_outline_rounded, color: Ind.alarm), onPressed: _delete),
          ],
        ),
        // No tablet, campos e Salvar com no máximo 640 dp (TB-3).
        bottomNavigationBar: FormWidth(child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton.icon(
              key: const ValueKey('salvar-variavel'),
              onPressed: project.equipment.isEmpty ? null : _save,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Salvar'),
            ),
          ),
        )),
        body: FormWidth(child: project.equipment.isEmpty
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
                autovalidateMode: _autovalidate,
                // Só o essencial à vista (equipamento, nome, tipo, onde, endereço,
                // permissão). Apresentação, lista, formatos raros e ordem de
                // bytes ficam em "Mais opções" — a maioria nunca precisa abrir.
                // "Lendo agora" preso no topo: é a resposta a cada campo mexido
                // (endereço, formato, escala) — rolando junto, sumia justo quando
                // se ajustava a escala lá embaixo.
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Ind.page, 12, Ind.page, 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _LivePanel(
                        value: _liveValue,
                        error: _liveError,
                        tag: live,
                        note: _liveNote,
                        idle: _deviceId == null
                            ? 'Escolha o equipamento'
                            : mqtt
                                ? 'Complete o tópico'
                                : s7
                                ? 'Complete o endereço do CLP'
                                : raw
                                ? 'Diga qual campo da mensagem'
                                : opcua
                                ? 'Complete o NodeId'
                                : _addressReading.overMax
                                ? 'Endereço acima de 65535'
                                : _addressReading.error ?? 'Complete equipamento e endereço',
                      ),
                      if (signed != null) ...[
                        const SizedBox(height: 8),
                        SuggestionTile(
                          key: const ValueKey('sugestao-com-sinal'),
                          text: 'Passou de ${signed == TagDataType.int16 ? '32767' : '2147483647'}. Se deveria ser negativo, use ${signed.label}. Toque para usar.',
                          onTap: () => _setType(signed),
                        ),
                      ],
                      if (betterOrder != null) ...[
                        const SizedBox(height: 8),
                        SuggestionTile(
                          key: const ValueKey('sugestao-ordem'),
                          text: betterOrder == ByteOrder.cdab
                              ? 'Valor estranho para ${_type.label.toLowerCase()}. Tente palavras trocadas (CDAB), comum em CLP. Toque para usar.'
                              : 'Valor estranho. Tente a ordem ${betterOrder.label} (${betterOrder.hint.toLowerCase()}). Toque para usar.',
                          onTap: () {
                            _order = betterOrder;
                            _onFieldChanged();
                          },
                        ),
                      ],
                    ]),
                  ),
                  Expanded(
                    child: ListView(
                      key: const ValueKey('formulario-variavel'),
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
                      children: [
                        // Um equipamento só (o caso comum): nem pergunta.
                        if (project.equipment.length > 1) ...[
                          const SectionHeader('Equipamento', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)),
                          DevicePick(
                            devices: project.equipment,
                            selectedId: _deviceId,
                            onChanged: (id) {
                              _deviceId = id;
                              _profile = VendorProfiles.of(project.device(id));
                              _onFieldChanged();
                            },
                          ),
                        ],
                        const SizedBox(height: Ind.spaceLarge),
                        KeyedSubtree(
                          key: _nameAnchor,
                          child: TextFormField(
                            key: const ValueKey('campo-nome-variavel'),
                            controller: _name,
                            validator: Validators.name,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: const InputDecoration(labelText: 'Nome', hintText: 'Ex.: Velocidade da faca'),
                          ),
                        ),
                        // Com marca e modelo no equipamento: a memória como no
                        // manual, e o resto do formulário segue (MP-3).
                        if (_profile != null && !mqtt && !s7) ...[
                          const SizedBox(height: Ind.space),
                          KeyedSubtree(key: _memoryAnchor, child: _memoryField()),
                        ],
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
                        if (typeWarning != null && _isMainType(_type)) ...[const SizedBox(height: 12), typeWarning],
                        // Com perfil, "Onde fica" e o endereço Modbus moram em
                        // "Mais opções": a memória do manual já diz onde (MP-3).
                        if (!_addressInMore) _whereHeader('Onde fica', const EdgeInsets.fromLTRB(0, 28, 0, 12)),
                        // MQTT: o endereço é o tópico (e o campo do JSON).
                        if (mqtt)
                          KeyedSubtree(
                            key: _addressAnchor,
                            child: MqttAddressBlock(fields: _mq, device: _device, onChanged: _onFieldChanged, onPick: _onMqttPick),
                          )
                        // S7: o endereço do TIA, com a prova da leitura embaixo.
                        else if (s7)
                          KeyedSubtree(
                            key: _addressAnchor,
                            child: S7AddressBlock(fields: _s7, type: _type, length: draft.length, onChanged: _onS7Changed),
                          )
                        // Cru: o endereço é o campo da mensagem.
                        else if (raw)
                          KeyedSubtree(
                            key: _addressAnchor,
                            child: RawAddressBlock(fields: _rw, device: _device, onChanged: _onFieldChanged, onPick: _onRawPick),
                          )
                        // OPC UA: o NodeId, com "Navegar e escolher".
                        else if (opcua)
                          KeyedSubtree(
                            key: _addressAnchor,
                            child: OpcUaAddressBlock(fields: _ua, device: _device, onChanged: _onFieldChanged, onPick: _onOpcUaPick),
                          )
                        else if (!_addressInMore)
                          ..._modbusAddress(),
                        // Lista é obrigatória para o gráfico de barras: aí fica à vista.
                        if (_lengthInMain && !isText) ...[
                          const SizedBox(height: Ind.space),
                          KeyedSubtree(
                            key: _lengthAnchor,
                            child: StepperField(label: 'Quantos valores seguidos', controller: _length, min: 1, max: 120, onChanged: _onFieldChanged),
                          ),
                        ],
                        // Texto: o tamanho é o essencial (quantos registradores ler).
                        // No MQTT o texto vem inteiro na mensagem.
                        if (isText && !mqtt && !s7 && !raw && !opcua) ...[
                          const SizedBox(height: Ind.space),
                          KeyedSubtree(
                            key: _lengthAnchor,
                            child: StepperField(
                              fieldKey: const ValueKey('campo-tamanho-texto'),
                              label: 'Tamanho em registradores',
                              controller: _length,
                              min: 1,
                              max: 120,
                              helper: '2 letras por registrador: ${_length.text} = até ${(int.tryParse(_length.text) ?? 1) * 2} letras.',
                              onChanged: _onFieldChanged,
                            ),
                          ),
                        ],
                        const SizedBox(height: Ind.spaceSmall),
                        SwitchListTile(
                          key: const ValueKey('pode-gravar'),
                          contentPadding: EdgeInsets.zero,
                          value: _writable && canWrite,
                          onChanged: canWrite ? (v) => setState(() => _writable = v) : null,
                          title: const Text('Pode ser alterada pela tela'),
                          subtitle: isText
                              ? const Text('Texto é só leitura nesta versão.')
                              : canWrite
                                  ? null
                                  : const Text('Esta memória é só de leitura.'),
                        ),
                        if (mqtt && _writable && canWrite) ...[
                          const SizedBox(height: Ind.spaceSmall),
                          MqttCommandField(fields: _mq, onChanged: _onFieldChanged),
                        ],
                        if (raw && _writable && canWrite) ...[
                          const SizedBox(height: Ind.spaceSmall),
                          RawCommandField(fields: _rw, device: _device, onChanged: _onFieldChanged),
                        ],
                        // Alarme: uma linha só, à vista (é segurança, não detalhe); o
                        // editor abre numa folha. Texto e lista não alarmam.
                        if (!draft.isText && !draft.isArray) ...[
                          const SizedBox(height: Ind.spaceSmall),
                          AlarmsRow(
                            tag: draft,
                            alarms: [for (final a in _alarms) if (draft.acceptsAlarm(a)) a],
                            // Os que não valem com este tipo continuam guardados.
                            onChanged: (a) => setState(() => _alarms = [...a, ...dormantAlarms]),
                          ),
                          // Narração: o operador ouve no fone o passo da máquina.
                          const SizedBox(height: Ind.spaceSmall),
                          NarrationsRow(tag: draft, narrations: _narrations, onChanged: (n) => setState(() => _narrations = n)),
                        ],
                        const SizedBox(height: Ind.spaceSmall),
                        _moreOptions(typeOptions, typeWarning),
                      ],
                    ),
                  ),
                ]),
              )),
      ),
    );
  }

  /// Com perfil de fabricante (e fora do MQTT), o endereço Modbus fica em
  /// "Mais opções": à vista, só a "Memória do CLP".
  bool get _addressInMore => _profile != null && !_isMqtt && !_isS7 && !_isRaw && !_isOpcUa;

  /// Título do bloco de endereço, com o aviso de quando o tipo mudou "Onde
  /// fica" sozinho.
  Widget _whereHeader(String title, EdgeInsets padding) => SectionHeader(
        title,
        padding: padding,
        trailing: AnimatedOpacity(
          opacity: _whereChanged && !_notModbus && !_isS7 ? 1 : 0,
          duration: const Duration(milliseconds: 250),
          child: Text('mudou com o tipo', style: TextStyle(color: Ind.accent, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ),
      );

  /// "Onde fica", endereço Modbus e bit. À vista no Modbus genérico; com
  /// perfil, em "Mais opções", preenchidos pela memória (e editáveis).
  List<Widget> _modbusAddress() => [
        _whereBlock(),
        const SizedBox(height: Ind.spaceLarge),
        KeyedSubtree(
          key: _addressAnchor,
          child: AddressField(controller: _address, area: _area, hex: _hex, manual: _profile == null, onChanged: _onFieldChanged),
        ),
        if (_isBitOfWord) ...[
          const SizedBox(height: Ind.space),
          KeyedSubtree(
            key: _bitAnchor,
            child: StepperField(
              fieldKey: const ValueKey('campo-bit'),
              label: 'Qual bit (0 a 15)',
              controller: _bit,
              min: 0,
              max: 15,
              onChanged: _onFieldChanged,
            ),
          ),
        ],
      ];

  /// "Onde fica": os cartões e, para bit de palavra, de qual registrador.
  Widget _whereBlock() {
    final isBool = _type == TagDataType.bool;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Stack(clipBehavior: Clip.none, children: [
        // Realce atrás dos cartões quando a troca de tipo mudou a escolha.
        Positioned(
          left: -8,
          right: -8,
          top: -8,
          bottom: -8,
          child: IgnorePointer(
            child: AnimatedOpacity(
              key: const ValueKey('onde-fica-destaque'),
              opacity: _whereChanged ? 1 : 0,
              duration: const Duration(milliseconds: 250),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Ind.accent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(Ind.radius),
                  border: Border.all(color: Ind.accent.withValues(alpha: 0.6), width: 1.5),
                ),
              ),
            ),
          ),
        ),
        ChoiceCards<_Where>(
          options: isBool
              ? const [
                  ChoiceOption(value: _Where.coil, title: 'Bit', subtitle: 'Lê e grava'),
                  ChoiceOption(value: _Where.discrete, title: 'Entrada', subtitle: 'Só leitura'),
                  ChoiceOption(value: _Where.bitInRegister, title: 'Bit de palavra', subtitle: 'Dentro de um registrador'),
                ]
              : const [
                  ChoiceOption(value: _Where.holding, title: 'Registrador', subtitle: 'Lê e grava'),
                  ChoiceOption(value: _Where.input, title: 'Registrador de entrada', subtitle: 'Só leitura'),
                ],
          // Bit de registrador de entrada é o mesmo cartão "Bit de palavra";
          // o registrador se escolhe logo abaixo.
          selected: _where == _Where.bitInInput ? _Where.bitInRegister : _where,
          columns: isBool ? 3 : 2,
          // Tocar de novo em "Bit de palavra" não troca o registrador escolhido.
          onChanged: (w) => _setWhere(w == _Where.bitInRegister && _isBitOfWord ? _where : w),
        ),
      ]),
      // Palavra de status costuma ser só leitura: o bit pode vir de um
      // registrador de entrada também. Só aparece para quem escolheu bit de
      // palavra.
      if (_isBitOfWord) ...[
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ChoiceChip(
            key: const ValueKey('bit-em-registrador'),
            label: const Text('Registrador · lê e grava'),
            selected: _where == _Where.bitInRegister,
            onSelected: (_) => _setWhere(_Where.bitInRegister),
          ),
          ChoiceChip(
            key: const ValueKey('bit-em-registrador-entrada'),
            label: const Text('Registrador de entrada · só leitura'),
            selected: _where == _Where.bitInInput,
            onSelected: (_) => _setWhere(_Where.bitInInput),
          ),
        ]),
      ],
    ]);
  }

  /// "Mais opções": escala, unidade, decimais, lista, formatos raros, ordem
  /// dos bytes, endereço em hexadecimal e observação.
  Widget _moreOptions(List<TagDataType> typeOptions, Widget? typeWarning) {
    final isText = _type == TagDataType.string;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: _moreKey,
        controller: _more,
        tilePadding: EdgeInsets.zero,
        onExpansionChanged: (open) {
          if (!_revealingError) revealAfterExpand(_moreKey, open);
        },
        childrenPadding: const EdgeInsets.only(bottom: 8),
        // Formato raro escolhido: abre sozinho, para não esconder a escolha.
        initiallyExpanded: !_isMainType(_type) || _order != ByteOrder.abcd,
        title: const Text('Mais opções'),
        subtitle: Text(_moreSummary(), style: TextStyle(color: Ind.textMuted, fontSize: 13)),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isMqtt) MqttMoreOptions(fields: _mq, writable: _writable && _canWrite, isBool: _type == TagDataType.bool, onChanged: _onFieldChanged),
          if (_isRaw) RawTagMoreOptions(fields: _rw, writable: _writable && _canWrite, onChanged: _onFieldChanged),
          if (_addressInMore) ...[
            _whereHeader('Endereço Modbus', const EdgeInsets.fromLTRB(0, 8, 0, 12)),
            ..._modbusAddress(),
            const SizedBox(height: Ind.space),
          ],
          if (_type.isNumeric) ...[
            // Escala primeiro: é o que mais se usa aqui ("o
            // manual diz para dividir por 10").
            const SectionHeader('Escala do equipamento', padding: EdgeInsets.fromLTRB(0, 8, 0, 6)),
            Text('O equipamento manda sem vírgula? Ex.: vem 752 e é 75,2 °C → ÷ 10.', style: TextStyle(color: Ind.textDim, height: 1.35)),
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
              KeyedSubtree(
                key: _scaleAnchor,
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('campo-fator'),
                      controller: _scale,
                      keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                      decoration: const InputDecoration(labelText: 'Multiplica por'),
                      validator: _scaleError,
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
                      validator: _offsetError,
                      onChanged: (_) => _onFieldChanged(),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 6),
              Text('Valor na tela = valor do equipamento × fator + soma. Ao gravar, o app faz a conta ao contrário.',
                  style: TextStyle(color: Ind.textMuted, fontSize: 12.5, height: 1.35)),
            ],
            const SizedBox(height: Ind.space),
          ],
          if (_type != TagDataType.bool) ...[
            if (!isText) ...[
              TextFormField(
                key: const ValueKey('campo-unidade'),
                controller: _unit,
                decoration: const InputDecoration(labelText: 'Unidade', hintText: 'Ex.: °C, m/min'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final u in _unitPresets)
                  ChoiceChip(
                    key: ValueKey('unidade-$u'),
                    label: Text(u),
                    selected: _unit.text.trim() == u,
                    // Tocar no que já está marcado tira a unidade.
                    onSelected: (on) => setState(() => _unit.text = on ? u : ''),
                  ),
              ]),
              const SizedBox(height: Ind.space),
              _DecimalsStepper(value: _decimals, onChanged: (d) => setState(() => _decimals = d)),
            ],
            if (_lengthInMore) ...[
              const SizedBox(height: Ind.space),
              KeyedSubtree(
                key: _lengthAnchor,
                child: StepperField(label: 'Quantos valores seguidos', controller: _length, min: 1, max: 120, helper: 'Mais que 1 forma uma lista (gráfico de barras).', onChanged: _onFieldChanged),
              ),
            ],
            // MQTT e cru não têm registrador: 16/32 bits e ordem de bytes não
            // existem lá; dos formatos raros só sobra texto.
            if (typeOptions.any((t) => !_isMainType(t) && (!_notModbus || t == TagDataType.string))) ...[
              const SectionHeader('Outros formatos', padding: EdgeInsets.fromLTRB(0, 24, 0, 10)),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final t in typeOptions.where((t) => !_isMainType(t) && (!_notModbus || t == TagDataType.string)))
                  ChoiceChip(key: ValueKey('formato-${t.name}'), label: Text(_notModbus ? t.label : '${t.label} · ${_isS7 ? S7TagFields.technical(t) : t.technical}'), selected: _type == t, onSelected: (_) => _setType(t)),
              ]),
            ],
            // Formato raro escolhido aqui: o aviso da troca aparece aqui também,
            // onde a pessoa está olhando.
            if (typeWarning != null && !_isMainType(_type)) ...[const SizedBox(height: 12), typeWarning],
            // S7 é sempre big-endian e MQTT e cru não têm registrador: não há
            // ordem para escolher.
            if (!_notModbus && !_isS7) ...[
            const SectionHeader('Ordem dos bytes', padding: EdgeInsets.fromLTRB(0, 24, 0, 10)),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final o in ByteOrder.values)
                if (_type.is32Bit || o == ByteOrder.abcd || o == ByteOrder.badc)
                  ChoiceChip(
                    key: ValueKey('ordem-${o.name}'),
                    label: Text(o == ByteOrder.abcd ? 'Padrão' : '${o.label} · ${o.hint}'),
                    selected: _order == o,
                    onSelected: (_) {
                      _order = o;
                      _onFieldChanged();
                    },
                  ),
            ]),
            ],
            const SizedBox(height: Ind.space),
          ],
          // LG-5: regra entre máquinas só grava onde a pessoa marcou.
          if (_writable && _canWrite)
            SwitchListTile(
              key: const ValueKey('aceita-regra'),
              contentPadding: EdgeInsets.zero,
              value: _ruleWritable,
              onChanged: (v) => setState(() => _ruleWritable = v),
              title: const Text('Aceita escrita por regra'),
              subtitle: const Text('Uma regra de Mais → Regras pode gravar aqui.'),
            ),
          // Endereço como o manual escreve. A "Memória do CLP" (perfis de
          // fabricante) é a outra opção de endereço que mora aqui.
          if (!_notModbus && !_isS7) SwitchListTile(
            key: const ValueKey('endereco-hex'),
            contentPadding: EdgeInsets.zero,
            value: _hex,
            onChanged: _setHex,
            title: const Text('Endereço em hexadecimal'),
            subtitle: const Text('Para manual que escreve 0x2000 ou 2000h. O teclado ganha as letras A a F.'),
          ),
          const SizedBox(height: Ind.spaceSmall),
          TextFormField(
            controller: _description,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Observação', hintText: 'Ex.: 0 parada · 1 em ciclo'),
          ),
        ],
      ),
    );
  }
}

/// Casas decimais com − / + (0 a 6): número digitado à mão era ajustado em
/// silêncio quando fora da faixa. O exemplo mostra como o valor vai aparecer.
class _DecimalsStepper extends StatelessWidget {
  const _DecimalsStepper({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Casas decimais', style: TextStyle(color: Ind.text, fontSize: 16)),
            const SizedBox(height: 2),
            Text('Ex.: ${75.2468.toStringAsFixed(value).replaceAll('.', ',')}', style: TextStyle(color: Ind.textMuted, fontSize: 12.5)),
          ]),
        ),
        IconButton.outlined(
          key: const ValueKey('decimais-menos'),
          onPressed: value > 0 ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove_rounded),
        ),
        SizedBox(width: 44, child: Text('$value', key: const ValueKey('casas-decimais'), textAlign: TextAlign.center, style: Ind.number(18))),
        IconButton.outlined(
          key: const ValueKey('decimais-mais'),
          onPressed: value < 6 ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add_rounded),
        ),
      ]);
}

/// Aviso em amarelo de atenção, uma frase por linha.
class _Warning extends StatelessWidget {
  const _Warning({super.key, required this.lines});
  final List<String> lines;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Ind.warn.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(Ind.radiusSmall),
          border: Border.all(color: Ind.warn.withValues(alpha: 0.45)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.warning_amber_rounded, color: Ind.textFor(Ind.warn), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final (i, l) in lines.indexed) ...[
                if (i > 0) const SizedBox(height: 6),
                Text(l, style: const TextStyle(height: 1.35)),
              ],
            ]),
          ),
        ]),
      );
}

/// Painel "Lendo agora do equipamento".
class _LivePanel extends StatelessWidget {
  const _LivePanel({required this.value, required this.error, required this.tag, required this.idle, this.note});
  final Object? value;
  final String? error;
  final Tag? tag;

  /// O que falta para começar a ler ("Endereço acima de 65535").
  final String idle;

  /// Aviso neutro no lugar do valor ("esperando mensagem em …").
  final String? note;

  @override
  Widget build(BuildContext context) {
    final err = error;
    final color = err != null ? Ind.alarm : (value != null ? Ind.ok : Ind.textMuted);
    final t = tag;
    final waiting = note != null ? capitalized(note!) : 'Lendo…';
    final text = err != null ? capitalized(err) : (t == null ? idle : value == null ? waiting : _fmt(t, value));
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
        // Tópico MQTT pode ser comprido: o valor lido é que não pode sumir.
        if (t != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 130),
            child: Text(t.addressLabel, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: Ind.number(12, color: Ind.textMuted)),
          ),
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
