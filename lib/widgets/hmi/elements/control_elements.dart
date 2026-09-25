import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/app_scope.dart';
import '../../../core/modbus/modbus_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../models/hmi_screen.dart';
import '../../../models/tag.dart';
import '../../../services/runtime/hmi_runtime.dart';
import '../../../services/runtime/tag_codec.dart';
import '../../../services/runtime/tag_store.dart';
import '../hmi_frame.dart';
import '../write_actions.dart';

/// Modos do botão — os usuais de IHM de mercado.
enum ButtonMode {
  /// Cada toque inverte: liga ↔ desliga.
  toggle,

  /// Liga enquanto o dedo está em cima, desliga ao soltar (partida por
  /// impulso, reset, jog). Sem confirmação: pedir "tem certeza?" quebraria o
  /// gesto de segurar. A soltura é garantida pelo [HmiRuntime] mesmo se a
  /// rede cair.
  momentary,

  /// Só liga.
  set,

  /// Só desliga.
  reset,

  /// Grava um número fixo (ex.: receita 3, modo 2).
  value,
}

extension ButtonModeMeta on ButtonMode {
  String get label {
    switch (this) {
      case ButtonMode.toggle:
        return 'Liga / desliga';
      case ButtonMode.momentary:
        return 'Pulso (enquanto segura)';
      case ButtonMode.set:
        return 'Só liga';
      case ButtonMode.reset:
        return 'Só desliga';
      case ButtonMode.value:
        return 'Grava um valor';
    }
  }

  String get badge {
    switch (this) {
      case ButtonMode.toggle:
        return 'LIGA/DESL';
      case ButtonMode.momentary:
        return 'PULSO';
      case ButtonMode.set:
        return 'LIGA';
      case ButtonMode.reset:
        return 'DESLIGA';
      case ButtonMode.value:
        return 'VALOR';
    }
  }

  bool get needsNumber => this == ButtonMode.value;

  static ButtonMode fromName(String? n) =>
      ButtonMode.values.firstWhere((m) => m.name == n, orElse: () => ButtonMode.toggle);
}

/// Botão de comando.
///
/// Aceso (preenchido na cor escolhida) quando a variável está ligada — o
/// operador vê o **estado real** lido do equipamento, não um estado que o
/// celular imagina. Se o comando não pegar, o botão continua apagado.
class ButtonElement extends StatefulWidget {
  const ButtonElement({super.key, required this.element});
  final HmiElement element;

  @override
  State<ButtonElement> createState() => _ButtonElementState();
}

class _ButtonElementState extends State<ButtonElement> {
  bool _holding = false;
  HmiRuntime? _runtime;

  HmiElement get e => widget.element;
  ButtonMode get mode => ButtonModeMeta.fromName(e.prop<String>('mode', 'toggle'));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Guardado aqui porque no dispose() o contexto já não pode ser consultado.
    _runtime = AppScope.of(context).runtime;
  }

  @override
  void dispose() {
    // Botão sumiu da tela com o dedo em cima (tela fechou, rolou, editou):
    // solta o comando.
    if (_holding && e.tagId != null) unawaited(_runtime?.release(e.tagId!));
    super.dispose();
  }

  Future<void> _tap(Tag tag, TagReading r) async {
    final on = r.value == true;
    switch (mode) {
      case ButtonMode.toggle:
        await WriteActions.write(context, tag: tag, value: !on, description: on ? 'Desligar?' : 'Ligar?');
      case ButtonMode.set:
        await WriteActions.write(context, tag: tag, value: true, description: 'Ligar?');
      case ButtonMode.reset:
        await WriteActions.write(context, tag: tag, value: false, description: 'Desligar?');
      case ButtonMode.value:
        final v = e.prop<num>('value', 0);
        await WriteActions.write(context, tag: tag, value: v,
            description: 'Gravar ${TagCodec.format(tag, v)}? (atual: ${TagCodec.format(tag, r.value)})');
      case ButtonMode.momentary:
        break;
    }
  }

  Future<void> _down(Tag tag) async {
    final screen = HmiScreenContext.of(context);
    if (!screen.canOperate || !tag.canWrite) {
      WriteActions.toast(context, screen.readOnly ? 'Esta tela é só de acompanhamento.' : '"${tag.name}" é só leitura.');
      return;
    }
    setState(() => _holding = true);
    HapticFeedback.mediumImpact();
    try {
      await AppScope.of(context).runtime.press(tag.id);
    } on ModbusError catch (err) {
      if (mounted) WriteActions.toast(context, 'Não gravou: ${err.userMessage}.', error: true);
    }
  }

  Future<void> _up(Tag tag) async {
    if (!_holding) return;
    setState(() => _holding = false);
    await AppScope.of(context).runtime.release(tag.id);
  }

  @override
  Widget build(BuildContext context) {
    final screen = HmiScreenContext.of(context);
    return TagBuilder(
      tagId: e.tagId,
      builder: (context, tag, r) {
        final color = StateColorMeta.fromName(e.prop<String>('color', 'green')).color;
        final lit = mode == ButtonMode.value ? false : (r.value == true || _holding);
        final label = e.prop<String>('label', tag?.name ?? 'Botão');

        final face = AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: lit ? color : Ind.surfaceHigher,
            borderRadius: BorderRadius.circular(Ind.radius),
            border: Border.all(color: lit ? color : color.withValues(alpha: 0.4), width: 1.5),
            boxShadow: lit ? [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 14)] : null,
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: FitText(label.toUpperCase(),
                    style: TextStyle(
                      fontFamily: Ind.condensed,
                      fontWeight: FontWeight.w700,
                      fontSize: 20,
                      letterSpacing: 0.5,
                      color: lit ? Ind.bg : Ind.text,
                    )),
              ),
              // Só o essencial: o nome. O modo aparece apenas onde muda o
              // gesto — pulso (segurar) ganha um ícone; "grava valor", o valor.
              if (mode == ButtonMode.momentary) ...[
                const SizedBox(height: 4),
                Icon(Icons.touch_app_outlined, size: 16, color: lit ? Ind.bg.withValues(alpha: 0.7) : Ind.textMuted),
              ] else if (mode == ButtonMode.value) ...[
                const SizedBox(height: 4),
                Text('= ${TagCodec.format(tag ?? _dummy, e.prop<num>('value', 0))}',
                    style: Ind.tag(size: 11, color: lit ? Ind.bg.withValues(alpha: 0.7) : Ind.textMuted)),
              ],
            ],
          ),
        );

        if (tag == null || r.quality == TagQuality.addressError || r.quality == TagQuality.configError) {
          return HmiFrame(label: '', tag: tag, reading: r, child: const SizedBox());
        }

        Widget interactive;
        if (screen.editMode) {
          interactive = face;
        } else if (screen.readOnly) {
          // Toque numa tela só de acompanhamento explica por que nada
          // aconteceu — silêncio parece defeito para quem opera.
          interactive = GestureDetector(
            onTap: () => WriteActions.toast(context, 'Esta tela é só de acompanhamento.'),
            child: face,
          );
        } else if (mode == ButtonMode.momentary) {
          interactive = Listener(
            onPointerDown: (_) => _down(tag),
            onPointerUp: (_) => _up(tag),
            onPointerCancel: (_) => _up(tag),
            child: face,
          );
        } else {
          interactive = GestureDetector(onTap: () => _tap(tag, r), child: face);
        }

        return Opacity(
          opacity: r.quality == TagQuality.commLost ? 0.45 : 1,
          child: Semantics(button: true, label: label, child: interactive),
        );
      },
    );
  }

  static const _dummy = Tag(id: '', name: '', deviceId: '');
}

/// Ajuste de valor: mostra o valor atual e abre o teclado numérico ao tocar.
class InputElement extends StatelessWidget {
  const InputElement({super.key, required this.element});
  final HmiElement element;

  @override
  Widget build(BuildContext context) {
    final e = element;
    final screen = HmiScreenContext.of(context);
    return TagBuilder(
      tagId: e.tagId,
      builder: (context, tag, r) {
        final label = e.prop<String>('label', tag?.name ?? '');
        final min = e.props['min'] as num?;
        final max = e.props['max'] as num?;
        final editable = screen.canOperate && (tag?.canWrite ?? false);

        final body = Row(
          children: [
            // Unidade colada no número, lápis encostado à direita.
            Flexible(
              child: FitText(tag == null ? '---' : TagCodec.format(tag, r.value, withUnit: false),
                  alignment: Alignment.centerLeft, style: Ind.number(34)),
            ),
            if (tag != null && tag.unit.isNotEmpty)
              Padding(padding: const EdgeInsets.only(left: 6), child: Text(tag.unit, style: const TextStyle(color: Ind.textDim, fontSize: 14))),
            const Spacer(),
            if (editable) ...[
              const SizedBox(width: 8),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: Ind.accent.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.edit_rounded, size: 20, color: Ind.accent),
              ),
            ],
          ],
        );

        final frame = HmiFrame(
          label: label,
          tag: tag,
          reading: r,
          child: Align(alignment: Alignment.centerLeft, child: body),
        );
        if (tag != null && !screen.editMode && !editable) {
          return GestureDetector(
            onTap: () => WriteActions.toast(context,
                screen.readOnly ? 'Esta tela é só de acompanhamento.' : '"${tag.name}" é só leitura.'),
            child: frame,
          );
        }
        if (!editable || tag == null) return frame;

        return GestureDetector(
          onTap: () async {
            final v = await NumberPad.show(context, tag: tag, current: r.value, min: min, max: max);
            if (v == null || !context.mounted) return;
            await WriteActions.write(context,
                tag: tag, value: v, description: 'De ${TagCodec.format(tag, r.value)} para ${TagCodec.format(tag, v)}?');
          },
          child: frame,
        );
      },
    );
  }
}
