import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/device.dart';
import '../../models/http_config.dart';
import '../../models/mqtt_config.dart' show MqttBoolFormat;
import '../../models/tag.dart';
import '../../services/runtime/drivers/http_driver.dart';
import '../../services/runtime/tag_codec.dart';
import '../../widgets/common/common.dart';

/// Estado da requisição no cadastro de variável — o "endereço" quando o
/// equipamento é HTTP: método, caminho, corpo, onde está o valor na resposta
/// e o comando para gravar. Fica fora do formulário para ele só trocar o
/// bloco de endereço Modbus por este, como faz com o OPC UA.
class HttpTagFields {
  HttpTagFields(HttpTagAddress? a)
      : method = a?.method ?? HttpMethod.get,
        extract = a?.extract ?? HttpExtract.json,
        writeMethod = a?.writeMethod ?? HttpMethod.post,
        boolFormat = a?.boolFormat ?? MqttBoolFormat.oneZero,
        path = TextEditingController(text: a?.path ?? ''),
        body = TextEditingController(text: a?.body ?? ''),
        select = TextEditingController(text: a?.select ?? ''),
        writePath = TextEditingController(text: a?.writePath ?? ''),
        writeBody = TextEditingController(text: a?.writeBody ?? '');

  HttpMethod method;
  HttpExtract extract;
  HttpMethod writeMethod;
  MqttBoolFormat boolFormat;
  final TextEditingController path;
  final TextEditingController body;
  final TextEditingController select;
  final TextEditingController writePath;
  final TextEditingController writeBody;

  HttpTagAddress build() => HttpTagAddress(
        method: method,
        path: path.text.trim(),
        body: method.hasBody ? body.text : '',
        extract: extract,
        select: extract == HttpExtract.regex ? select.text : select.text.trim(),
        writeMethod: writeMethod,
        writePath: writePath.text.trim(),
        writeBody: writeBody.text,
        boolFormat: boolFormat,
      );

  /// O que está errado na leitura, curto. Nulo = certo.
  String? error() => build().problem;

  void dispose() {
    for (final c in [path, body, select, writePath, writeBody]) {
      c.dispose();
    }
  }
}

/// Campo escolhido na resposta do "Testar": o caminho JSON, o tipo que
/// combina com o valor e as casas decimais dele.
class HttpPick {
  const HttpPick({required this.path, required this.type, this.decimals = 0});
  final String path;
  final TagDataType type;
  final int decimals;

  /// Nome de partida: a última parte do caminho ("data.temperatura" →
  /// "Temperatura"; "itens.0.valor" → "Valor").
  String get suggestedName {
    final parts = path.split('.').where((p) => p.isNotEmpty && int.tryParse(p) == null).toList();
    return capitalized((parts.isEmpty ? path : parts.last).replaceAll('_', ' '));
  }
}

/// A requisição no lugar de "Onde fica" do Modbus: método, caminho (com a
/// URL inteira embaixo, como prova), corpo no POST, onde está o valor na
/// resposta e o **Testar**, que mostra o código, o tempo e o valor tirado —
/// e, numa resposta JSON, os campos para escolher com um toque.
class HttpAddressBlock extends StatefulWidget {
  const HttpAddressBlock({super.key, required this.fields, required this.device, required this.draft, required this.onChanged, required this.onPick});

  final HttpTagFields fields;
  final Device? device;

  /// A variável como está no formulário (tipo e escala valem no Testar).
  final Tag Function() draft;
  final VoidCallback onChanged;
  final ValueChanged<HttpPick> onPick;

  @override
  State<HttpAddressBlock> createState() => _HttpAddressBlockState();
}

class _HttpAddressBlockState extends State<HttpAddressBlock> {
  HttpTestResult? _result;
  bool _testing = false;

  void _changed([VoidCallback? fn]) {
    setState(() {
      fn?.call();
      _result = null;
    });
    widget.onChanged();
  }

  Future<void> _test() async {
    final d = widget.device;
    if (d == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _testing = true;
      _result = null;
    });
    final r = await HttpDriver.test(d, widget.draft());
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.fields;
    final d = widget.device;
    final error = f.error();
    String? url;
    try {
      url = d?.http.resolve(d.host, d.port, f.path.text).toString();
    } on FormatException {
      url = null; // caminho com caractere que não cabe numa URL: o erro aparece no Testar
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final m in const [HttpMethod.get, HttpMethod.post])
          ChoiceChip(key: ValueKey('http-metodo-${m.name}'), label: Text(m.verb), selected: f.method == m, onSelected: (_) => _changed(() => f.method = m)),
      ]),
      const SizedBox(height: Ind.space),
      TextFormField(
        key: const ValueKey('campo-caminho-http'),
        controller: f.path,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.url,
        style: Ind.number(18),
        decoration: InputDecoration(
          labelText: 'Caminho',
          hintText: '/api/status',
          helperText: error == null ? url : null,
          helperMaxLines: 2,
          errorText: error != null && f.path.text.trim().isNotEmpty && f.extract == HttpExtract.json ? error : null,
          errorMaxLines: 3,
        ),
        onChanged: (_) => _changed(),
      ),
      if (f.method.hasBody) ...[
        const SizedBox(height: Ind.space),
        TextFormField(
          key: const ValueKey('campo-corpo-http'),
          controller: f.body,
          minLines: 1,
          maxLines: 4,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Corpo do pedido', hintText: '{"canal": 1}'),
          onChanged: (_) => _changed(),
        ),
      ],
      const SectionHeader('Onde está o valor', padding: EdgeInsets.fromLTRB(0, 20, 0, 8)),
      Wrap(spacing: 8, runSpacing: 8, children: [
        ChoiceChip(key: const ValueKey('http-seletor-json'), label: const Text('Campo do JSON'), selected: f.extract == HttpExtract.json, onSelected: (_) => _changed(() => f.extract = HttpExtract.json)),
        ChoiceChip(key: const ValueKey('http-seletor-regex'), label: const Text('Expressão regular'), selected: f.extract == HttpExtract.regex, onSelected: (_) => _changed(() => f.extract = HttpExtract.regex)),
      ]),
      const SizedBox(height: Ind.space),
      TextFormField(
        key: const ValueKey('campo-seletor-http'),
        controller: f.select,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.visiblePassword,
        style: Ind.number(16),
        decoration: InputDecoration(
          labelText: f.extract == HttpExtract.json ? 'Campo' : 'Expressão regular',
          hintText: f.extract == HttpExtract.json ? 'data.temperatura' : r'T=(?<valor>[\d.]+)',
          helperText: f.extract == HttpExtract.json ? 'Ex.: itens[0].valor. Vazio = a resposta inteira.' : 'Vale o grupo (?<valor>…), senão o primeiro grupo.',
          helperMaxLines: 2,
          errorText: f.extract == HttpExtract.regex && f.select.text.isNotEmpty ? error : null,
          errorMaxLines: 3,
        ),
        onChanged: (_) => _changed(),
      ),
      const SizedBox(height: Ind.space),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const ValueKey('testar-http'),
          onPressed: _testing || d == null || error != null ? null : _test,
          icon: _testing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow_rounded),
          label: Text(_testing ? 'Testando…' : 'Testar'),
        ),
      ),
      // Escolher um campo testa de novo: o cartão passa a mostrar o valor tirado
      // em vez do aviso antigo ("diga qual campo ler"), que já foi resolvido.
      if (_result != null) ...[
        const SizedBox(height: 12),
        _TestCard(
          result: _result!,
          tag: widget.draft(),
          onPick: (p) {
            widget.onPick(p);
            Future.microtask(_test);
          },
        ),
      ],
    ]);
  }
}

/// O resultado do Testar: código e tempo, o valor tirado (ou por que não) e
/// os campos da resposta JSON.
class _TestCard extends StatelessWidget {
  const _TestCard({required this.result, required this.tag, required this.onPick});
  final HttpTestResult result;
  final Tag tag;
  final ValueChanged<HttpPick> onPick;

  static String _show(Object? v) => switch (v) {
        null => 'null',
        String s => '"${s.length > 30 ? '${s.substring(0, 30)}…' : s}"',
        List l => 'lista de ${l.length}',
        Map _ => 'objeto',
        double d => '$d'.replaceAll('.', ','),
        _ => '$v',
      };

  @override
  Widget build(BuildContext context) {
    final r = result;
    final color = r.ok ? Ind.ok : Ind.alarm;
    final head = [
      if (r.status != null) '${r.status}',
      if (r.elapsedMs != null) '${r.elapsedMs} ms',
    ].join(' · ');
    final leaves = [for (final (p, v) in r.fields) if (v is! Map) (p, v)];
    return Container(
      key: ValueKey(r.ok ? 'http-teste-ok' : 'http-teste-falhou'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Ind.radius),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(r.ok ? Icons.check_circle_rounded : Icons.error_rounded, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              r.ok ? 'Valor: ${TagCodec.format(tag, r.value)}' : capitalized(r.error!),
              key: const ValueKey('http-teste-texto'),
              style: TextStyle(color: Ind.textFor(color), fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
        ]),
        if (head.isNotEmpty) ...[
          const SizedBox(height: 4),
          Padding(padding: const EdgeInsets.only(left: 34), child: Text(head, key: const ValueKey('http-teste-status'), style: Ind.number(13, color: Ind.textDim))),
        ],
        if (leaves.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('Campos da resposta (toque para usar):', style: TextStyle(color: Ind.textDim, fontSize: 13)),
          for (final (p, v) in leaves.take(12))
            InkWell(
              key: ValueKey('http-campo-$p'),
              onTap: () => onPick(HttpPick(path: p, type: v is List ? TagDataType.uint16 : HttpPickType.of(v), decimals: HttpPickType.decimals(v))),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  Expanded(child: Text(p, style: Ind.number(14, color: Ind.text), overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 12),
                  Text(_show(v), style: TextStyle(color: Ind.textDim, fontSize: 13)),
                ]),
              ),
            ),
        ] else if (!r.ok && r.preview.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Veio: ${r.preview.trim()}', maxLines: 3, overflow: TextOverflow.ellipsis, style: Ind.number(12, color: Ind.textDim)),
        ],
      ]),
    );
  }
}

/// Tipo e casas decimais sugeridos para um valor da resposta.
abstract final class HttpPickType {
  static TagDataType of(Object? v) {
    if (v is bool) return TagDataType.bool;
    if (v is int) return TagDataType.uint16;
    if (v is double) return TagDataType.float32;
    if (v is String) {
      final n = num.tryParse(v.trim().replaceAll(',', '.'));
      if (n != null) return n is int ? TagDataType.uint16 : TagDataType.float32;
      final l = v.trim().toLowerCase();
      if (const {'on', 'off', 'true', 'false'}.contains(l)) return TagDataType.bool;
    }
    return TagDataType.string;
  }

  static int decimals(Object? v) {
    final d = v is double ? v : (v is String ? double.tryParse(v.trim().replaceAll(',', '.')) : null);
    if (d == null || d == d.roundToDouble()) return 0;
    final s = '$d';
    final dot = s.indexOf('.');
    return dot < 0 || s.contains('e') ? 0 : (s.length - dot - 1).clamp(0, 3);
  }
}

/// O comando para gravar, quando "Pode ser alterada pela tela" está ligado:
/// método, caminho (vazio = o da leitura) e corpo, com `{valor}` onde o valor
/// entra. Liga/desliga escolhe como o valor vai (1/0, true/false, ON/OFF).
class HttpCommandField extends StatelessWidget {
  const HttpCommandField({super.key, required this.fields, required this.isBool, required this.onChanged});

  final HttpTagFields fields;
  final bool isBool;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final f = fields;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionHeader('Comando para gravar', padding: EdgeInsets.fromLTRB(0, 12, 0, 8)),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final m in const [HttpMethod.post, HttpMethod.put, HttpMethod.get])
          ChoiceChip(
            key: ValueKey('http-gravar-${m.name}'),
            label: Text(m.verb),
            selected: f.writeMethod == m,
            onSelected: (_) {
              f.writeMethod = m;
              onChanged();
            },
          ),
      ]),
      const SizedBox(height: Ind.space),
      TextFormField(
        key: const ValueKey('campo-caminho-gravar-http'),
        controller: f.writePath,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          labelText: 'Caminho do comando',
          hintText: f.path.text.trim().isEmpty ? '/api/rele' : f.path.text.trim(),
          helperText: f.writeMethod == HttpMethod.get ? 'Ex.: /rele?estado={valor}. Vazio = o caminho da leitura.' : 'Vazio = o caminho da leitura.',
          helperMaxLines: 2,
        ),
        onChanged: (_) => onChanged(),
      ),
      if (f.writeMethod.hasBody) ...[
        const SizedBox(height: Ind.space),
        TextFormField(
          key: const ValueKey('campo-corpo-gravar-http'),
          controller: f.writeBody,
          minLines: 1,
          maxLines: 4,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Corpo do comando',
            hintText: '{"valor": {valor}}',
            helperText: '{valor} é trocado pelo valor gravado. Vazio = só o valor.',
            helperMaxLines: 2,
          ),
          onChanged: (_) => onChanged(),
        ),
      ],
      if (isBool) ...[
        const SizedBox(height: Ind.space),
        Text('Ligado e desligado vão como', style: TextStyle(color: Ind.textDim, fontSize: 13)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final b in MqttBoolFormat.values)
            ChoiceChip(
              key: ValueKey('http-liga-${b.name}'),
              label: Text(b.label),
              selected: f.boolFormat == b,
              onSelected: (_) {
                f.boolFormat = b;
                onChanged();
              },
            ),
        ]),
      ],
    ]);
  }
}
