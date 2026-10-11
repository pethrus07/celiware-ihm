import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/comm/comm_error.dart';
import '../../core/rawlink/message_profile.dart';
import '../../core/theme/app_theme.dart';
import '../../models/device.dart';
import '../../models/raw_config.dart';
import '../../models/tag.dart';
import '../../services/runtime/drivers/raw_driver.dart';
import '../../services/runtime/raw_codec.dart';
import '../../widgets/common/common.dart';

/// Estado dos campos do protocolo cru no cadastro de variável — o "endereço"
/// quando o equipamento é Arduino/ESP. Fica fora do formulário para ele só
/// trocar o bloco de endereço Modbus por este, como no MQTT.
class RawTagFields {
  RawTagFields(RawAddress? a)
      : field = TextEditingController(text: a?.field ?? ''),
        command = TextEditingController(text: _commandText(a?.command)),
        validitySec = a?.validitySec ?? 0,
        binary = a?.command?.binary ?? false,
        order = a?.command?.order ?? RawByteOrder.abcd;

  final TextEditingController field;

  /// Na notação de bytes (`SET P={valor}\n`); no binário, os bytes em
  /// hexadecimal como estão.
  final TextEditingController command;
  int validitySec;
  bool binary;
  RawByteOrder order;

  static String _commandText(CommandTemplate? c) => c == null ? '' : (c.binary ? c.template : ByteEscapes.encode(c.template));

  /// O comando digitado, ou nulo (vale o do equipamento).
  CommandTemplate? get _command {
    final text = command.text.trim();
    if (text.isEmpty) return null;
    return binary ? CommandTemplate.binary(text, order: order) : CommandTemplate.text(ByteEscapes.decode(command.text));
  }

  /// Nulo enquanto o campo não for informado.
  RawAddress? build() {
    final f = field.text.trim();
    if (f.isEmpty) return null;
    return RawAddress(field: f, validitySec: validitySec, command: _command);
  }

  /// O que está valendo em "Mais opções", para o resumo fechado.
  List<String> summary({required bool writable}) => [
        if (validitySec > 0) 'validade ${validityLabel(validitySec)}',
        if (writable && binary && command.text.trim().isNotEmpty) 'comando em bytes',
      ];

  void dispose() {
    field.dispose();
    command.dispose();
  }

  static const validityOptions = [0, 5, 10, 30, 60];

  static String validityLabel(int s) => s == 0 ? 'Sem prazo' : (s >= 60 && s % 60 == 0 ? '${s ~/ 60} min' : '$s s');
}

/// Qual campo da mensagem — o que fica à vista no lugar de "Onde fica" e
/// "Endereço". O "Ouvir o equipamento" poupa adivinhar o nome do campo.
class RawAddressBlock extends StatelessWidget {
  const RawAddressBlock({super.key, required this.fields, required this.device, required this.onChanged, required this.onPick});

  final RawTagFields fields;
  final Device? device;
  final VoidCallback onChanged;
  final ValueChanged<RawPick> onPick;

  Future<void> _listen(BuildContext context) async {
    final d = device;
    if (d == null) return;
    final pick = await showRawListenSheet(context, d);
    if (pick != null) onPick(pick);
  }

  /// Exemplo de campo conforme o jeito de tirar os campos do perfil.
  static String _example(MessageProfile? p) => switch (p?.fields) {
        CsvFields(:final names) when names.any((n) => n.trim().isNotEmpty) => 'Ex.: ${names.firstWhere((n) => n.trim().isNotEmpty).trim()}',
        CsvFields() => 'A posição: 1, 2, 3…',
        BinaryFields(:final items) when items.isNotEmpty => 'Ex.: ${items.first.key}',
        RegexFields() => 'O nome do grupo da expressão',
        _ => 'Ex.: T (em T=25.3)',
      };

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextFormField(
        key: const ValueKey('campo-mensagem'),
        controller: fields.field,
        autocorrect: false,
        enableSuggestions: false,
        style: Ind.number(20),
        decoration: InputDecoration(labelText: 'Campo da mensagem', hintText: _example(device?.raw.profile)),
        validator: (v) => (v ?? '').trim().isEmpty ? 'Diga qual campo (ex.: T) — ou ouça o equipamento' : null,
        onChanged: (_) => onChanged(),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('ouvir-equipamento'),
          onPressed: device == null ? null : () => _listen(context),
          icon: const Icon(Icons.hearing_rounded),
          label: const Text('Ouvir o equipamento e escolher'),
        ),
      ),
    ]);
  }
}

/// Como gravar — aparece só quando a variável pode ser alterada pela tela.
class RawCommandField extends StatelessWidget {
  const RawCommandField({super.key, required this.fields, required this.device, required this.onChanged});

  final RawTagFields fields;
  final Device? device;
  final VoidCallback onChanged;

  /// O comando que vale quando a variável não tem o seu.
  CommandTemplate? get _fallback => device?.raw.profile.commandFor(fields.field.text.trim());

  @override
  Widget build(BuildContext context) {
    final fallback = _fallback;
    final shown = fallback == null ? null : (fallback.binary ? fallback.template : ByteEscapes.encode(fallback.template));
    return TextFormField(
      key: const ValueKey('campo-comando'),
      controller: fields.command,
      autocorrect: false,
      enableSuggestions: false,
      style: Ind.number(16, color: Ind.text),
      decoration: InputDecoration(
        labelText: 'Comando para gravar',
        hintText: shown == null ? (fields.binary ? 'Ex.: AA 01 {valor:u16}' : r'Ex.: SET {campo}={valor}\n') : 'Vazio = $shown',
        helperText: '{valor} vira o valor; {campo}, o nome do campo.',
      ),
      validator: (v) => (v ?? '').trim().isEmpty && fallback == null ? 'O equipamento não tem comando: diga qual' : null,
      onChanged: (_) => onChanged(),
    );
  }
}

/// O que é do cru em "Mais opções": validade do campo e comando em bytes.
class RawTagMoreOptions extends StatelessWidget {
  const RawTagMoreOptions({super.key, required this.fields, required this.writable, required this.onChanged});

  final RawTagFields fields;
  final bool writable;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final validity = {...RawTagFields.validityOptions, fields.validitySec}.toList()..sort();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionHeader('Validade do campo', padding: EdgeInsets.fromLTRB(0, 8, 0, 6)),
      Text('Sem este campo na mensagem nesse tempo, a variável fica "sem comunicação" — o resto da mensagem pode continuar chegando.',
          style: TextStyle(color: Ind.textDim, height: 1.35)),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in validity)
          ChoiceChip(
            key: ValueKey('validade-campo-$s'),
            label: Text(RawTagFields.validityLabel(s)),
            selected: fields.validitySec == s,
            onSelected: (_) {
              fields.validitySec = s;
              onChanged();
            },
          ),
      ]),
      if (writable) ...[
        const SizedBox(height: Ind.spaceSmall),
        SwitchListTile(
          key: const ValueKey('comando-em-bytes'),
          contentPadding: EdgeInsets.zero,
          value: fields.binary,
          onChanged: (v) {
            fields.binary = v;
            onChanged();
          },
          title: const Text('Comando em bytes (hexadecimal)'),
          subtitle: const Text('Para equipamento binário: AA 01 {valor:u16} {cs}.'),
        ),
        if (fields.binary)
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (o, text) in const [(RawByteOrder.abcd, 'Byte alto primeiro'), (RawByteOrder.dcba, 'Byte baixo primeiro (Arduino)')])
              ChoiceChip(
                key: ValueKey('ordem-comando-${o.name}'),
                label: Text(text),
                selected: fields.order == o,
                onSelected: (_) {
                  fields.order = o;
                  onChanged();
                },
              ),
          ]),
      ],
      const SizedBox(height: Ind.space),
    ]);
  }
}

// ── Ouvir o equipamento ────────────────────────────────────────────────────────

/// Campo escolhido no "Ouvir o equipamento", com o tipo que combina com o
/// valor ouvido.
class RawPick {
  const RawPick(this.field, this.type, {this.decimals = 0});
  final String field;
  final TagDataType type;

  /// Casas do valor ouvido (25.3 → 1): sem isto, o número com vírgula
  /// apareceria arredondado no "Lendo agora".
  final int decimals;

  static int decimalsOf(Object value) {
    if (value is! double) return 0;
    final s = '$value';
    final dot = s.indexOf('.');
    return dot < 0 || s.contains('e') ? 0 : (s.length - dot - 1).clamp(0, 3);
  }

  /// Nome de partida para variável sem nome: o próprio campo ("Temp"), ou
  /// "Campo 2" quando o campo é uma posição.
  String get suggestedName => int.tryParse(field) != null ? 'Campo $field' : capitalized(field.replaceAll('_', ' '));
}

Future<RawPick?> showRawListenSheet(BuildContext context, Device device) => showModalBottomSheet<RawPick>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ListenSheet(device: device),
    );

/// Ouve o equipamento por 10 s e lista os campos com o último valor; tocar
/// escolhe.
class _ListenSheet extends StatefulWidget {
  const _ListenSheet({required this.device});
  final Device device;

  @override
  State<_ListenSheet> createState() => _ListenSheetState();
}

class _ListenSheetState extends State<_ListenSheet> {
  static const _seconds = 10;
  RawHeard _heard = RawHeard();
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
      _heard = RawHeard();
      _error = null;
      _done = false;
      _left = _seconds;
    });
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _left > 0) setState(() => _left--);
    });
    try {
      await RawDriver.listen(
        widget.device,
        duration: const Duration(seconds: _seconds),
        onChange: (h) {
          if (mounted) setState(() => _heard = h);
        },
        cancelled: () => _closed,
      );
    } on CommError catch (e) {
      _error = e.userMessage;
    }
    _tick?.cancel();
    if (mounted) setState(() => _done = true);
  }

  void _pick(String field, Object value) => Navigator.pop(context, RawPick(field, RawCodec.guessType(value), decimals: RawPick.decimalsOf(value)));

  static String _preview(Object v) {
    final s = v is double ? '$v'.replaceAll('.', ',') : '$v';
    return s.length <= 60 ? s : '${s.substring(0, 60)}…';
  }

  @override
  Widget build(BuildContext context) {
    final n = _heard.fields.length;
    final status = _error != null
        ? 'Não conectou: ${_error!}'
        : _done
            ? (n == 0 ? 'Nenhum campo chegou em $_seconds s.' : '$n ${n == 1 ? 'campo' : 'campos'}. Toque no que quer usar.')
            : 'Ouvindo… $_left s · $n ${n == 1 ? 'campo' : 'campos'}';
    final bad = _heard.bad;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Ind.page, 20, Ind.page, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Ouvir o equipamento', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(status, key: const ValueKey('ouvir-status'), style: TextStyle(color: _error != null ? Ind.textFor(Ind.alarm) : Ind.textDim)),
            if (bad > 0) ...[
              const SizedBox(height: 6),
              Text(
                '$bad ${bad == 1 ? 'mensagem que o perfil não entendeu' : 'mensagens que o perfil não entendeu'} (${_heard.lastProblem!.label}). Ajuste a mensagem no cadastro do equipamento.',
                key: const ValueKey('ouvir-problemas'),
                style: TextStyle(color: Ind.textFor(Ind.warn), height: 1.35),
              ),
            ],
            if (!_done) ...[const SizedBox(height: 12), const LinearProgressIndicator()],
          ]),
        ),
        Expanded(
          child: _done && n == 0 && _error == null
              ? Padding(
                  padding: const EdgeInsets.all(Ind.page),
                  child: Text(
                    bad > 0
                        ? 'Chegou mensagem, mas o perfil não tirou nenhum campo dela.'
                        : 'O equipamento está mandando? Se ele só responde quando perguntam, escolha "O app pergunta" na mensagem do equipamento.',
                    style: TextStyle(color: Ind.textDim, height: 1.4),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(Ind.page, 4, Ind.page, 16),
                  children: [
                    for (final e in _heard.fields.entries)
                      ListTile(
                        key: ValueKey('ouvido-campo-${e.key}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(e.key, style: Ind.number(16, color: Ind.text)),
                        subtitle: Text(_preview(e.value), maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _pick(e.key, e.value),
                      ),
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
}
