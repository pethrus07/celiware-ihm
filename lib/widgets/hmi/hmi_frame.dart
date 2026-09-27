import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/tag.dart';
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
/// [TagReading] (do runtime), e redesenha só quando ela muda.
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
    return ValueListenableBuilder<TagReading>(
      valueListenable: scope.runtime.watch(id),
      builder: (context, reading, _) => builder(context, tag, reading),
    );
  }
}

/// Moldura comum a todos os elementos: fundo, rótulo em placa e o
/// tratamento visual de problema — escrito uma vez só, para todos:
///
///   • sem variável ligada → borda tracejada âmbar + "Escolha a variável";
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
    final r = reading ?? TagReading.waiting;
    final missing = needsTag && tag == null;
    final broken = !missing && (r.quality == TagQuality.addressError || r.quality == TagQuality.configError);
    final lost = !missing && r.quality == TagQuality.commLost;

    // Sem borda no estado normal (o fundo já separa); borda só quando ela
    // comunica algo: âmbar = falta configurar, vermelho = erro.
    final borderColor = missing
        ? Ind.accent
        : broken
            ? Ind.alarm
            : border;

    Widget body = child;
    if (lost) body = Opacity(opacity: 0.38, child: body);

    // Elemento de 1 linha: rótulo ao lado, não em cima. Empilhar os dois numa
    // célula baixa espremia tudo.
    return LayoutBuilder(builder: (context, box) {
      if (box.maxHeight < 76 && label.isNotEmpty) {
        return _panel(
          borderColor: borderColor,
          width: missing || broken ? 1.6 : 1.2,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * 0.34),
              child: Text(label.toUpperCase(), maxLines: 2, overflow: TextOverflow.ellipsis, style: Ind.tag(size: 11)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: missing
                  ? _Notice(icon: Icons.link_off_rounded, text: 'Escolha a variável', color: Ind.accent)
                  : broken
                      ? _Notice(icon: Icons.report_gmailerrorred_rounded, text: r.message, color: Ind.alarm)
                      : body,
            ),
            if (lost) Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.wifi_off_rounded, size: 14, color: Ind.warn)),
          ]),
        );
      }
      return _stacked(borderColor, lost, broken, missing, r, body);
    });
  }

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

  Widget _stacked(Color? borderColor, bool lost, bool broken, bool missing, TagReading r, Widget body) {
    return _panel(
      borderColor: borderColor,
      width: missing || broken ? 1.6 : 1.2,
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
                ? _Notice(icon: Icons.link_off_rounded, text: 'Escolha a variável', color: Ind.accent)
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
