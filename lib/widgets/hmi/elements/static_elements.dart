import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/image_util.dart';
import '../../../models/hmi_screen.dart';
import '../element_catalog.dart';
import '../hmi_frame.dart';

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
///
/// **Por etapa** (`source: byValue`): uma imagem por código de uma variável
/// — o "multiestado de imagem" das IHMs de mercado. O CLP põe o número da
/// etapa numa memória e a tela mostra como fazer aquela etapa. Um PDF
/// importado vira uma imagem por página (página 1 = código 1). Código sem
/// imagem mostra a imagem fixa, se houver, ou avisa o código — nunca uma
/// tela em branco que parece defeito.
class ImageElement extends StatelessWidget {
  const ImageElement({super.key, required this.element});
  final HmiElement element;

  bool get _byValue => element.prop<String>('source', 'fixed') == 'byValue';

  @override
  Widget build(BuildContext context) {
    if (!_byValue) return _picture(element.props['data'] as String?, placeholder: 'Escolha a imagem');
    final images = <int, String>{
      for (final i in (element.props['images'] as List? ?? const []))
        if (i is Map && i['value'] is num && i['data'] is String) (i['value'] as num).toInt(): i['data'] as String,
    };
    return TagBuilder(
      tagId: element.tagId,
      builder: (context, tag, r) {
        final raw = r.value;
        final code = raw is bool ? (raw ? 1 : 0) : (raw is num ? raw.round() : null);
        final data = images[code] ?? element.props['data'] as String?;
        final Widget body;
        if (images.isEmpty) {
          body = _picture(null, placeholder: 'Acrescente as imagens');
        } else if (code == null) {
          body = Center(child: Text('---', style: TextStyle(color: Ind.textMuted)));
        } else if (data == null) {
          body = Center(child: Text('SEM IMAGEM PARA O CÓDIGO $code', textAlign: TextAlign.center, style: TextStyle(color: Ind.warn, fontWeight: FontWeight.w700, fontSize: 12)));
        } else {
          body = _picture(data);
        }
        return HmiFrame(label: '', tag: tag, reading: r, padding: const EdgeInsets.all(4), child: body);
      },
    );
  }

  Widget _picture(String? data, {String placeholder = ''}) {
    if (data == null || data.isEmpty) {
      return Container(
        decoration: BoxDecoration(border: Border.all(color: Ind.accent, width: 1.6), borderRadius: BorderRadius.circular(Ind.radius)),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.add_photo_alternate_outlined, color: Ind.accent),
            const SizedBox(height: 4),
            Text(placeholder, style: TextStyle(color: Ind.accent, fontWeight: FontWeight.w600, fontSize: 12)),
          ]),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(Ind.radius),
      child: Image.memory(
        // Decodificar base64 a cada leitura (3×/s) gastaria bateria à toa
        // com imagem de página inteira: decodifica uma vez por conteúdo.
        decodeBase64Cached(data),
        fit: element.prop<String>('fit', 'contain') == 'cover' ? BoxFit.cover : BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => Center(child: Icon(Icons.broken_image_outlined, color: Ind.alarm)),
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
