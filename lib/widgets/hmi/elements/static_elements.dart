import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/hmi_screen.dart';
import '../element_catalog.dart';

/// Texto fixo: título de seção, observação, identificação da linha.
class LabelElement extends StatelessWidget {
  const LabelElement({super.key, required this.element});
  final HmiElement element;

  @override
  Widget build(BuildContext context) {
    final e = element;
    final size = switch (e.prop<String>('size', 'm')) { 's' => 14.0, 'l' => 28.0, _ => 19.0 };
    final center = e.prop<String>('align', 'left') == 'center';
    return Align(
      alignment: center ? Alignment.center : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          e.prop<String>('text', ''),
          textAlign: center ? TextAlign.center : TextAlign.left,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w700, fontSize: size, color: Ind.text, letterSpacing: 0.5),
        ),
      ),
    );
  }
}

/// Imagem embutida no projeto (base64): foto da máquina, esquema, logotipo.
///
/// Fica **dentro** do arquivo do projeto de propósito — exportar e mandar para
/// outro celular leva a imagem junto, sem arquivo solto para se perder. O
/// editor reduz a imagem antes de embutir (ver [ElementConfigSheet]).
class ImageElement extends StatelessWidget {
  const ImageElement({super.key, required this.element});
  final HmiElement element;

  @override
  Widget build(BuildContext context) {
    final data = element.props['data'];
    if (data is! String || data.isEmpty) {
      return Container(
        decoration: BoxDecoration(border: Border.all(color: Ind.accent, width: 1.6), borderRadius: BorderRadius.circular(Ind.radius)),
        child: const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.add_photo_alternate_outlined, color: Ind.accent),
            SizedBox(height: 4),
            Text('Escolha a imagem', style: TextStyle(color: Ind.accent, fontWeight: FontWeight.w600, fontSize: 12)),
          ]),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(Ind.radius),
      child: Image.memory(
        base64Decode(data),
        fit: element.prop<String>('fit', 'contain') == 'cover' ? BoxFit.cover : BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined, color: Ind.alarm)),
      ),
    );
  }
}

/// Elemento de tipo que esta versão não conhece (arquivo de versão mais nova).
/// Aparece como placa neutra e é preservado ao salvar.
class UnknownElement extends StatelessWidget {
  const UnknownElement({super.key, required this.element});
  final HmiElement element;

  @override
  Widget build(BuildContext context) {
    final info = ElementCatalog.of(ElementType.unknown);
    return Container(
      decoration: BoxDecoration(color: Ind.surface, borderRadius: BorderRadius.circular(Ind.radius), border: Border.all(color: Ind.line)),
      child: Center(child: Tooltip(message: info.description, child: Icon(info.icon, color: Ind.textMuted))),
    );
  }
}
