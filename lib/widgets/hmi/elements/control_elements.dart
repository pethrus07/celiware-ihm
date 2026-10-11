import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/app_scope.dart';
import '../../../core/comm/comm_error.dart';
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

  /// Não grava nada: abre outra tela do projeto (`goTo`).
  screen,
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
      case ButtonMode.screen:
        return 'Ir para tela';
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
      case ButtonMode.screen:
        return 'TELA';
    }
  }

  bool get needsNumber => this == ButtonMode.value;

  /// Modo que grava numa variável (todos menos "Ir para tela").
  bool get needsTag => this != ButtonMode.screen;

  /// Modo de liga/desliga, em que o retorno da máquina faz sentido.
  bool get isBit => needsTag && !needsNumber;

  static ButtonMode fromName(String? n) =>
      ButtonMode.values.firstWhere((m) => m.name == n, orElse: () => ButtonMode.toggle);
}

/// Botão de comando.
///
/// Aceso (preenchido na cor escolhida) quando a variável está ligada — o
/// operador vê o **estado real** lido do equipamento, não um estado que o
/// celular imagina. Se o comando não pegar, o botão continua apagado.
///
/// **Retorno** (`feedbackTagId`, opcional): grava numa memória e acende pela
/// outra — o padrão de IHM de mercado para "comando liga" × "motor ligado".
/// Com retorno, o comando decide o que o toque faz (liga/desliga inverte o
/// comando) e o retorno decide se acende. Comando ligado sem retorno aparece
/// como **aguardando** (borda na cor + ampulheta): a máquina recebeu a ordem e
/// ainda não confirmou. Passados [ButtonElement.feedbackTimeout] sem retorno,
/// vira **SEM RETORNO** (cor de atenção): a máquina não vai confirmar (porta
/// aberta, intertravamento, desarme) — ampulheta para sempre parecia travado.
class ButtonElement extends StatefulWidget {
  const ButtonElement({super.key, required this.element});
  final HmiElement element;

  /// Quanto esperar a confirmação da máquina antes de avisar "sem retorno".
  static const feedbackTimeout = Duration(seconds: 5);

  @override
  State<ButtonElement> createState() => _ButtonElementState();
}

class _ButtonElementState extends State<ButtonElement> {
  bool _holding = false;

  /// Dedo em cima do botão (visual de "afundar").
  bool _pressed = false;
  HmiRuntime? _runtime;

  /// Desde quando o comando está ligado sem a máquina confirmar.
  DateTime? _pendingSince;
  Timer? _pendingTimer;

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
    _pendingTimer?.cancel();
    super.dispose();
  }

  /// Marca quando começou a espera e agenda um redesenho para o fim do prazo.
  /// Devolve true quando a espera já passou do prazo (sem retorno).
  bool _trackPending(bool pending) {
    if (!pending) {
      _pendingSince = null;
      _pendingTimer?.cancel();
      _pendingTimer = null;
      return false;
    }
    final now = clock.now();
    final since = _pendingSince ??= now;
    final left = ButtonElement.feedbackTimeout - now.difference(since);
    if (left <= Duration.zero) return true;
    _pendingTimer ??= Timer(left, () {
      _pendingTimer = null;
      if (mounted) setState(() {});
    });
    return false;
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
      case ButtonMode.screen:
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
    } on CommError catch (err) {
      if (mounted) WriteActions.toast(context, 'Não gravou: ${err.userMessage}.', error: true);
    }
  }

  Future<void> _up(Tag tag) async {
    if (!_holding) return;
    setState(() => _holding = false);
    await AppScope.of(context).runtime.release(tag.id);
  }

  /// Rosto do botão. [pending] = comando ligado que a máquina ainda não
  /// confirmou (só com retorno configurado).
  /// Rosto tátil: face com leve degradê (mais clara em cima), brilho de 1 px
  /// no topo, sombra em duas camadas e uma **faixa de LED** no alto — apagada
  /// na cor do botão a 35%, acesa quando ligado. Ao tocar, afunda 1,5 px e
  /// perde a sombra (princípio de botão físico, ver PESQUISA-UI-UX.md §1.4).
  Widget _face({required String label, required Color color, required bool lit, bool pending = false, Tag? tag, Widget? hint}) {
    // Texto legível sobre qualquer cor acesa (amarelo pede texto escuro).
    final onColor = color.computeLuminance() > 0.42 ? const Color(0xFF15181C) : Colors.white;
    final fg = lit ? onColor.withValues(alpha: 0.72) : Ind.textMuted;
    final base = lit ? color : Ind.surfaceHigh;
    final top = lit
        ? Color.lerp(color, Colors.white, 0.14)!
        : Color.lerp(Ind.surfaceHigh, Colors.white, Ind.isDark ? 0.045 : 0.6)!;
    final pressed = _pressed;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      transform: Matrix4.translationValues(0, pressed ? 1.5 : 0, 0),
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: pressed ? [base, base] : [top, base]),
        borderRadius: BorderRadius.circular(Ind.radius),
        border: Border.all(
          color: pending ? color : (lit ? Color.lerp(color, Colors.black, 0.18)! : Ind.lineStrong.withValues(alpha: Ind.isDark ? 0.55 : 0.8)),
          width: pending ? 3 : 1,
        ),
        boxShadow: pressed
            ? null
            : [
                ...Ind.cardShadow,
                if (lit && Ind.isDark) BoxShadow(color: color.withValues(alpha: 0.32), blurRadius: 18),
              ],
      ),
      child: CustomPaint(
        foregroundPainter: CardEdge(color: lit ? Colors.white.withValues(alpha: 0.35) : Ind.edge, rev: Ind.revision),
        child: Stack(children: [
          // Faixa de LED.
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: 22,
                height: 4,
                decoration: BoxDecoration(
                  color: lit ? onColor.withValues(alpha: 0.85) : color.withValues(alpha: pending ? 0.9 : 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
            child: _faceBody(label: label, color: color, lit: lit, pending: pending, tag: tag, hint: hint, onColor: onColor, fg: fg),
          ),
        ]),
      ),
    );
  }

  Widget _faceBody({required String label, required Color color, required bool lit, required bool pending, Tag? tag, Widget? hint, required Color onColor, required Color fg}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: FitText(label.toUpperCase(),
                style: TextStyle(
                  fontFamily: Ind.condensed,
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                  letterSpacing: 0.6,
                  color: lit ? onColor : Ind.text,
                )),
          ),
          // Só o essencial: o nome. O modo aparece apenas onde muda o
          // gesto — pulso (segurar) ganha um ícone; "grava valor", o valor;
          // "ir para tela", a seta; aguardando retorno, a ampulheta.
          if (hint != null) ...[
            const SizedBox(height: 4),
            hint,
          ] else if (pending) ...[
            const SizedBox(height: 4),
            Icon(Icons.hourglass_top_rounded, size: 16, color: color),
          ] else if (mode == ButtonMode.momentary) ...[
            const SizedBox(height: 4),
            Icon(Icons.touch_app_outlined, size: 16, color: fg),
          ] else if (mode == ButtonMode.value) ...[
            const SizedBox(height: 4),
            Text('= ${TagCodec.format(tag ?? _dummy, e.prop<num>('value', 0))}', style: Ind.tag(size: 11, color: fg)),
          ],
        ],
      ),
    );
  }

  /// "Ir para tela": não depende de variável nem de comunicação, e funciona
  /// também em tela só de acompanhamento (navegar não grava nada).
  Widget _screenButton(BuildContext context, HmiScreenContext screen) {
    final project = AppScope.watch(context).controller.project;
    final target = e.props['goTo'] as String?;
    final dest = target == null ? null : project.screen(target);
    final color = StateColorMeta.fromName(e.prop<String>('color', 'blue'), StateColor.blue).color;
    final label = e.prop<String>('label', dest?.name ?? 'Botão');
    // Seta AO LADO do nome, não embaixo: botão de navegação costuma ser uma
    // faixa de 1 linha, e empilhar os dois deixava o nome minúsculo.
    final face = dest == null
        ? _face(label: label, color: color, lit: false,
            hint: Text('ESCOLHA A TELA', style: TextStyle(color: Ind.accent, fontSize: 11, fontWeight: FontWeight.w700)))
        : CustomPaint(
            foregroundPainter: CardEdge(rev: Ind.revision),
            child: Container(
            decoration: Ind.card(color: Ind.surfaceHigh, border: color.withValues(alpha: 0.5), width: 1.2),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Flexible(
                child: FitText(label.toUpperCase(),
                    style: TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w700, fontSize: 20, letterSpacing: 0.5, color: Ind.text)),
              ),
              const SizedBox(width: 10),
              Icon(Icons.arrow_forward_rounded, size: 22, color: Ind.textFor(color)),
            ]),
          ),
          );
    final nav = screen.onNavigate;
    if (screen.editMode || nav == null || target == null) return face;
    return Semantics(button: true, child: GestureDetector(key: ValueKey('ir-${e.id}'), onTap: () => nav(target), child: face));
  }

  @override
  Widget build(BuildContext context) {
    final screen = HmiScreenContext.of(context);
    if (mode == ButtonMode.screen) return _screenButton(context, screen);
    final feedbackId = mode.isBit ? e.props['feedbackTagId'] as String? : null;
    return TagBuilder(
      tagId: e.tagId,
      builder: (context, tag, r) => TagBuilder(
        tagId: feedbackId,
        builder: (context, fbTag, fb) => _build(context, screen, tag, r, fbTag, fb),
      ),
    );
  }

  Widget _build(BuildContext context, HmiScreenContext screen, Tag? tag, TagReading r, Tag? fbTag, TagReading fb) {
    final color = StateColorMeta.fromName(e.prop<String>('color', 'green')).color;
    final commanded = r.value == true || _holding;
    // Com retorno, acende pelo que a máquina confirma; sem, pelo comando.
    final hasFeedback = fbTag != null;
    final lit = mode == ButtonMode.value ? false : (hasFeedback ? fb.value == true : commanded);
    final pending = hasFeedback && commanded && fb.value != true && mode != ButtonMode.momentary;
    final noFeedback = _trackPending(pending);
    final label = e.prop<String>('label', tag?.name ?? 'Botão');

    final face = noFeedback
        ? _face(label: label, color: Ind.warn, lit: false, pending: true, tag: tag,
            hint: Text('SEM RETORNO', style: TextStyle(color: Ind.textFor(Ind.warn), fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4)))
        : _face(label: label, color: color, lit: lit, pending: pending, tag: tag);

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
    // Afundar ao tocar: só visual, em qualquer modo que opere.
    if (screen.canOperate) {
      interactive = Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: interactive,
      );
    }

    return Opacity(
      opacity: r.quality == TagQuality.commLost ? 0.45 : 1,
      child: Semantics(button: true, label: label, child: interactive),
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
              Padding(padding: const EdgeInsets.only(left: 6), child: Text(tag.unit, style: TextStyle(color: Ind.textDim, fontSize: 14))),
            const Spacer(),
            if (editable) ...[
              const SizedBox(width: 8),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: Ind.accent.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(8)),
                child: Icon(Icons.edit_rounded, size: 20, color: Ind.accent),
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
