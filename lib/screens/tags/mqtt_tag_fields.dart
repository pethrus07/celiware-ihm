import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/comm/comm_error.dart';
import '../../core/mqtt/mqtt_topic.dart';
import '../../core/theme/app_theme.dart';
import '../../models/device.dart';
import '../../models/mqtt_config.dart';
import '../../models/tag.dart';
import '../../services/runtime/drivers/mqtt_driver.dart';
import '../../services/runtime/mqtt_codec.dart';
import '../../widgets/common/common.dart';

/// Estado dos campos MQTT do cadastro de variável — o "endereço" quando o
/// equipamento é MQTT. Fica fora do formulário para ele só trocar o bloco de
/// endereço Modbus por este, sem misturar as duas lógicas.
class MqttTagFields {
  MqttTagFields(MqttAddress? a)
      : topic = TextEditingController(text: a?.topic ?? ''),
        jsonPath = TextEditingController(text: a?.jsonPath ?? ''),
        commandTopic = TextEditingController(text: a?.commandTopic ?? ''),
        qos = a?.qos ?? 0,
        retain = a?.retain ?? false,
        validitySec = a?.validitySec ?? 0,
        boolFormat = a?.boolFormat ?? MqttBoolFormat.oneZero,
        commandJson = a?.commandJson ?? false;

  final TextEditingController topic;
  final TextEditingController jsonPath;
  final TextEditingController commandTopic;
  int qos;
  bool retain;
  int validitySec;
  MqttBoolFormat boolFormat;
  bool commandJson;

  /// Nulo enquanto o tópico não for um filtro válido.
  MqttAddress? build() {
    final t = topic.text.trim();
    if (!MqttTopic.isValidFilter(t)) return null;
    final path = jsonPath.text.trim();
    return MqttAddress(
      topic: t,
      jsonPath: path,
      commandTopic: commandTopic.text.trim(),
      qos: qos,
      retain: retain,
      validitySec: validitySec,
      boolFormat: boolFormat,
      commandJson: commandJson && path.isNotEmpty,
    );
  }

  /// O que está valendo em "Mais opções", para o resumo fechado.
  List<String> summary({required bool writable, required bool isBool}) => [
        if (validitySec > 0) 'validade ${validityLabel(validitySec)}',
        if (qos == 1) 'QoS 1',
        if (writable && isBool && boolFormat != MqttBoolFormat.oneZero) boolFormat.label,
        if (writable && commandJson && jsonPath.text.trim().isNotEmpty) 'comando em JSON',
        if (writable && retain) 'retain',
      ];

  void dispose() {
    topic.dispose();
    jsonPath.dispose();
    commandTopic.dispose();
  }

  static const validityOptions = [0, 10, 30, 60, 300];

  static String validityLabel(int s) => s == 0 ? 'Sem prazo' : (s >= 60 && s % 60 == 0 ? '${s ~/ 60} min' : '$s s');
}

/// Tópico e campo do JSON — o que fica à vista no lugar de "Onde fica" e
/// "Endereço". O "Ouvir o broker" poupa digitar tópico de cabeça.
class MqttAddressBlock extends StatelessWidget {
  const MqttAddressBlock({super.key, required this.fields, required this.device, required this.onChanged, required this.onPick});

  final MqttTagFields fields;
  final Device? device;
  final VoidCallback onChanged;
  final ValueChanged<MqttPick> onPick;

  Future<void> _listen(BuildContext context) async {
    final d = device;
    if (d == null) return;
    final pick = await showMqttListenSheet(context, d);
    if (pick != null) onPick(pick);
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextFormField(
        key: const ValueKey('campo-topico'),
        controller: fields.topic,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(labelText: 'Tópico', hintText: 'Ex.: cortadora/temperatura'),
        validator: (v) => MqttTopic.isValidFilter((v ?? '').trim()) ? null : 'Informe o tópico (+ e # só ocupando um nível inteiro)',
        onChanged: (_) => onChanged(),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('ouvir-broker'),
          onPressed: device == null ? null : () => _listen(context),
          icon: const Icon(Icons.hearing_rounded),
          label: const Text('Ouvir o broker e escolher'),
        ),
      ),
      const SizedBox(height: Ind.spaceSmall),
      TextFormField(
        key: const ValueKey('campo-json'),
        controller: fields.jsonPath,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(
          labelText: 'Campo do JSON (opcional)',
          hintText: 'Ex.: sensores.temp',
          helperText: 'Quando a mensagem traz vários valores num JSON.',
        ),
        onChanged: (_) => onChanged(),
      ),
    ]);
  }
}

/// Onde gravar — aparece só quando a variável pode ser alterada pela tela.
class MqttCommandField extends StatelessWidget {
  const MqttCommandField({super.key, required this.fields, required this.onChanged});
  final MqttTagFields fields;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final state = fields.topic.text.trim();
    return TextFormField(
      key: const ValueKey('campo-topico-comando'),
      controller: fields.commandTopic,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: 'Tópico de comando',
        hintText: state.isEmpty || MqttTopic.hasWildcard(state) ? 'Ex.: cortadora/velocidade/set' : 'Vazio = grava em $state',
        helperText: 'Costuma ser outro: o equipamento lê o comando e publica o estado novo.',
        helperMaxLines: 2,
      ),
      validator: (v) {
        final c = (v ?? '').trim();
        if (c.isEmpty) return MqttTopic.hasWildcard(state) ? 'Tópico com + ou #: diga onde gravar' : null;
        return MqttTopic.isValidTopic(c) ? null : 'Comando não aceita + nem #';
      },
      onChanged: (_) => onChanged(),
    );
  }
}

/// O que é MQTT em "Mais opções": validade, QoS e o formato do comando.
class MqttMoreOptions extends StatelessWidget {
  const MqttMoreOptions({super.key, required this.fields, required this.writable, required this.isBool, required this.onChanged});

  final MqttTagFields fields;
  final bool writable;
  final bool isBool;
  final VoidCallback onChanged;

  // O cabeçalho de seção do app, como "Validade da mensagem" logo acima.
  Widget _label(String text) => SectionHeader(text, padding: const EdgeInsets.fromLTRB(0, 8, 0, 10));

  @override
  Widget build(BuildContext context) {
    final validity = {...MqttTagFields.validityOptions, fields.validitySec}.toList()..sort();
    final hasPath = fields.jsonPath.text.trim().isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionHeader('Validade da mensagem', padding: EdgeInsets.fromLTRB(0, 8, 0, 6)),
      Text('Sem mensagem nova nesse tempo, a variável fica "sem comunicação" — para equipamento que publica de tempos em tempos.',
          style: TextStyle(color: Ind.textDim, height: 1.35)),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in validity)
          ChoiceChip(
            key: ValueKey('validade-$s'),
            label: Text(MqttTagFields.validityLabel(s)),
            selected: fields.validitySec == s,
            onSelected: (_) {
              fields.validitySec = s;
              onChanged();
            },
          ),
      ]),
      const SizedBox(height: Ind.space),
      _label('Entrega (QoS)'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (q, text) in const [(0, '0 · mais leve'), (1, '1 · com confirmação')])
          ChoiceChip(
            key: ValueKey('qos-$q'),
            label: Text(text),
            selected: fields.qos == q,
            onSelected: (_) {
              fields.qos = q;
              onChanged();
            },
          ),
      ]),
      if (writable) ...[
        if (isBool) ...[
          const SizedBox(height: Ind.space),
          _label('Gravar liga/desliga como'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final f in MqttBoolFormat.values)
              ChoiceChip(
                key: ValueKey('formato-${f.name}'),
                label: Text(f.label),
                selected: fields.boolFormat == f,
                onSelected: (_) {
                  fields.boolFormat = f;
                  onChanged();
                },
              ),
          ]),
        ],
        if (hasPath)
          SwitchListTile(
            key: const ValueKey('comando-json'),
            contentPadding: EdgeInsets.zero,
            value: fields.commandJson,
            onChanged: (v) {
              fields.commandJson = v;
              onChanged();
            },
            title: const Text('Gravar como JSON'),
            subtitle: Text('{"${fields.jsonPath.text.trim()}": valor} em vez do valor puro.'),
          ),
        SwitchListTile(
          key: const ValueKey('comando-retain'),
          contentPadding: EdgeInsets.zero,
          value: fields.retain,
          onChanged: (v) {
            fields.retain = v;
            onChanged();
          },
          title: const Text('Guardar o comando no broker (retain)'),
          subtitle: const Text('Desligado é o seguro: comando guardado pode rodar de novo quando o equipamento reconectar.'),
        ),
      ],
      const SizedBox(height: Ind.space),
    ]);
  }
}

// ── Ouvir o broker (MQ-5) ──────────────────────────────────────────────────────

/// Tópico (e campo) escolhido no "ouvir o broker", com o tipo que combina com
/// o valor ouvido.
class MqttPick {
  const MqttPick(this.topic, this.jsonPath, this.type);
  final String topic;
  final String jsonPath;
  final TagDataType type;

  /// Nome sugerido para variável sem nome: o último nível ("temp").
  String get suggestedName {
    final last = (jsonPath.isNotEmpty ? jsonPath : topic).split(RegExp(r'[./]')).lastWhere((s) => s.isNotEmpty, orElse: () => topic);
    return capitalized(last.replaceAll('_', ' '));
  }
}

Future<MqttPick?> showMqttListenSheet(BuildContext context, Device device) => showModalBottomSheet<MqttPick>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ListenSheet(device: device),
    );

/// Ouve tudo no broker por 10 s e lista tópicos e campos; tocar escolhe.
class _ListenSheet extends StatefulWidget {
  const _ListenSheet({required this.device});
  final Device device;

  @override
  State<_ListenSheet> createState() => _ListenSheetState();
}

class _ListenSheetState extends State<_ListenSheet> {
  static const _seconds = 10;
  final Map<String, MqttHeard> _heard = {};
  String? _error;
  bool _done = false;
  bool _closed = false;
  int _left = _seconds;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _closed = true;
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _heard.clear();
      _error = null;
      _done = false;
      _left = _seconds;
    });
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _left > 0) setState(() => _left--);
    });
    try {
      await MqttDriver.listen(
        widget.device,
        duration: const Duration(seconds: _seconds),
        onHeard: (h) {
          if (mounted) setState(() => _heard[h.topic] = h);
        },
        cancelled: () => _closed,
      );
    } on CommError catch (e) {
      _error = e.userMessage;
    }
    _tick?.cancel();
    if (mounted) setState(() => _done = true);
  }

  void _pick(String topic, String path, Object? value) => Navigator.pop(context, MqttPick(topic, path, MqttCodec.guessType(value)));

  static String _preview(Object? v) {
    final s = v is String ? v : '$v';
    return s.length <= 60 ? s : '${s.substring(0, 60)}…';
  }

  @override
  Widget build(BuildContext context) {
    final status = _error != null
        ? 'Não conectou: ${_error!}'
        : _done
            ? (_heard.isEmpty ? 'Nada chegou em $_seconds s.' : '${_heard.length} tópicos. Toque no valor que quer usar.')
            : 'Ouvindo… $_left s · ${_heard.length} tópicos';
    final topics = _heard.values.toList()..sort((a, b) => a.topic.compareTo(b.topic));
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Ind.page, 20, Ind.page, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Ouvir o broker', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(status, key: const ValueKey('ouvir-status'), style: TextStyle(color: _error != null ? Ind.textFor(Ind.alarm) : Ind.textDim)),
            if (!_done) ...[const SizedBox(height: 12), const LinearProgressIndicator()],
          ]),
        ),
        Expanded(
          child: _done && _heard.isEmpty && _error == null
              ? Padding(
                  padding: const EdgeInsets.all(Ind.page),
                  child: Text('O equipamento está publicando? Mensagem com retain aparece na hora; as outras, só quando o equipamento publica.',
                      style: TextStyle(color: Ind.textDim, height: 1.4)),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(Ind.page, 4, Ind.page, 16),
                  children: [
                    for (final h in topics) ..._topicRows(h),
                  ],
                ),
        ),
        if (_done)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Ind.page, 4, Ind.page, 12),
              child: OutlinedButton.icon(onPressed: _start, icon: const Icon(Icons.refresh_rounded), label: const Text('Ouvir de novo')),
            ),
          ),
      ]),
    );
  }

  /// Um tópico: valor simples numa linha só; JSON abre um campo por linha.
  List<Widget> _topicRows(MqttHeard h) {
    final fields = MqttCodec.fields(h.payload);
    if (fields.isEmpty) {
      return [
        ListTile(
          key: ValueKey('ouvido-${h.topic}'),
          contentPadding: EdgeInsets.zero,
          title: Text(h.topic, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(_preview(h.payload), maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _pick(h.topic, '', h.payload),
        ),
      ];
    }
    return [
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 2),
        child: Text(h.topic, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      for (final (path, value) in fields)
        ListTile(
          key: ValueKey('ouvido-${h.topic}-$path'),
          dense: true,
          contentPadding: const EdgeInsets.only(left: 12),
          title: Text(path, style: Ind.number(14, color: Ind.text)),
          subtitle: Text(_preview(value), maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _pick(h.topic, path, value),
        ),
    ];
  }
}
