import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/tag.dart';
import '../../services/alarms/alarm_engine.dart';
import '../alarms/alarm_widgets.dart';
import '../../services/runtime/tag_store.dart';
import '../common/common.dart';

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

/// Elemento "pousado" na imagem de fundo da tela (item 62, sinótico): a
/// moldura ([HmiFrame]) não desenha o cartão, e todo texto de dentro ganha
/// um contorno na cor de fundo do tema — escuro no tema escuro, claro no
/// claro —, para o valor ser lido sobre qualquer cor do desenho.
///
/// Vale para o elemento com "Fundo transparente" (`props.transparent`) numa
/// tela com imagem de fundo, e para o texto fixo (que já não tem cartão)
/// nessa mesma tela. A tela decide ([HmiCanvas]); a moldura só obedece.
class HmiSurface extends InheritedWidget {
  const HmiSurface({super.key, required this.bare, required super.child});

  final bool bare;

  static bool bareOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<HmiSurface>()?.bare ?? false;

  /// Contorno do texto: a cor de fundo do tema em volta de cada letra.
  static List<Shadow> get halo => [
        Shadow(color: Ind.bg, blurRadius: 3),
        for (final o in const [Offset(1, 0), Offset(-1, 0), Offset(0, 1), Offset(0, -1)]) Shadow(color: Ind.bg, offset: o, blurRadius: 1.5),
      ];

  /// [child] pousado (com o contorno no texto) quando [bare]; senão, igual.
  static Widget wrap({required bool bare, required Widget child}) =>
      bare ? HmiSurface(bare: true, child: DefaultTextStyle.merge(style: TextStyle(shadows: halo), child: child)) : child;

  @override
  bool updateShouldNotify(HmiSurface old) => old.bare != bare;
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
    this.minBodyWidth = 0,
  });

  final String label;
  final Widget child;
  final Tag? tag;
  final TagReading? reading;
  final bool needsTag;
  final EdgeInsets padding;

  /// Largura que o corpo precisa para continuar legível com o rótulo ao
  /// lado (elemento de uma linha). Sem ela, o rótulo sobe e o corpo fica
  /// com a largura toda.
  final double minBodyWidth;

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
    final content = missing
        ? _missingNotice()
        : broken
            ? _Notice(icon: Icons.report_gmailerrorred_rounded, text: r.message, color: Ind.alarm)
            : body;

    return LayoutBuilder(builder: (context, box) {
      if (box.maxHeight < 76 && label.isNotEmpty) {
        return _oneLine(context, box, borderColor, bw, lost, broken || missing, content);
      }
      return _stacked(context, box, borderColor, bw, lost, broken, content);
    });
  }

  /// "Escolha a variável" — ou, na variável sem endereço, o aviso dela.
  Widget _missingNotice() =>
      tag == null ? _Notice(icon: Icons.link_off_rounded, text: 'Escolha a variável', color: Ind.accent) : const _PendingNotice();

  /// Elemento de uma linha de grade (lâmpada, indicador, barra 3×1 ou 6×1).
  /// Três arranjos, nesta ordem — o rótulo nunca acaba em "…" no tamanho
  /// padrão, de 320 a 412 dp:
  ///
  ///   1. **ao lado** (como num painel): o rótulo inteiro em até 40% da
  ///      largura, em até 2 linhas, e o corpo com pelo menos [minBodyWidth];
  ///   2. **em cima**: não cabendo ao lado, o rótulo ganha a largura toda numa
  ///      linha e o corpo (LED e estado, número) desce — no celular, "FACA
  ///      ACIONA…" com um "DESLIGADO" de 7 pt viraram rótulo e estado
  ///      inteiros e legíveis;
  ///   3. **ao lado, encolhido**: na grade fina (~26 dp de altura) não há
  ///      altura para dois andares; o rótulo encolhe até 75% para caber.
  Widget _oneLine(BuildContext context, BoxConstraints box, Color? borderColor, double bw, bool lost, bool notice, Widget content) {
    final scaler = MediaQuery.textScalerOf(context);
    final h = box.maxHeight;
    final tight = h < 40;
    final hPad = tight ? 8.0 : 14.0;
    final gap = tight ? 6.0 : 10.0;
    final lostW = lost ? 20.0 : 0.0;
    final inner = box.maxWidth - 2 * hPad - lostW;
    final text = label.toUpperCase();
    final style = Ind.tag(size: tight ? 10 : 11);
    final lostIcon = Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.wifi_off_rounded, size: 14, color: Ind.warn));

    // 1. Ao lado: uma linha se couber no espaço; senão a menor largura em duas.
    final budget = inner * 0.4;
    final one = TextFit.width(text, style, scaler: scaler);
    final lines = one <= budget || tight ? 1 : 2;
    final need = lines == 1 ? one : TextFit.widthFor(text, style, 2, scaler: scaler);
    final bodyMin = notice ? 0.0 : minBodyWidth;
    if (need <= budget && inner - need - gap >= bodyMin) {
      return _panel(
        borderColor: borderColor,
        width: bw,
        padding: EdgeInsets.symmetric(horizontal: hPad),
        child: Row(children: [
          SizedBox(width: need + 1, child: Text(text, maxLines: lines, style: style)),
          SizedBox(width: gap),
          Expanded(child: content),
          if (lost) lostIcon,
        ]),
      );
    }

    // 2. Em cima: rótulo numa linha com a largura toda, corpo embaixo.
    if (h >= 36) {
      final (s, _, ok) = TextFit.arrange(text, style, inner, maxLines: 1, minScale: 0.7, scaler: scaler);
      return _panel(
        borderColor: borderColor,
        width: bw,
        padding: EdgeInsets.fromLTRB(hPad, 5, hPad, 5),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(text, maxLines: 1, overflow: ok ? TextOverflow.clip : TextOverflow.ellipsis, style: s)),
            if (lost) lostIcon,
          ]),
          const SizedBox(height: 2),
          Expanded(child: content),
        ]),
      );
    }

    // 3. Grade fina: ao lado, com o rótulo encolhido para caber.
    final w = math.min(one, inner * 0.45);
    final (s, _, ok) = TextFit.arrange(text, style, w, maxLines: 1, scaler: scaler);
    return _panel(
      borderColor: borderColor,
      width: bw,
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Row(children: [
        SizedBox(width: w + 1, child: Text(text, maxLines: 1, overflow: ok ? TextOverflow.clip : TextOverflow.ellipsis, style: s)),
        SizedBox(width: gap),
        Expanded(child: content),
        if (lost) lostIcon,
      ]),
    );
  }

  /// Cartão com o acabamento do sistema visual: camada, borda de 1 px,
  /// sombra em duas camadas e brilho no topo ([CardEdge]). A borda de
  /// estado (falta configurar / erro) substitui a borda neutra.
  ///
  /// "Fundo transparente" sobre a imagem da tela ([HmiSurface]): sem cartão,
  /// sem tinta e sem borda — só a borda de problema (falta configurar, erro,
  /// alarme), que comunica estado. O texto ganha o contorno do [HmiSurface].
  Widget _panel({required EdgeInsets padding, required Widget child, Color? borderColor, double width = 1}) => Builder(builder: (context) {
        if (HmiSurface.bareOf(context)) {
          final problem = borderColor != null && borderColor != border;
          return Container(
            decoration: problem ? BoxDecoration(borderRadius: BorderRadius.circular(Ind.radius), border: Border.all(color: borderColor, width: width)) : null,
            padding: padding,
            child: child,
          );
        }
        return CustomPaint(
          foregroundPainter: CardEdge(rev: Ind.revision),
          child: Container(
            decoration: Ind.card(color: color, border: borderColor, width: borderColor == null ? 1 : width),
            padding: padding,
            child: child,
          ),
        );
      });

  /// Rótulo em cima, corpo embaixo (elemento de duas linhas de grade ou
  /// mais). Rótulo longo ("TEMPERATURA DO MOTOR" num 3×2 de 320 dp) encolhe
  /// um pouco ou vai para duas linhas antes de pensar em "…".
  Widget _stacked(BuildContext context, BoxConstraints box, Color? borderColor, double bw, bool lost, bool broken, Widget content) {
    final icons = (lost ? 14.0 : 0.0) + (broken ? 14.0 : 0.0);
    final width = box.maxWidth - padding.horizontal - icons;
    final text = label.toUpperCase();
    // Duas linhas só quando sobra altura para o corpo (~40 dp).
    final room = box.maxHeight - padding.vertical;
    final (style, lines, ok) = label.isEmpty
        ? (Ind.tag(size: 11), 1, true)
        : TextFit.arrange(text, Ind.tag(size: 11), width, maxLines: room >= 58 ? 2 : 1, scaler: MediaQuery.textScalerOf(context));
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
                  child: Text(text, maxLines: lines, overflow: ok ? TextOverflow.clip : TextOverflow.ellipsis, style: style),
                ),
                if (lost) Tooltip(message: 'Sem comunicação — mostrando o último valor', child: Icon(Icons.wifi_off_rounded, size: 14, color: Ind.warn)),
                if (broken) Icon(Icons.error_outline_rounded, size: 14, color: Ind.alarm),
              ],
            ),
          Expanded(child: content),
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
