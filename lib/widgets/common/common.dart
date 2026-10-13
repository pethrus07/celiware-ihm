import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../core/modbus/modbus_client.dart';
import '../../core/theme/app_theme.dart';
import '../../models/device.dart';
import '../../services/runtime/device_session.dart';

/// Tela vazia que ensina o próximo passo — nunca só "nada aqui".
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(color: Ind.surfaceHigh, borderRadius: BorderRadius.circular(20)),
              child: Icon(icon, size: 34, color: Ind.accent),
            ),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center, style: TextStyle(color: Ind.textDim, height: 1.45)),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// Título de seção em placa (caixa alta condensada) — o **único** cabeçalho
/// de seção do app: página, formulário, folha e grupo de opções ("Ordem dos
/// bytes", "Entrega (QoS)", "Quando"). Dois estilos no mesmo formulário
/// faziam o leitor procurar uma hierarquia que não existe. O respiro vem
/// por [padding]; a letra, nunca.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.trailing, this.padding = const EdgeInsets.fromLTRB(Ind.page, 28, Ind.page, 12)});
  final String text;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(children: [
          Expanded(child: Text(text.toUpperCase(), style: Ind.tag(size: 12.5, color: Ind.textDim))),
          ?trailing,
        ]),
      );
}

/// Selo de comunicação de um equipamento, ao vivo.
///
/// Verde = respondendo; âmbar = conectando; vermelho = sem comunicação (com o
/// motivo); cinza = nada dele em uso agora (não está sendo lido).
class LinkChip extends StatelessWidget {
  const LinkChip({super.key, required this.device, this.compact = false});
  final Device device;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final runtime = AppScope.of(context).runtime;
    return ValueListenableBuilder<int>(
      valueListenable: runtime.sessionsRevision,
      builder: (context, _, _) => _forHealth(runtime.health(device.id)),
    );
  }

  Widget _forHealth(ValueListenable<DeviceHealth>? health) {
    if (health == null) return _chip(Ind.textMuted, compact ? device.name : 'Ocioso', Icons.pause_circle_outline_rounded);
    return ValueListenableBuilder<DeviceHealth>(
      valueListenable: health,
      builder: (context, h, _) {
        final (color, text, icon) = switch (h) {
          _ when h.online => (Ind.ok, compact ? device.name : 'Online${h.lastScanMs != null ? ' · ${h.lastScanMs} ms' : ''}', Icons.check_circle_rounded),
          // A mensagem vem em minúscula porque também entra no meio de frases
          // ("Não gravou: sem conexão…"); sozinha no selo, começa maiúscula,
          // como o "Online" ao lado.
          _ when h.message.isNotEmpty => (Ind.alarm, compact ? device.name : capitalized(h.message), Icons.error_rounded),
          _ when h.link == ModbusLinkState.connecting => (Ind.warn, compact ? device.name : 'Conectando…', Icons.sync_rounded),
          _ => (Ind.textMuted, compact ? device.name : 'Ocioso', Icons.pause_circle_outline_rounded),
        };
        return _chip(color, text, icon);
      },
    );
  }

  Widget _chip(Color color, String text, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(child: Text(text, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600))),
        ]),
      );
}

/// "sem conexão" → "Sem conexão".
String capitalized(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Depois de abrir um "Mais opções", rola a tela até ele: aberto no pé da
/// tela, o conteúdo novo ficava escondido atrás do botão Salvar e parecia que
/// nada tinha acontecido. Espera a animação de abrir antes de medir.
void revealAfterExpand(GlobalKey tileKey, bool opened) {
  if (!opened) return;
  Future.delayed(const Duration(milliseconds: 260), () {
    final ctx = tileKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    Scrollable.ensureVisible(ctx, alignment: 0.05, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
  });
}

/// Uma opção grande de escolha — ícone, título e explicação curta.
class ChoiceOption<T> {
  const ChoiceOption({required this.value, required this.title, this.subtitle, this.icon});
  final T value;
  final String title;
  final String? subtitle;
  final IconData? icon;
}

/// Cartões de escolha em grade. Mais fácil que uma lista suspensa para quem
/// não é técnico: todas as opções à vista, cada uma com uma frase.
class ChoiceCards<T> extends StatelessWidget {
  const ChoiceCards({super.key, required this.options, required this.selected, required this.onChanged, this.columns = 2});
  final List<ChoiceOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;
  final int columns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth < 340 ? 1 : columns;
      // Linha a linha, cada cartão com a altura do mais alto da linha: com
      // uma explicação de duas linhas ao lado de uma de uma, os cartões
      // ficavam desencontrados ("Na rede" × "Cabo USB").
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < options.length; i += cols) ...[
            if (i > 0) const SizedBox(height: 12),
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var j = i; j < i + cols; j++) ...[
                  if (j > i) const SizedBox(width: 12),
                  Expanded(
                    child: j < options.length
                        ? _ChoiceCard(option: options[j], selected: options[j].value == selected, onTap: () => onChanged(options[j].value))
                        : const SizedBox.shrink(),
                  ),
                ],
              ]),
            ),
          ],
        ],
      );
    });
  }
}

class _ChoiceCard<T> extends StatelessWidget {
  const _ChoiceCard({required this.option, required this.selected, required this.onTap});
  final ChoiceOption<T> option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Ind.accent.withValues(alpha: 0.14) : Ind.surfaceHigh,
      borderRadius: BorderRadius.circular(Ind.radiusSmall),
      child: InkWell(
        key: ValueKey('opcao-${option.value}'),
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Ind.radiusSmall),
            border: selected ? Border.all(color: Ind.accent, width: 2) : null,
          ),
          child: Row(
            children: [
              if (option.icon != null) ...[
                Icon(option.icon, color: selected ? Ind.accent : Ind.textDim, size: 22),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(option.title, style: TextStyle(fontWeight: FontWeight.w700, color: selected ? Ind.text : Ind.text)),
                    if (option.subtitle != null)
                      Padding(padding: const EdgeInsets.only(top: 2), child: Text(option.subtitle!, style: TextStyle(color: Ind.textMuted, fontSize: 12.5, height: 1.3))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Campo numérico inteiro com botões − / + (endereço, porta, ID) — errar um
/// dígito no teclado pequeno é o erro de cadastro mais comum.
class StepperField extends StatelessWidget {
  const StepperField({
    super.key,
    required this.label,
    required this.controller,
    this.min = 0,
    this.max = 65535,
    this.helper,
    this.onChanged,
    this.fieldKey,
  });

  final String label;
  final TextEditingController controller;
  final int min;
  final int max;
  final String? helper;
  final VoidCallback? onChanged;
  final Key? fieldKey;

  void _bump(int d) {
    final v = (int.tryParse(controller.text) ?? min) + d;
    controller.text = v.clamp(min, max).toString();
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextFormField(
            key: fieldKey,
            controller: controller,
            keyboardType: TextInputType.number,
            // O teclado numérico do Android tem "." e ",": num inteiro sem
            // sinal, só algarismos entram ("5020." virava erro no Salvar).
            inputFormatters: [if (min >= 0) FilteringTextInputFormatter.digitsOnly],
            style: Ind.number(20),
            // O campo divide a largura com − e +: a dica quebra em mais
            // linhas que num campo inteiro, e não pode acabar em "…".
            decoration: InputDecoration(labelText: label, helperText: helper, helperMaxLines: 6),
            onChanged: (_) => onChanged?.call(),
            validator: (t) {
              final v = int.tryParse(t ?? '');
              if (v == null) return 'Número inteiro';
              if (v < min || v > max) return 'De $min a $max';
              return null;
            },
          ),
        ),
        const SizedBox(width: 6),
        StepButton(icon: Icons.remove_rounded, onTap: () => _bump(-1), tooltip: 'Diminuir'),
        const SizedBox(width: 6),
        StepButton(icon: Icons.add_rounded, onTap: () => _bump(1), tooltip: 'Aumentar'),
      ],
    );
  }
}

/// O botão − / + do app — e das setas de mover —, um só desenho em todo
/// lugar: quadrado de cantos arredondados com fundo, da altura do campo
/// ([size] = 56 × 58). Fundo em vez de contorno: combina com o campo sem
/// borda ao lado. Antes havia também o círculo de contorno (casas decimais,
/// largura/altura do elemento), e os dois apareciam no mesmo formulário.
///
/// [onTap] nulo = desabilitado (chegou no limite).
class StepButton extends StatelessWidget {
  const StepButton({super.key, required this.icon, required this.onTap, this.tooltip, this.size = const Size(56, 58)});
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final Size size;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox.fromSize(
      size: size,
      child: FilledButton.tonal(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(Ind.minTouch, Ind.minTouch),
          backgroundColor: Ind.surfaceHigh,
          foregroundColor: Ind.text,
          // Desabilitado (chegou no limite) mantém a forma; só o ícone apaga.
          disabledBackgroundColor: Ind.surfaceHigh.withValues(alpha: 0.6),
          disabledForegroundColor: Ind.textMuted.withValues(alpha: 0.5),
        ),
        child: Icon(icon),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// Contador "rótulo · valor − +" (casas decimais, largura e altura do
/// elemento), com o mesmo [StepButton] do campo numérico — os dois convivem
/// no mesmo formulário e agora se leem como um controle só, com o − e o +
/// na mesma coluna do [StepperField].
///
/// [onDecrease]/[onIncrease] nulos desabilitam o lado que chegou no limite.
/// Chaves: `$keyPrefix-menos`, `$keyPrefix-mais` e [valueKey] no número.
class StepperCounter extends StatelessWidget {
  const StepperCounter({
    super.key,
    required this.label,
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
    this.caption,
    this.keyPrefix,
    this.valueKey,
  });

  final String label;
  final String? caption;
  final int value;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;
  final String? keyPrefix;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(color: Ind.text, fontSize: 16)),
            if (caption != null) ...[
              const SizedBox(height: 2),
              Text(caption!, style: TextStyle(color: Ind.textMuted, fontSize: 12.5)),
            ],
          ]),
        ),
        // O número antes dos botões, e os botões com o mesmo respiro do
        // campo numérico: num formulário, o − e o + de todos caem na mesma
        // coluna.
        SizedBox(width: 48, child: Text('$value', key: valueKey, textAlign: TextAlign.center, style: Ind.number(20))),
        const SizedBox(width: 6),
        StepButton(key: keyPrefix == null ? null : ValueKey('$keyPrefix-menos'), icon: Icons.remove_rounded, onTap: onDecrease, tooltip: 'Diminuir'),
        const SizedBox(width: 6),
        StepButton(key: keyPrefix == null ? null : ValueKey('$keyPrefix-mais'), icon: Icons.add_rounded, onTap: onIncrease, tooltip: 'Aumentar'),
      ]);
}

/// Sugestão que se aplica com um toque ("Parece a notação de manual…",
/// "Tente palavras trocadas…"). Azul de informação: não é erro, é atalho. Só
/// aparece quando o problema existe.
class SuggestionTile extends StatelessWidget {
  const SuggestionTile({super.key, required this.text, required this.onTap, this.icon = Icons.auto_fix_high_rounded});
  final String text;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Material(
        color: Ind.info.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        child: InkWell(
          borderRadius: BorderRadius.circular(Ind.radiusSmall),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(icon, color: Ind.info),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
            ]),
          ),
        ),
      );
}

/// Medidas de texto com a letra de verdade, para escolher o arranjo (uma ou
/// duas linhas, um pouco menor, em cima ou ao lado) **antes** de cortar com
/// "…". Palavra nunca quebra no meio: a mais longa tem que caber inteira.
abstract final class TextFit {
  static final Map<String, double> _cache = {};

  static TextPainter _painter(String text, TextStyle style, TextScaler scaler, int? maxLines) =>
      TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, textScaler: scaler, maxLines: maxLines);

  static String _key(String what, String text, TextStyle style, TextScaler scaler) =>
      '$what|$text|${style.fontFamily}|${style.fontWeight?.value}|${style.fontSize}|${style.letterSpacing}|${style.height}|${scaler.scale(100)}';

  static double _remember(String key, double Function() compute) {
    final hit = _cache[key];
    if (hit != null) return hit;
    if (_cache.length > 512) _cache.clear();
    return _cache[key] = compute();
  }

  /// Largura do texto numa linha só.
  static double width(String text, TextStyle style, {TextScaler scaler = TextScaler.noScaling}) =>
      _remember(_key('w', text, style, scaler), () {
        final p = _painter(text, style, scaler, null)..layout();
        final w = p.width;
        p.dispose();
        return w;
      });

  /// Largura da palavra mais longa (o mínimo para nada quebrar no meio).
  static double longestWord(String text, TextStyle style, {TextScaler scaler = TextScaler.noScaling}) {
    var w = 0.0;
    for (final word in text.split(RegExp(r'\s+'))) {
      if (word.isNotEmpty) w = math.max(w, width(word, style, scaler: scaler));
    }
    return w;
  }

  /// Cabe em [width] com no máximo [maxLines] linhas, sem quebrar palavra?
  static bool fits(String text, TextStyle style, double width, {int maxLines = 1, TextScaler scaler = TextScaler.noScaling}) {
    if (width <= 0) return false;
    if (longestWord(text, style, scaler: scaler) > width + 0.01) return false;
    // Guardado: o elemento da tela redesenha a cada leitura nova e o rótulo
    // (e a largura dele) quase nunca muda.
    return _remember(_key('f$maxLines@${width.toStringAsFixed(1)}', text, style, scaler), () {
          final p = _painter(text, style, scaler, maxLines)..layout(maxWidth: width);
          final ok = !p.didExceedMaxLines;
          p.dispose();
          return ok ? 1 : 0;
        }) ==
        1;
  }

  /// Menor largura em que o texto cabe em [lines] linhas sem quebrar
  /// palavra (o rótulo ocupa só o que precisa e o resto fica para o valor).
  static double widthFor(String text, TextStyle style, int lines, {TextScaler scaler = TextScaler.noScaling}) {
    final full = width(text, style, scaler: scaler);
    if (lines <= 1) return full;
    return _remember(_key('l$lines', text, style, scaler), () {
      var lo = math.max(longestWord(text, style, scaler: scaler), full / lines), hi = full;
      if (fits(text, style, lo, maxLines: lines, scaler: scaler)) return lo.ceilToDouble();
      for (var i = 0; i < 14 && hi - lo > 0.5; i++) {
        final mid = (lo + hi) / 2;
        if (fits(text, style, mid, maxLines: lines, scaler: scaler)) {
          hi = mid;
        } else {
          lo = mid;
        }
      }
      return hi.ceilToDouble();
    });
  }

  /// O mesmo estilo em [scale] do tamanho (o espaçamento entre letras acompanha).
  static TextStyle scaled(TextStyle style, double scale) =>
      style.copyWith(fontSize: (style.fontSize ?? 14) * scale, letterSpacing: style.letterSpacing == null ? null : style.letterSpacing! * scale);

  /// Arranjo de um rótulo em [width]: no tamanho de [style] numa linha; senão
  /// um pouco menor (até 85%) numa linha; senão em duas linhas ([maxLines]),
  /// encolhendo até [minScale]. Devolve o estilo, as linhas e se coube —
  /// `false` é o último recurso (o chamador corta com "…").
  static (TextStyle, int, bool) arrange(String text, TextStyle style, double width,
      {int maxLines = 2, double minScale = 0.75, TextScaler scaler = TextScaler.noScaling}) {
    if (fits(text, style, width, scaler: scaler)) return (style, 1, true);
    final steps = [for (var s = 0.95; s >= minScale - 1e-9; s -= 0.05) s];
    for (final s in steps.where((s) => s >= 0.85 - 1e-9)) {
      final t = scaled(style, s);
      if (fits(text, t, width, scaler: scaler)) return (t, 1, true);
    }
    for (var lines = 2; lines <= maxLines; lines++) {
      for (final s in [1.0, ...steps]) {
        final t = scaled(style, s);
        if (fits(text, t, width, maxLines: lines, scaler: scaler)) return (t, lines, true);
      }
    }
    if (maxLines == 1) {
      for (final s in steps.where((s) => s < 0.85 - 1e-9)) {
        final t = scaled(style, s);
        if (fits(text, t, width, scaler: scaler)) return (t, 1, true);
      }
    }
    return (scaled(style, minScale), maxLines, false);
  }
}

/// Peso de um botão de [DecisionDialog]: define cor, estilo e lugar.
enum DialogActionKind {
  /// Fecha sem fazer nada ("Continuar editando", "Cancelar").
  dismiss,

  /// Perde algo ("Descartar", "Apagar") — texto em vermelho.
  destructive,

  /// A ação recomendada ("Salvar") — o único botão preenchido.
  primary,
}

/// Um botão de [DecisionDialog].
class DialogAction<T> {
  const DialogAction({required this.label, required this.value, this.kind = DialogActionKind.dismiss, this.key});
  final String label;
  final T value;
  final DialogActionKind kind;
  final Key? key;
}

/// Pergunta com até três saídas, no padrão do Material 3: botões de texto e
/// um só preenchido **numa linha alinhada à direita** — fechar · destrutiva ·
/// principal — quando cabem; quando não cabem (celular), **empilhados com a
/// largura toda**, a principal em cima e a de fechar embaixo. Assim nunca
/// ficam em escada, cada um com uma largura e uma borda (o "Descartar
/// alterações?" do celular).
class DecisionDialog<T> extends StatelessWidget {
  const DecisionDialog({super.key, required this.title, required this.body, required this.actions});
  final String title;
  final String body;
  final List<DialogAction<T>> actions;

  /// Largura máxima do diálogo (Material 3).
  static const double maxWidth = 560;
  static const double _gap = 8;

  static TextStyle _textStyle(ThemeData t, DialogActionKind kind) {
    final base = t.textTheme.labelLarge ?? const TextStyle(fontSize: 14);
    final own = (kind == DialogActionKind.primary ? t.filledButtonTheme.style : t.textButtonTheme.style)?.textStyle?.resolve(const <WidgetState>{});
    return base.merge(own);
  }

  /// Largura de um botão: texto + o respiro lateral do Material (24 no de
  /// texto, o do tema no preenchido), nunca abaixo do mínimo de toque.
  static double _buttonWidth(BuildContext context, DialogAction<Object?> a) {
    final t = Theme.of(context);
    final w = TextFit.width(a.label, _textStyle(t, a.kind), scaler: MediaQuery.textScalerOf(context));
    if (a.kind == DialogActionKind.primary) {
      final pad = t.filledButtonTheme.style?.padding?.resolve(const <WidgetState>{})?.horizontal ?? 48;
      return math.max(64, w + pad);
    }
    return math.max(Ind.minTouch, w + 24);
  }

  /// Os botões cabem lado a lado em [width]?
  static bool fitsInRow(BuildContext context, List<DialogAction<Object?>> actions, double width) {
    var total = _gap * (actions.length - 1);
    for (final a in actions) {
      total += _buttonWidth(context, a) + 2; // folga de arredondamento
    }
    return total <= width;
  }

  Widget _button(DialogAction<T> a, BuildContext context, {required bool stretch}) {
    void tap() => Navigator.pop(context, a.value);
    final label = Text(a.label, textAlign: TextAlign.center);
    final Widget b = switch (a.kind) {
      DialogActionKind.primary => FilledButton(key: a.key, onPressed: tap, child: label),
      DialogActionKind.destructive => TextButton(key: a.key, style: TextButton.styleFrom(foregroundColor: Ind.textFor(Ind.alarm)), onPressed: tap, child: label),
      DialogActionKind.dismiss => TextButton(key: a.key, onPressed: tap, child: label),
    };
    return stretch ? SizedBox(width: double.infinity, child: b) : b;
  }

  @override
  Widget build(BuildContext context) {
    final dt = Theme.of(context).dialogTheme;
    // Ordem fixa pelo peso, não pela lista: na linha a principal fica na
    // ponta direita; empilhado, em cima.
    final inRow = [
      for (final k in DialogActionKind.values) ...actions.where((a) => a.kind == k),
    ];
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: dt.titleTextStyle),
              const SizedBox(height: 14),
              // Letra grande no aparelho: o texto rola, os botões ficam.
              Flexible(child: SingleChildScrollView(child: Text(body, style: dt.contentTextStyle))),
              const SizedBox(height: 22),
              LayoutBuilder(
                builder: (context, box) => fitsInRow(context, inRow, box.maxWidth)
                    ? Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                        for (final (i, a) in inRow.indexed) ...[
                          if (i > 0) const SizedBox(width: _gap),
                          _button(a, context, stretch: false),
                        ],
                      ])
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        for (final (i, a) in inRow.reversed.indexed) ...[
                          if (i > 0) const SizedBox(height: 6),
                          _button(a, context, stretch: true),
                        ],
                      ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Resposta do [confirmDiscard].
enum LeaveChoice {
  /// Salvar e sair.
  save,

  /// Sair jogando fora o que mudou.
  discard,

  /// Ficar no formulário.
  keep,
}

/// "Descartar alterações?" ao sair de um formulário com mudança não salva —
/// a mesma pergunta, com os mesmos três botões no mesmo lugar, em todo
/// cadastro (variável, calculada, câmera, regra, equipamento). [body] diz o
/// que se perde ("O que foi mudado nesta câmera ainda não foi salvo.").
/// Fechar o diálogo por fora é ficar.
Future<LeaveChoice> confirmDiscard(BuildContext context, {required String body}) async {
  final r = await showDialog<LeaveChoice>(
    context: context,
    builder: (_) => DecisionDialog<LeaveChoice>(
      key: const ValueKey('descartar-alteracoes'),
      title: 'Descartar alterações?',
      body: body,
      actions: const [
        DialogAction(key: ValueKey('continuar-editando'), label: 'Continuar editando', value: LeaveChoice.keep),
        DialogAction(key: ValueKey('descartar'), label: 'Descartar', value: LeaveChoice.discard, kind: DialogActionKind.destructive),
        DialogAction(key: ValueKey('salvar-e-sair'), label: 'Salvar', value: LeaveChoice.save, kind: DialogActionKind.primary),
      ],
    ),
  );
  return r ?? LeaveChoice.keep;
}

/// Título da barra de cima que mostra o nome inteiro: no tamanho do tema
/// numa linha quando cabe; senão numa linha um pouco menor (até
/// [twoLineSize]); senão em duas linhas (de [twoLineSize] até [minSize]). Só
/// um nome que nem assim cabe termina em "…" — "Cortadora — o…" no editor do
/// celular escondia justamente qual tela se está montando.
class AdaptiveTitle extends StatelessWidget {
  const AdaptiveTitle(this.text, {super.key, this.twoLineSize = 18, this.minSize = 15});
  final String text;
  final double twoLineSize;
  final double minSize;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      if (!w.isFinite || TextFit.fits(text, base, w, scaler: scaler)) {
        return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
      }
      for (var size = (base.fontSize ?? 22) - 1; size >= twoLineSize; size -= 1) {
        final s = base.copyWith(fontSize: size);
        if (TextFit.fits(text, s, w, scaler: scaler)) return Text(text, style: s, maxLines: 1, overflow: TextOverflow.ellipsis);
      }
      var style = base.copyWith(fontSize: minSize, height: 1.1);
      for (var size = twoLineSize; size >= minSize; size -= 1) {
        final s = base.copyWith(fontSize: size, height: 1.1);
        if (TextFit.fits(text, s, w, maxLines: 2, scaler: scaler)) {
          style = s;
          break;
        }
      }
      return Text(text, style: style, maxLines: 2, softWrap: true, overflow: TextOverflow.ellipsis);
    });
  }
}

/// Confirmação de ação destrutiva, com o que vai ser perdido escrito.
Future<bool> confirmDelete(BuildContext context, {required String title, required String body}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.delete_outline_rounded, color: Ind.alarm),
      title: Text(title),
      content: Text(body, style: const TextStyle(height: 1.4)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Ind.alarm, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Apagar'),
        ),
      ],
    ),
  );
  return r ?? false;
}
