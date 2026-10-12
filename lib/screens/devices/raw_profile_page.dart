import 'package:flutter/material.dart';

import '../../core/rawlink/message_parser.dart';
import '../../core/rawlink/message_profile.dart';
import '../../core/rawlink/raw_link_error.dart';
import '../../core/theme/app_theme.dart';
import '../../models/device.dart';
import '../../models/raw_config.dart';
import '../../services/runtime/drivers/raw_driver.dart' show FrameProblemText, RawDriver;
import '../../services/runtime/raw_preview.dart';
import '../../widgets/common/common.dart';

/// Editor do perfil da mensagem de um equipamento cru (RW-3), com a **prévia
/// ao vivo** presa no topo: conecta no equipamento, mostra as últimas
/// mensagens, os campos que o perfil tirou de cada uma e os problemas
/// ("checksum errado", "mensagem sem fim descartada") — e reinterpreta tudo a
/// cada mexida, sem esperar mensagem nova (ver [RawPreview]).
///
/// O caso comum é 2 ou 3 toques: escolher o modelo que parece com a mensagem
/// (chave=valor, vírgulas, binário), talvez o separador, e quem fala
/// primeiro. Delimitação, checksum, regex, comando e validade ficam em "Mais
/// opções". Devolve o perfil ao sair; o cadastro do equipamento grava no
/// Salvar dele.
class RawProfilePage extends StatefulWidget {
  const RawProfilePage({super.key, required this.device});

  /// O equipamento como está no cadastro: onde ouvir e o perfil de partida.
  final Device device;

  static Future<MessageProfile?> open(BuildContext context, Device device) =>
      Navigator.push<MessageProfile>(context, MaterialPageRoute(builder: (_) => RawProfilePage(device: device)));

  @override
  State<RawProfilePage> createState() => _RawProfilePageState();
}

class _RawProfilePageState extends State<RawProfilePage> {
  late MessageProfile _p = widget.device.raw.profile;
  late final RawPreview _preview = RawPreview(widget.device, _p);
  final _moreKey = GlobalKey();

  // Textos na notação de bytes (\n, \x02), a mesma do arquivo do projeto.
  final _names = TextEditingController();
  final _regex = TextEditingController();
  final _pollText = TextEditingController();
  final _pollMs = TextEditingController();
  final _command = TextEditingController();
  final _lineEnd = TextEditingController();
  final _start = TextEditingController();
  final _end = TextEditingController();
  final _header = TextEditingController();
  final _length = TextEditingController();
  final _adjust = TextEditingController();
  final _csSeparator = TextEditingController();
  final _csSkip = TextEditingController();
  final _maxBytes = TextEditingController();
  final List<_BinRow> _bin = [];

  static String _enc(String s) => ByteEscapes.encode(s);
  static String _dec(String s) => ByteEscapes.decode(s);

  @override
  void initState() {
    super.initState();
    _load();
    _preview.addListener(_onPreview);
    _preview.start();
  }

  void _onPreview() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _preview.removeListener(_onPreview);
    _preview.dispose();
    for (final c in [_names, _regex, _pollText, _pollMs, _command, _lineEnd, _start, _end, _header, _length, _adjust, _csSeparator, _csSkip, _maxBytes]) {
      c.dispose();
    }
    for (final r in _bin) {
      r.dispose();
    }
    super.dispose();
  }

  /// Campos de texto a partir do perfil. Os de partes que não estão em uso
  /// ganham o valor de partida delas, para trocar de opção já vir preenchido.
  void _load() {
    final p = _p;
    final f = p.framing;
    _lineEnd.text = _enc(f is LineFraming ? f.end : '\n');
    _length.text = '${f is FixedLengthFraming ? f.length : 8}';
    _header.text = _enc(switch (f) { FixedLengthFraming(:final header) || LengthPrefixFraming(:final header) => header, _ => '' });
    _start.text = _enc(f is StartEndFraming ? f.start : '\x02');
    _end.text = _enc(f is StartEndFraming ? f.end : '\x03');
    _adjust.text = '${f is LengthPrefixFraming ? f.adjust : 0}';
    final ff = p.fields;
    _names.text = ff is CsvFields ? ff.names.join(', ') : '';
    _regex.text = ff is RegexFields ? ff.pattern : r'T=(?<T>-?[\d.]+)';
    for (final r in _bin) {
      r.dispose();
    }
    _bin
      ..clear()
      ..addAll([for (final b in ff is BinaryFields ? ff.items : const <BinaryField>[]) _BinRow(b)]);
    _pollText.text = p.pollRequest.binary ? p.pollRequest.template : _enc(p.pollRequest.template);
    _pollMs.text = '${p.pollMs}';
    final cmd = _generic(p);
    _command.text = cmd == null ? '' : (cmd.binary ? cmd.template : _enc(cmd.template));
    _csSeparator.text = _enc(p.checksum.separator);
    _csSkip.text = '${p.checksum.skipStart}';
    _maxBytes.text = '${p.maxFrameBytes}';
  }

  /// Troca o perfil e reinterpreta a prévia na hora.
  void _set(MessageProfile p, {bool reload = false}) {
    setState(() {
      _p = p;
      if (reload) _load();
    });
    _preview.profile = p;
  }

  /// O comando "para qualquer campo" (sem chave e sem nome) — o que o cadastro
  /// mostra. Comandos com nome ("Zerar") vindos do arquivo ficam como estão.
  static CommandTemplate? _generic(MessageProfile p) => p.commands.where((c) => c.field.isEmpty && c.name.isEmpty).firstOrNull;

  // ── Mudanças ─────────────────────────────────────────────────────────────────

  /// Modelo pronto: troca o jeito de achar e tirar os campos; quem fala
  /// primeiro, validade e o comando que já existia continuam.
  void _applyTemplate(RawTemplate t) => _set(
        _p.copyWith(
          framing: t.profile.framing,
          checksum: t.profile.checksum,
          fields: t.profile.fields,
          commands: _p.commands.isEmpty ? t.profile.commands : _p.commands,
        ),
        reload: true,
      );

  void _setFraming(_Framing kind) {
    final FrameSpec f = switch (kind) {
      _Framing.line => LineFraming(end: _dec(_lineEnd.text)),
      _Framing.fixed => FixedLengthFraming(length: int.tryParse(_length.text) ?? 8, header: _dec(_header.text)),
      _Framing.startEnd => StartEndFraming(start: _dec(_start.text), end: _dec(_end.text)),
      _Framing.lengthPrefix => LengthPrefixFraming(header: _dec(_header.text), adjust: int.tryParse(_adjust.text) ?? 0),
    };
    // Checksum depois do fim só existe com marcadores de início e fim.
    final cs = f is StartEndFraming ? _p.checksum : _checksum(afterEnd: false);
    _set(_p.copyWith(framing: f, checksum: cs));
  }

  /// A delimitação atual com os textos dos campos.
  void _framingEdited({int? lengthBytes, bool? bigEndian, bool? trimCr}) {
    final f = _p.framing;
    _set(_p.copyWith(
      framing: switch (f) {
        LineFraming() => LineFraming(end: _dec(_lineEnd.text), trimCr: trimCr ?? f.trimCr),
        FixedLengthFraming() => FixedLengthFraming(length: int.tryParse(_length.text) ?? 0, header: _dec(_header.text)),
        StartEndFraming() => StartEndFraming(start: _dec(_start.text), end: _dec(_end.text)),
        LengthPrefixFraming() => LengthPrefixFraming(
            header: _dec(_header.text),
            lengthBytes: lengthBytes ?? f.lengthBytes,
            bigEndian: bigEndian ?? f.bigEndian,
            adjust: int.tryParse(_adjust.text) ?? 0,
          ),
      },
    ));
  }

  ChecksumSpec _checksum({ChecksumKind? kind, ChecksumEncoding? encoding, bool? afterEnd, bool? lowByteFirst}) {
    final c = _p.checksum;
    return ChecksumSpec(
      kind: kind ?? c.kind,
      encoding: encoding ?? c.encoding,
      separator: _dec(_csSeparator.text),
      skipStart: int.tryParse(_csSkip.text) ?? 0,
      afterEnd: afterEnd ?? c.afterEnd,
      lowByteFirst: lowByteFirst ?? c.lowByteFirst,
    );
  }

  void _setFields(_Format kind) {
    final FieldFormat f = switch (kind) {
      _Format.keyValue => const KeyValueFields(),
      _Format.csv => CsvFields(names: _namesList()),
      _Format.regex => RegexFields(_regex.text),
      _Format.binary => BinaryFields(_bin.isEmpty ? const [BinaryField(key: 'valor1', offset: 0)] : _binItems()),
    };
    _set(_p.copyWith(fields: f), reload: kind == _Format.binary && _bin.isEmpty);
  }

  /// Nome vazio no meio vale a posição ("temp, , estado" → temp, 2, estado).
  List<String> _namesList() {
    final names = [for (final n in _names.text.split(',')) n.trim()];
    return names.every((n) => n.isEmpty) ? const [] : names;
  }

  List<BinaryField> _binItems() => [
        for (final r in _bin) BinaryField(key: r.key.text.trim(), offset: int.tryParse(r.offset.text) ?? 0, type: r.type, order: r.order),
      ];

  void _binEdited() => _set(_p.copyWith(fields: BinaryFields(_binItems())));

  void _addBin() {
    final last = _binItems().lastOrNull;
    final next = last == null ? 0 : last.offset + last.type.size;
    setState(() => _bin.add(_BinRow(BinaryField(key: 'valor${_bin.length + 1}', offset: next, order: last?.order ?? RawByteOrder.abcd))));
    _binEdited();
  }

  void _removeBin(_BinRow r) {
    setState(() => _bin.remove(r));
    r.dispose();
    _binEdited();
  }

  /// Pedido do polling a partir do texto (bytes em hexadecimal se o pedido
  /// já era binário).
  CommandTemplate _pollRequest() =>
      _p.pollRequest.binary ? CommandTemplate.binary(_pollText.text.trim()) : CommandTemplate.text(_dec(_pollText.text));

  void _commandEdited({bool? binary, RawByteOrder? order}) {
    final old = _generic(_p);
    final isBinary = binary ?? old?.binary ?? false;
    final text = _command.text.trim();
    final CommandTemplate? cmd = text.isEmpty
        ? null
        : isBinary
            ? CommandTemplate.binary(text, order: order ?? old?.order ?? RawByteOrder.abcd)
            : CommandTemplate.text(_dec(_command.text));
    final others = [for (final c in _p.commands) if (!identical(c, old)) c];
    _set(_p.copyWith(commands: [?cmd, ...others]));
  }

  // ── Sair ─────────────────────────────────────────────────────────────────────

  /// O que impede o perfil de funcionar (inclusive o pedido do polling que
  /// não monta, que só o interpretador descobre).
  List<String> _blocking() {
    final out = _p.problems();
    if (out.isNotEmpty) return out;
    try {
      MessageParser(_p);
    } on RawProfileError catch (e) {
      return [e.message];
    }
    return const [];
  }

  Future<void> _finish() async {
    final problems = _blocking();
    if (problems.isEmpty) {
      Navigator.pop(context, _p);
      return;
    }
    final back = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('O perfil não fecha'),
        content: Text('${capitalized(problems.first)}. Sair agora volta ao perfil de antes.', style: const TextStyle(height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Voltar ao anterior')),
          FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Continuar editando')),
        ],
      ),
    );
    if (back == true && mounted) Navigator.pop(context);
  }

  // ── Tela ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mensagem do equipamento'),
          actions: [TextButton(key: const ValueKey('concluir-perfil'), onPressed: _finish, child: const Text('Concluir'))],
        ),
        body: Column(children: [
          // Prévia presa no topo: é a resposta a cada opção mexida lá embaixo.
          Padding(
            padding: const EdgeInsets.fromLTRB(Ind.page, 12, Ind.page, 8),
            child: _PreviewPanel(preview: _preview, where: RawDriver.labelFor(d)),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
              children: [
                const SectionHeader('Como a mensagem chega', padding: EdgeInsets.fromLTRB(0, 20, 0, 10)),
                _templates(),
                ..._formatEssentials(),
                const SectionHeader('Quem fala primeiro', padding: EdgeInsets.fromLTRB(0, 24, 0, 10)),
                _mode(),
                const SizedBox(height: Ind.spaceSmall),
                _more(),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: Ind.space, bottom: 8),
        child: Text(text, style: TextStyle(color: Ind.textDim, fontWeight: FontWeight.w600)),
      );

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text, style: TextStyle(color: Ind.textMuted, fontSize: 12.5, height: 1.35)),
      );

  /// Chips de escolha; o valor atual fora das opções aparece como mais um.
  Widget _chips<T>(String keyPrefix, List<(T, String)> options, T selected, ValueChanged<T> onSelected, {String Function(T)? keyOf}) {
    final all = [...options, if (!options.any((o) => o.$1 == selected)) (selected, '$selected')];
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final (v, text) in all)
        ChoiceChip(
          key: ValueKey('$keyPrefix-${keyOf?.call(v) ?? v}'),
          label: Text(text),
          selected: v == selected,
          onSelected: (_) => onSelected(v),
        ),
    ]);
  }

  Widget _templates() {
    final current = RawTemplates.of(_p);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final t in RawTemplates.all)
          ChoiceChip(
            key: ValueKey('modelo-${t.id}'),
            label: Text(t.name),
            selected: identical(current, t),
            onSelected: (_) {
              if (!identical(current, t)) _applyTemplate(t);
            },
          ),
      ]),
      _hint(current == null ? 'Mensagem própria: os campos saem da expressão regular (em "Mais opções").' : 'Ex.: ${current.example}'),
    ]);
  }

  /// O essencial de cada jeito de tirar os campos.
  List<Widget> _formatEssentials() {
    switch (_p.fields) {
      case KeyValueFields(:final pairSeparator, :final assign):
        return [
          _label('Separa um campo do outro'),
          _chips<String>('par', const [(';', ';'), (',', ','), ('&', '&'), (' ', 'espaço'), ('\t', 'tab')], pairSeparator,
              (v) => _set(_p.copyWith(fields: KeyValueFields(pairSeparator: v, assign: assign))), keyOf: _enc),
          _label('Separa o nome do valor'),
          _chips<String>('atribuicao', const [('=', '='), (':', ':')], assign,
              (v) => _set(_p.copyWith(fields: KeyValueFields(pairSeparator: pairSeparator, assign: v))), keyOf: _enc),
        ];
      case CsvFields(:final separator, :final quote):
        return [
          _label('Separador'),
          _chips<String>('separador', const [(',', ','), (';', ';'), ('\t', 'tab'), (' ', 'espaço'), ('|', '|')], separator,
              (v) => _set(_p.copyWith(fields: CsvFields(separator: v, quote: quote, names: _namesList()))), keyOf: _enc),
          const SizedBox(height: Ind.space),
          TextFormField(
            key: const ValueKey('nomes-campos'),
            controller: _names,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Nomes dos campos (opcional)',
              hintText: 'Ex.: temp, bomba, estado',
              helperText: 'Na ordem em que chegam. Sem nome, o campo é a posição: 1, 2, 3…',
              helperMaxLines: 2,
            ),
            onChanged: (_) => _set(_p.copyWith(fields: CsvFields(separator: separator, quote: quote, names: _namesList()))),
          ),
        ];
      case BinaryFields():
        return _binaryEssentials();
      case RegexFields():
        return [
          const SizedBox(height: Ind.space),
          _regexField(),
        ];
    }
  }

  Widget _regexField() => TextFormField(
        key: const ValueKey('campo-regex'),
        controller: _regex,
        autocorrect: false,
        enableSuggestions: false,
        style: Ind.number(15, color: Ind.text),
        decoration: const InputDecoration(
          labelText: 'Expressão regular',
          helperText: 'Cada grupo com nome vira um campo: T=(?<temp>[\\d.]+) dá o campo "temp".',
          helperMaxLines: 2,
        ),
        onChanged: (t) => _set(_p.copyWith(fields: RegexFields(t))),
      );

  /// Binário: o pacote (tamanho e cabeçalho) e um campo por linha.
  List<Widget> _binaryEssentials() {
    final f = _p.framing;
    return [
      if (f is FixedLengthFraming) ...[
        const SizedBox(height: Ind.space),
        StepperField(fieldKey: const ValueKey('tamanho-pacote'), label: 'Tamanho do pacote (bytes)', controller: _length, min: 1, max: 65536, onChanged: _framingEdited),
        const SizedBox(height: Ind.space),
        _headerField(),
      ],
      _label('Campos (byte contado do começo do pacote)'),
      for (final (i, r) in _bin.indexed) ...[
        if (i > 0) const SizedBox(height: 12),
        _BinRowEditor(key: ObjectKey(r), row: r, onChanged: _binEdited, onRemove: () => _removeBin(r)),
      ],
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(key: const ValueKey('acrescentar-campo'), onPressed: _addBin, icon: const Icon(Icons.add_rounded), label: const Text('Acrescentar campo')),
      ),
    ];
  }

  Widget _headerField() => TextFormField(
        key: const ValueKey('cabecalho'),
        controller: _header,
        autocorrect: false,
        style: Ind.number(15, color: Ind.text),
        decoration: const InputDecoration(labelText: 'Cabeçalho', hintText: r'Ex.: \xAA\x55', helperText: 'Os bytes fixos do começo — é por eles que o app se acha depois de um byte perdido.', helperMaxLines: 2),
        onChanged: (_) => _framingEdited(),
      );

  Widget _mode() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _chips<RawMode>('modo', const [(RawMode.streaming, 'O equipamento manda sozinho'), (RawMode.polling, 'O app pergunta')], _p.mode,
            (m) => _set(_p.copyWith(mode: m, pollRequest: _pollRequest())), keyOf: (m) => m.name),
        if (_p.mode == RawMode.polling) ...[
          const SizedBox(height: Ind.space),
          TextFormField(
            key: const ValueKey('pergunta'),
            controller: _pollText,
            autocorrect: false,
            style: Ind.number(15, color: Ind.text),
            decoration: InputDecoration(
              labelText: 'Pergunta',
              helperText: _p.pollRequest.binary ? 'Bytes em hexadecimal: 01 03 {cs}' : r'O que o app manda. \n = fim de linha.',
            ),
            onChanged: (_) => _set(_p.copyWith(pollRequest: _pollRequest())),
          ),
          const SizedBox(height: Ind.space),
          StepperField(
            fieldKey: const ValueKey('perguntar-a-cada'),
            label: 'Perguntar a cada (ms)',
            controller: _pollMs,
            min: 20,
            max: 600000,
            onChanged: () => _set(_p.copyWith(pollMs: int.tryParse(_pollMs.text) ?? _p.pollMs)),
          ),
        ],
      ]);

  // ── Mais opções ──────────────────────────────────────────────────────────────

  String _moreSummary() {
    final f = _p.framing;
    final cmd = _generic(_p);
    return [
      switch (f) {
        LineFraming(:final end) => 'fim ${_enc(end)}',
        FixedLengthFraming(:final length) => 'pacote de $length bytes',
        StartEndFraming(:final start, :final end) => 'entre ${_enc(start)} e ${_enc(end)}',
        LengthPrefixFraming() => 'tamanho no começo',
      },
      _p.checksum.enabled ? 'checksum ${_checksumName(_p.checksum.kind)}' : 'sem checksum',
      cmd == null ? 'sem comando' : 'comando ${cmd.binary ? cmd.template : _enc(cmd.template)}',
      'validade ${_staleLabel(_p.staleAfterMs)}',
    ].join(' · ');
  }

  static String _checksumName(ChecksumKind k) => switch (k) {
        ChecksumKind.none => 'nenhum',
        ChecksumKind.xor => 'XOR',
        ChecksumKind.sum8 => 'soma',
        ChecksumKind.crc16 => 'CRC16',
      };

  static String _staleLabel(int ms) => ms <= 0 ? 'sem prazo' : (ms % 1000 == 0 ? '${ms ~/ 1000} s' : '$ms ms');

  Widget _more() => Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: _moreKey,
          onExpansionChanged: (open) => revealAfterExpand(_moreKey, open),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          title: const Text('Mais opções'),
          subtitle: Text(_moreSummary(), style: TextStyle(color: Ind.textMuted, fontSize: 13)),
          children: [
            ..._framingOptions(),
            ..._checksumOptions(),
            _label('Jeito de tirar os campos'),
            _chips<_Format>('formato', const [(_Format.keyValue, 'chave=valor'), (_Format.csv, 'vírgulas'), (_Format.regex, 'regex'), (_Format.binary, 'binário')],
                _Format.of(_p.fields), _setFields, keyOf: (f) => f.name),
            if (_p.fields is RegexFields) ...[const SizedBox(height: Ind.space), _hint('A expressão fica à vista lá em cima.')],
            ..._commandOptions(),
            _label('Sem mensagem por'),
            _chips<int>('validade', const [(2000, '2 s'), (5000, '5 s'), (10000, '10 s'), (30000, '30 s'), (0, 'Sem prazo')], _p.staleAfterMs,
                (ms) => _set(_p.copyWith(staleAfterMs: ms))),
            _hint('Sem mensagem nesse tempo, as variáveis do equipamento ficam "sem comunicação".'),
            _label('Letras'),
            _chips<RawCharset>('letras', const [(RawCharset.utf8, 'UTF-8 (Arduino)'), (RawCharset.latin1, 'Latin-1 (antigo)')], _p.charset,
                (c) => _set(_p.copyWith(charset: c)), keyOf: (c) => c.name),
            SwitchListTile(
              key: const ValueKey('virgula-decimal'),
              contentPadding: EdgeInsets.zero,
              value: _p.decimalComma,
              onChanged: (v) => _set(_p.copyWith(decimalComma: v)),
              title: const Text('Número com vírgula (25,3)'),
              subtitle: const Text('Balança brasileira. Não combina com campos separados por vírgula.'),
            ),
            const SizedBox(height: Ind.spaceSmall),
            StepperField(
              label: 'Mensagem de no máximo (bytes)',
              controller: _maxBytes,
              min: 8,
              max: 65536,
              helper: 'Passou disso sem terminar, é descartada (fim de linha errado, velocidade trocada).',
              onChanged: () => _set(_p.copyWith(maxFrameBytes: int.tryParse(_maxBytes.text) ?? _p.maxFrameBytes)),
            ),
          ],
        ),
      );

  List<Widget> _framingOptions() {
    final f = _p.framing;
    return [
      _label('Onde a mensagem termina'),
      _chips<_Framing>('fim', const [(_Framing.line, 'Fim de linha'), (_Framing.fixed, 'Tamanho fixo'), (_Framing.startEnd, 'Início e fim'), (_Framing.lengthPrefix, 'Tamanho no começo')],
          _Framing.of(f), _setFraming, keyOf: (k) => k.name),
      const SizedBox(height: Ind.space),
      ...switch (f) {
        LineFraming() => [
            _bytesField('fim-linha', _lineEnd, 'Fim da mensagem', r'\n = fim de linha; \r\n, ; ou \x03 também servem.'),
          ],
        FixedLengthFraming() => [
            if (_p.fields is! BinaryFields) ...[
              StepperField(label: 'Tamanho (bytes)', controller: _length, min: 1, max: 65536, onChanged: _framingEdited),
              const SizedBox(height: Ind.space),
              _headerField(),
            ] else
              _hint('Tamanho e cabeçalho ficam à vista, junto dos campos.'),
          ],
        StartEndFraming() => [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _bytesField('inicio', _start, 'Início', r'Ex.: \x02 ou <')),
              const SizedBox(width: 12),
              Expanded(child: _bytesField('fim', _end, 'Fim', r'Ex.: \x03 ou >')),
            ]),
          ],
        LengthPrefixFraming(:final lengthBytes, :final bigEndian) => [
            _headerField(),
            _label('O tamanho ocupa'),
            _chips<int>('bytes-tamanho', const [(1, '1 byte'), (2, '2 bytes')], lengthBytes, (n) => _framingEdited(lengthBytes: n)),
            if (lengthBytes == 2) ...[
              const SizedBox(height: 8),
              _chips<bool>('ordem-tamanho', const [(true, 'Byte alto primeiro'), (false, 'Byte baixo primeiro')], bigEndian, (b) => _framingEdited(bigEndian: b)),
            ],
            const SizedBox(height: Ind.space),
            StepperField(
              label: 'Ajuste do tamanho',
              controller: _adjust,
              min: -255,
              max: 255,
              helper: 'Bytes depois do tamanho = valor + ajuste. Conta só os dados e há 1 byte de checksum depois: 1.',
              onChanged: _framingEdited,
            ),
          ],
      },
    ];
  }

  Widget _bytesField(String key, TextEditingController c, String label, String helper) => TextFormField(
        key: ValueKey(key),
        controller: c,
        autocorrect: false,
        style: Ind.number(15, color: Ind.text),
        decoration: InputDecoration(labelText: label, helperText: helper, helperMaxLines: 2),
        onChanged: (_) => _framingEdited(),
      );

  List<Widget> _checksumOptions() {
    final cs = _p.checksum;
    return [
      _label('Checksum'),
      _chips<ChecksumKind>('checksum', const [(ChecksumKind.none, 'Nenhum'), (ChecksumKind.xor, 'XOR (BCC)'), (ChecksumKind.sum8, 'Soma 8 bits'), (ChecksumKind.crc16, 'CRC16')],
          cs.kind, (k) => _set(_p.copyWith(checksum: _checksum(kind: k))), keyOf: (k) => k.name),
      if (cs.enabled) ...[
        const SizedBox(height: 8),
        _chips<ChecksumEncoding>('checksum-escrita', const [(ChecksumEncoding.hex, 'Em hexadecimal (texto)'), (ChecksumEncoding.binary, 'Bytes crus')], cs.encoding,
            (e) => _set(_p.copyWith(checksum: _checksum(encoding: e))), keyOf: (e) => e.name),
        const SizedBox(height: Ind.space),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextFormField(
              controller: _csSeparator,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Separador antes', hintText: 'Ex.: *'),
              onChanged: (_) => _set(_p.copyWith(checksum: _checksum())),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              controller: _csSkip,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Ignora no começo', hintText: 'bytes'),
              onChanged: (_) => _set(_p.copyWith(checksum: _checksum())),
            ),
          ),
        ]),
        _hint(r'Fica no fim da mensagem e cobre o que vem antes. NMEA ($...*hh): separador * e ignora 1.'),
        if (_p.framing is StartEndFraming)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: cs.afterEnd,
            onChanged: (v) => _set(_p.copyWith(checksum: _checksum(afterEnd: v))),
            title: const Text('Depois do marcador de fim'),
            subtitle: const Text('O BCC de balança: STX … ETX e o checksum logo depois.'),
          ),
        if (cs.kind == ChecksumKind.crc16 && cs.encoding == ChecksumEncoding.binary)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: cs.lowByteFirst,
            onChanged: (v) => _set(_p.copyWith(checksum: _checksum(lowByteFirst: v))),
            title: const Text('Byte baixo primeiro'),
            subtitle: const Text('Como no Modbus RTU.'),
          ),
      ],
    ];
  }

  List<Widget> _commandOptions() {
    final cmd = _generic(_p);
    final binary = cmd?.binary ?? false;
    return [
      _label('Comando para gravar'),
      TextFormField(
        key: const ValueKey('comando-perfil'),
        controller: _command,
        autocorrect: false,
        enableSuggestions: false,
        style: Ind.number(15, color: Ind.text),
        decoration: InputDecoration(
          hintText: binary ? 'Ex.: AA 01 {valor:u16} {cs}' : r'Ex.: SET {campo}={valor}\n',
          helperText: '{campo} vira o nome do campo e {valor} o valor. Vazio = o equipamento não recebe comando (cada variável pode ter o seu).',
          helperMaxLines: 3,
        ),
        onChanged: (_) => _commandEdited(),
      ),
      SwitchListTile(
        key: const ValueKey('comando-binario'),
        contentPadding: EdgeInsets.zero,
        value: binary,
        onChanged: (v) => _commandEdited(binary: v),
        title: const Text('Comando em bytes (hexadecimal)'),
      ),
      if (binary) _chips<RawByteOrder>('ordem-comando', _orders, cmd?.order ?? RawByteOrder.abcd, (o) => _commandEdited(order: o), keyOf: (o) => o.name),
    ];
  }
}

const List<(RawByteOrder, String)> _orders = [
  (RawByteOrder.abcd, 'Byte alto primeiro'),
  (RawByteOrder.dcba, 'Byte baixo primeiro (Arduino)'),
  (RawByteOrder.cdab, 'CDAB'),
  (RawByteOrder.badc, 'BADC'),
];

enum _Framing {
  line,
  fixed,
  startEnd,
  lengthPrefix;

  static _Framing of(FrameSpec f) => switch (f) {
        LineFraming() => line,
        FixedLengthFraming() => fixed,
        StartEndFraming() => startEnd,
        LengthPrefixFraming() => lengthPrefix,
      };
}

enum _Format {
  keyValue,
  csv,
  regex,
  binary;

  static _Format of(FieldFormat f) => switch (f) {
        KeyValueFields() => keyValue,
        CsvFields() => csv,
        RegexFields() => regex,
        BinaryFields() => binary,
      };
}

/// Um campo binário em edição.
class _BinRow {
  _BinRow(BinaryField f)
      : key = TextEditingController(text: f.key),
        offset = TextEditingController(text: '${f.offset}'),
        type = f.type,
        order = f.order;

  final TextEditingController key;
  final TextEditingController offset;
  RawType type;
  RawByteOrder order;

  void dispose() {
    key.dispose();
    offset.dispose();
  }
}

class _BinRowEditor extends StatelessWidget {
  const _BinRowEditor({super.key, required this.row, required this.onChanged, required this.onRemove});

  final _BinRow row;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(color: Ind.surfaceHigh, borderRadius: BorderRadius.circular(Ind.radiusSmall)),
        child: Column(children: [
          Row(children: [
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: row.key,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Nome'),
                onChanged: (_) => onChanged(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: TextFormField(
                controller: row.offset,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Byte'),
                onChanged: (_) => onChanged(),
              ),
            ),
            IconButton(tooltip: 'Tirar', onPressed: onRemove, icon: const Icon(Icons.close_rounded)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<RawType>(
                initialValue: row.type,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Tipo'),
                items: [for (final t in RawType.values) DropdownMenuItem(value: t, child: Text(_typeLabel(t)))],
                onChanged: (t) {
                  if (t == null) return;
                  row.type = t;
                  onChanged();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<RawByteOrder>(
                initialValue: row.order,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Ordem'),
                items: [for (final (o, text) in _orders) DropdownMenuItem(value: o, child: Text(text, overflow: TextOverflow.ellipsis))],
                onChanged: (o) {
                  if (o == null) return;
                  row.order = o;
                  onChanged();
                },
              ),
            ),
            const SizedBox(width: 44),
          ]),
        ]),
      );

  static String _typeLabel(RawType t) => switch (t) {
        RawType.u8 => '8 bits',
        RawType.i8 => '8 bits c/ sinal',
        RawType.u16 => '16 bits',
        RawType.i16 => '16 bits c/ sinal',
        RawType.u32 => '32 bits',
        RawType.i32 => '32 bits c/ sinal',
        RawType.f32 => 'Com vírgula (float)',
      };
}

// ── Prévia ─────────────────────────────────────────────────────────────────────

/// A prévia ao vivo: estado da conexão e as últimas mensagens (a mais nova em
/// cima), cada uma com os campos tirados ou o problema.
class _PreviewPanel extends StatelessWidget {
  const _PreviewPanel({required this.preview, required this.where});

  final RawPreview preview;
  final String where;

  @override
  Widget build(BuildContext context) {
    final p = preview;
    final (icon, color, status) = switch (p.state) {
      RawPreviewLink.connecting => (Icons.sync_rounded, Ind.warn, 'Conectando a $where…'),
      RawPreviewLink.failed => (Icons.error_rounded, Ind.alarm, 'Não conectou: ${p.error}'),
      RawPreviewLink.connected => p.heardAnything
          ? (Icons.sensors_rounded, Ind.ok, 'Ao vivo · $where')
          : (Icons.hourglass_empty_rounded, Ind.textMuted, 'Conectado · esperando mensagem'),
    };
    final frames = p.frames.reversed.take(6).toList();
    return Container(
      key: const ValueKey('previa-perfil'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: Ind.bg,
        borderRadius: BorderRadius.circular(Ind.radius),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text('PRÉVIA AO VIVO', style: Ind.tag(size: 10.5, color: Ind.textMuted))),
          if (p.state == RawPreviewLink.failed)
            TextButton(key: const ValueKey('previa-tentar'), onPressed: p.start, child: const Text('Tentar de novo')),
        ]),
        const SizedBox(height: 2),
        Text(status, key: const ValueKey('previa-status'), style: TextStyle(color: Ind.textFor(color), fontWeight: FontWeight.w600)),
        if (p.problems.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final m in p.problems.take(3))
            Text('O perfil não fecha: $m', style: TextStyle(color: Ind.textFor(Ind.alarm), height: 1.35)),
        ] else if (frames.isNotEmpty) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.28),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final (i, f) in frames.indexed) ...[
                  if (i > 0) Divider(height: 14, color: Ind.line),
                  _FrameRow(frame: f, index: i),
                ],
              ],
            ),
          ),
        ] else if (p.state == RawPreviewLink.connected && !p.heardAnything && p.isDatagram) ...[
          const SizedBox(height: 6),
          Text('UDP: o equipamento precisa mandar para este celular. Se ele manda sozinho, fixe a "Porta deste celular" no cadastro; se responde a quem pergunta, escolha "O app pergunta".',
              style: TextStyle(color: Ind.textMuted, fontSize: 12.5, height: 1.35)),
        ],
      ]),
    );
  }
}

class _FrameRow extends StatelessWidget {
  const _FrameRow({required this.frame, required this.index});

  final RawFrame frame;
  final int index;

  /// Número em pt-BR, texto entre aspas: mostra o que o perfil achou que é
  /// número ("25,3") e o que ficou texto ("25.3C").
  static String _value(Object v) => switch (v) {
        double d => '$d'.replaceAll('.', ','),
        String s => '"$s"',
        _ => '$v',
      };

  @override
  Widget build(BuildContext context) => Column(
        key: ValueKey('previa-msg-$index'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(frame.preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: Ind.number(12.5, color: Ind.textMuted)),
          const SizedBox(height: 2),
          if (frame.ok)
            Text(
              frame.fields.entries.map((e) => '${e.key} = ${_value(e.value)}').join('  ·  '),
              key: ValueKey('previa-campos-$index'),
              style: TextStyle(color: Ind.text, fontWeight: FontWeight.w600),
            )
          else
            Row(children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: Ind.textFor(Ind.alarm)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(frame.problem!.label, key: ValueKey('previa-problema-$index'), style: TextStyle(color: Ind.textFor(Ind.alarm), fontWeight: FontWeight.w600)),
              ),
            ]),
        ],
      );
}
