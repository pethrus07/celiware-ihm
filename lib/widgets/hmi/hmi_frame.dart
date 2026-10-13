import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/tag.dart';
import '../../services/alarms/alarm_engine.dart';
import '../alarms/alarm_widgets.dart';
import '../../services/runtime/tag_store.dart';

/// Como a tela está sendo usada — os elementos leem daqui.
class HmiScreenContext extends InheritedWidget {
  const HmiScreenContext({
    super.key,
    required this.editMode,
    required this.readOnly,
    required this.confirmWrites,
    this.onNavigate,
    required super.child,
  });

  /// Abre outra tela do projeto (botão "Ir para tela" e "ao tocar, abrir").
  /// Nulo fora da tela em operação — no editor e na prévia o toque não navega.
  final void Function(String screenId)? onNavigate;

  /// Montando a tela: elementos mostram valor ao vivo mas não reagem a toque.
  final bool editMode;

  /// Tela só de acompanhamento: nenhum elemento grava.
  final bool readOnly;

  /// Pedir confirmação antes de gravar.
  final bool confirmWrites;

  static HmiScreenContext of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HmiScreenContext>() ??
      const HmiScreenContext(editMode: false, readOnly: true, confirmWrites: true, child: SizedBox());

  bool get canOperate => !editMode && !readOnly;

  @override
  bool updateShouldNotify(HmiScreenContext old) =>
      old.editMode != editMode || old.readOnly != readOnly || old.confirmWrites != confirmWrites || old.onNavigate != onNavigate;
}

/// Liga um widget a uma variável: entrega a [Tag] (do projeto) e a última
/// [TagReading] (do runtime), e redesenha só quando muda o que a tela mostra.
class TagBuilder extends StatelessWidget {
  const TagBuilder({super.key, required this.tagId, required this.builder});

  final String? tagId;
  final Widget Function(BuildContext context, Tag? tag, TagReading reading) builder;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.watch(context);
    final id = tagId;
    if (id == null) return builder(context, null, TagReading.waiting);
    final tag = scope.controller.project.tag(id);
    return _ReadingListener(
      listenable: scope.runtime.watch(id),
      builder: (context, reading) => builder(context, tag, reading),
    );
  }

  /// Duas leituras que aparecem iguais na tela: mesmo valor, mesma qualidade,
  /// mesmo motivo. O carimbo de hora não conta.
  static bool sameOnScreen(TagReading a, TagReading b) {
    if (identical(a, b)) return true;
    if (a.quality != b.quality || a.message != b.message) return false;
    final x = a.value, y = b.value;
    if (x is List && y is List) return listEquals(x, y);
    return x == y;
  }
}

/// O `ValueListenableBuilder` do [TagBuilder], com um filtro: a varredura
/// publica uma leitura nova a cada ciclo — mesmo valor, carimbo de hora
/// novo — e cada uma redesenhava o elemento. Com 48 elementos e varredura de
/// 500 ms, eram 96 elementos redesenhados por segundo para mostrar a mesma
/// coisa (GR-9). Agora só redesenha o que mudou. O motor de alarmes e o
/// registro de dados ouvem o runtime direto e continuam recebendo toda
/// leitura (o atraso de 1 s do alarme e o "leitura parada" dependem disso).
class _ReadingListener extends StatefulWidget {
  const _ReadingListener({required this.listenable, required this.builder});
  final ValueListenable<TagReading> listenable;
  final Widget Function(BuildContext context, TagReading reading) builder;

  @override
  State<_ReadingListener> createState() => _ReadingListenerState();
}

class _ReadingListenerState extends State<_ReadingListener> {
  late TagReading _shown;

  @override
  void initState() {
    super.initState();
    _shown = widget.listenable.value;
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(_ReadingListener old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(_changed);
      _shown = widget.listenable.value;
      widget.listenable.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final next = widget.listenable.value;
    if (TagBuilder.sameOnScreen(_shown, next)) return;
    setState(() => _shown = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _shown);
}

/// Moldura comum a todos os elementos: fundo, rótulo em placa e o
/// tratamento visual de problema — escrito uma vez só, para todos:
///
///   • sem variável ligada → borda tracejada âmbar + "Escolha a variável";
///   • variável de modelo com o endereço a configurar → a mesma borda +
///     "Endereço a configurar" (o runtime não lê; nada de valor inventado);
///   • aguardando primeira leitura → conteúdo normal, valor "---";
///   • sem comunicação → conteúdo **esmaecido** (último valor) + ícone;
///   • endereço inválido / configuração → borda vermelha + motivo.
class HmiFrame extends StatelessWidget {
  const HmiFrame({
    super.key,
    required this.label,
    required this.child,
    this.tag,
    this.reading,
    this.needsTag = true,
    this.padding = const EdgeInsets.fromLTRB(14, 12, 14, 12),
    this.color,
    this.border,
  });

  final String label;
  final Widget child;
  final Tag? tag;
  final TagReading? reading;
  final bool needsTag;
  final EdgeInsets padding;

  /// Cor do cartão (nulo = cartão padrão da paleta).
  final Color? color;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    final t = tag;
    if (t == null || t.alarms.isEmpty) return _build(context, null);
    // Variável com alarme: o cartão ouve o motor de alarmes e se marca
    // quando ele dispara — o alarme aparece onde o valor está.
    final engine = AppScope.of(context).alarms;
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final a = engine.forTag(t.id);
        final frame = _build(context, a);
        if (a == null) return frame;
        return Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(child: frame),
          Positioned(top: 8, right: 8, child: ElementAlarmBadge(entry: a)),
        ]);
      },
    );
  }

  Widget _build(BuildContext context, AlarmEntry? alarm) {
    final r = reading ?? TagReading.waiting;
    // Variável de modelo de tela com o endereço a configurar: também "falta
    // configurar" (cor de interação), não erro — o runtime nem tenta ler.
    final missing = (needsTag && tag == null) || (tag?.addressPending ?? false);
    final broken = !missing && (r.quality == TagQuality.addressError || r.quality == TagQuality.configError);
    final lost = !missing && r.quality == TagQuality.commLost;

    // Sem borda no estado normal (o fundo já separa); borda só quando ela
    // comunica algo: cor de interação = falta configurar, vermelho = erro,
    // cor da prioridade = alarme desta variável.
    final borderColor = missing
        ? Ind.accent
        : broken
            ? Ind.alarm
            : alarm != null && alarm.phase.active
                ? alarm.priority.color
                : border;
    final bw = missing || broken ? 1.6 : (alarm != null ? 2.0 : 1.2);

    Widget body = child;
    if (lost) body = Opacity(opacity: 0.38, child: body);

    // Elemento de 1 linha: rótulo ao lado, não em cima. Empilhar os dois numa
    // célula baixa espremia tudo.
    return LayoutBuilder(builder: (context, box) {
      if (box.maxHeight < 76 && label.isNotEmpty) {
        // Linha da grade fina (~26 dp): a largura é que aperta. Margem menor e
        // rótulo numa linha só deixam o número legível.
        final tight = box.maxHeight < 40;
        return _panel(
          borderColor: borderColor,
          width: bw,
          padding: EdgeInsets.symmetric(horizontal: tight ? 8 : 14),
          child: Row(children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * (tight ? 0.4 : 0.34)),
              child: Text(label.toUpperCase(), maxLines: tight ? 1 : 2, overflow: TextOverflow.ellipsis, style: Ind.tag(size: tight ? 10 : 11)),
            ),
            SizedBox(width: tight ? 6 : 10),
            Expanded(
              child: missing
                  ? _missingNotice()
                  : broken
                      ? _Notice(icon: Icons.report_gmailerrorred_rounded, text: r.message, color: Ind.alarm)
                      : body,
            ),
            if (lost) Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.wifi_off_rounded, size: 14, color: Ind.warn)),
          ]),
        );
      }
      return _stacked(borderColor, bw, lost, broken, missing, r, body);
    });
  }

  /// "Escolha a variável" — ou, na variável sem endereço, o aviso dela.
  Widget _missingNotice() =>
      tag == null ? _Notice(icon: Icons.link_off_rounded, text: 'Escolha a variável', color: Ind.accent) : const _PendingNotice();

  /// Cartão com o acabamento do sistema visual: camada, borda de 1 px,
  /// sombra em duas camadas e brilho no topo ([CardEdge]). A borda de
  /// estado (falta configurar / erro) substitui a borda neutra.
  Widget _panel({required EdgeInsets padding, required Widget child, Color? borderColor, double width = 1}) => CustomPaint(
        foregroundPainter: CardEdge(rev: Ind.revision),
        child: Container(
          decoration: Ind.card(color: color, border: borderColor, width: borderColor == null ? 1 : width),
          padding: padding,
          child: child,
        ),
      );

  Widget _stacked(Color? borderColor, double bw, bool lost, bool broken, bool missing, TagReading r, Widget body) {
    return _panel(
      borderColor: borderColor,
      width: bw,
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (label.isNotEmpty || lost || broken)
            Row(
              children: [
                Expanded(
                  child: Text(label.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: Ind.tag(size: 11)),
                ),
                if (lost) Tooltip(message: 'Sem comunicação — mostrando o último valor', child: Icon(Icons.wifi_off_rounded, size: 14, color: Ind.warn)),
                if (broken) Icon(Icons.error_outline_rounded, size: 14, color: Ind.alarm),
              ],
            ),
          Expanded(
            child: missing
                ? _missingNotice()
                : broken
                    ? _Notice(icon: Icons.report_gmailerrorred_rounded, text: r.message, color: Ind.alarm)
                    : body,
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

/// "Endereço a configurar" onde cabe inteiro; "A configurar" onde não cabe —
/// encolher a frase longa num cartão de meia largura do celular de 320 dp
/// deixava a letra com 9 dp.
class _PendingNotice extends StatelessWidget {
  const _PendingNotice();

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        // Ícone (16) e o espaço (6) do aviso.
        final text = _fitting(context, const ['Endereço a configurar', 'A configurar'], const TextStyle(fontWeight: FontWeight.w600, fontSize: 13), box.maxWidth - 22);
        return _Notice(icon: Icons.pending_outlined, text: text, color: Ind.accent);
      });
}

/// O aviso no rosto do botão cuja variável está com o endereço a configurar
/// (no lugar do modo, como "ESCOLHA A TELA"): "A CONFIGURAR", ou
/// "CONFIGURAR" no botão estreito do celular de 320 dp.
class PendingHint extends StatelessWidget {
  const PendingHint({super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final style = TextStyle(color: Ind.accent, fontSize: 11, fontWeight: FontWeight.w700);
        return FitText(_fitting(context, const ['A CONFIGURAR', 'CONFIGURAR'], style, box.maxWidth), style: style);
      });
}

/// O primeiro texto de [options] que cabe em [width] sem encolher (senão, o
/// último).
String _fitting(BuildContext context, List<String> options, TextStyle style, double width) {
  final full = DefaultTextStyle.of(context).style.merge(style);
  for (final o in options.take(options.length - 1)) {
    final painter = TextPainter(text: TextSpan(text: o, style: full), textDirection: TextDirection.ltr, maxLines: 1)..layout();
    final fits = painter.width <= width;
    painter.dispose();
    if (fits) return o;
  }
  return options.last;
}

/// Texto que encolhe para caber na célula (números grandes em elemento 1×1).
class FitText extends StatelessWidget {
  const FitText(this.text, {super.key, required this.style, this.alignment = Alignment.center});
  final String text;
  final TextStyle style;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: alignment,
        child: Text(text, style: style, maxLines: 1),
      );
}
