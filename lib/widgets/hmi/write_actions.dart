import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../core/modbus/modbus_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../models/tag.dart';
import '../../services/runtime/tag_codec.dart';
import 'hmi_frame.dart';

/// Escrita a partir de um elemento, com as regras de segurança da tela.
///
/// Todo elemento que grava passa por aqui — confirmação, só leitura e
/// mensagem de erro ficam num lugar só:
///   1. tela só leitura → não grava (e avisa);
///   2. [HmiScreenContext.confirmWrites] → pergunta "de X para Y?";
///   3. grava e dá retorno tátil;
///   4. falhou → mensagem clara na parte de baixo (motivo real, sem jargão).
class WriteActions {
  WriteActions._();

  static Future<bool> write(
    BuildContext context, {
    required Tag tag,
    required Object value,
    required String description,
    bool askConfirmation = true,
  }) async {
    final screen = HmiScreenContext.of(context);
    final scope = AppScope.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);

    if (screen.readOnly) {
      _toast(messenger, 'Esta tela é só de acompanhamento.');
      return false;
    }
    if (!tag.canWrite) {
      _toast(messenger, '"${tag.name}" está marcada como só leitura.');
      return false;
    }
    if (askConfirmation && screen.confirmWrites) {
      final ok = await confirm(context, title: tag.name, message: description);
      if (!ok || !context.mounted) return false;
    }
    try {
      await scope.runtime.write(tag.id, value);
      HapticFeedback.lightImpact();
      return true;
    } on TagValueError catch (e) {
      _toast(messenger, e.message, error: true);
    } on ModbusError catch (e) {
      _toast(messenger, 'Não gravou: ${e.userMessage}.', error: true);
    }
    return false;
  }

  static Future<bool> confirm(BuildContext context, {required String title, required String message}) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.edit_note_rounded, color: Ind.accent),
        title: Text(title),
        content: Text(message, style: const TextStyle(fontSize: 16, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(key: const ValueKey('confirmar-escrita'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirmar')),
        ],
      ),
    );
    return r ?? false;
  }

  static void _toast(ScaffoldMessengerState? m, String text, {bool error = false}) {
    m?.hideCurrentSnackBar();
    m?.showSnackBar(SnackBar(
      content: Row(children: [
        Icon(error ? Icons.error_outline_rounded : Icons.info_outline_rounded, color: error ? Ind.alarm : Ind.accent),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ]),
    ));
  }

  static void toast(BuildContext context, String text, {bool error = false}) =>
      _toast(ScaffoldMessenger.maybeOf(context), text, error: error);
}

/// Teclado numérico grande, para luva e dedo sujo de graxa — o campo de texto
/// do sistema é pequeno demais para chão de fábrica.
class NumberPad extends StatefulWidget {
  const NumberPad({super.key, required this.tag, required this.current, this.min, this.max});

  final Tag tag;
  final Object? current;
  final num? min;
  final num? max;

  /// Abre o teclado e devolve o número digitado (ou nulo se cancelou).
  static Future<num?> show(BuildContext context, {required Tag tag, Object? current, num? min, num? max}) =>
      showModalBottomSheet<num>(
        context: context,
        isScrollControlled: true,
        builder: (_) => NumberPad(tag: tag, current: current, min: min, max: max),
      );

  @override
  State<NumberPad> createState() => _NumberPadState();
}

class _NumberPadState extends State<NumberPad> {
  String _text = '';
  String? _error;

  // Com escala (÷10), um inteiro do equipamento vira 75,2 na tela: a vírgula
  // tem que existir no teclado. Deslocamento ou fator negativo permitem valor
  // negativo mesmo em registrador sem sinal.
  bool get _allowsDecimal => widget.tag.dataType == TagDataType.float32 || widget.tag.displayDecimals > 0;
  bool get _allowsNegative =>
      widget.tag.dataType == TagDataType.int16 ||
      widget.tag.dataType == TagDataType.int32 ||
      widget.tag.dataType == TagDataType.float32 ||
      widget.tag.offset < 0 ||
      widget.tag.scale < 0;

  void _key(String k) {
    setState(() {
      _error = null;
      if (k == '⌫') {
        if (_text.isNotEmpty) _text = _text.substring(0, _text.length - 1);
      } else if (k == ',') {
        if (_allowsDecimal && !_text.contains(',')) _text = _text.isEmpty ? '0,' : '$_text,';
      } else if (k == '±') {
        if (_allowsNegative) _text = _text.startsWith('-') ? _text.substring(1) : '-$_text';
      } else if (_text.replaceAll(RegExp(r'[-,]'), '').length < 10) {
        _text += k;
      }
    });
  }

  void _ok() {
    try {
      final v = TagCodec.parseInput(widget.tag, _text);
      if (widget.min != null && v < widget.min!) throw TagValueError('Mínimo permitido: ${_fmt(widget.min!)}');
      if (widget.max != null && v > widget.max!) throw TagValueError('Máximo permitido: ${_fmt(widget.max!)}');
      TagCodec.encodeRegisters(widget.tag, v); // valida faixa do tipo
      Navigator.pop(context, v);
    } on TagValueError catch (e) {
      setState(() => _error = e.message);
    }
  }

  String _fmt(num n) => n.toString().replaceAll('.', ',');

  @override
  Widget build(BuildContext context) {
    final t = widget.tag;
    final limits = [
      if (widget.min != null) 'mín. ${_fmt(widget.min!)}',
      if (widget.max != null) 'máx. ${_fmt(widget.max!)}',
    ].join(' · ');
    final keys = ['7', '8', '9', '4', '5', '6', '1', '2', '3', _allowsNegative ? '±' : '', '0', _allowsDecimal ? ',' : ''];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Atual: ${TagCodec.format(t, widget.current)}${limits.isEmpty ? '' : '  ·  $limits'}',
                style: const TextStyle(color: Ind.textDim)),
            const SizedBox(height: 14),
            Container(
              key: const ValueKey('numpad-visor'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: Ind.bg,
                borderRadius: BorderRadius.circular(Ind.radiusSmall),
                border: Border.all(color: _error != null ? Ind.alarm : Ind.accent, width: 2),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_text.isEmpty ? ' ' : _text, textAlign: TextAlign.right, style: Ind.number(36)),
                  ),
                  if (t.unit.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 8), child: Text(t.unit, style: const TextStyle(color: Ind.textDim, fontSize: 18))),
                ],
              ),
            ),
            SizedBox(
              height: 28,
              child: _error == null ? null : Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: const TextStyle(color: Ind.alarm, fontWeight: FontWeight.w600))),
            ),
            GridView.count(
              shrinkWrap: true,
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 2.1,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final k in keys)
                  k.isEmpty
                      ? const SizedBox()
                      : _PadKey(label: k, onTap: () => _key(k)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _PadKey(label: '⌫', onTap: () => _key('⌫'), dim: true)),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 56,
                    child: FilledButton(key: const ValueKey('numpad-ok'), onPressed: _text.isEmpty ? null : _ok, child: const Text('GRAVAR', style: TextStyle(fontSize: 17, letterSpacing: 1))),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PadKey extends StatelessWidget {
  const _PadKey({required this.label, required this.onTap, this.dim = false});
  final String label;
  final VoidCallback onTap;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Material(
        color: dim ? Ind.surfaceHigh : Ind.surfaceHigher,
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        child: InkWell(
          key: ValueKey('tecla-$label'),
          borderRadius: BorderRadius.circular(Ind.radiusSmall),
          onTap: onTap,
          child: Center(child: Text(label, style: Ind.number(24, color: dim ? Ind.textDim : Ind.text))),
        ),
      ),
    );
  }
}
