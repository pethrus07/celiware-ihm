import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Reduz uma imagem para caber no projeto e devolve PNG em base64.
///
/// Foto de celular tem 3–8 MB; embutida em base64 incharia o arquivo do
/// projeto (que vai por WhatsApp) e a memória do app. [maxSide] px no maior
/// lado é nítido para qualquer elemento de tela e fica na casa dos 100–400 KB.
/// Usa só `dart:ui` — sem pacote extra de imagem.
Future<String> shrinkToBase64Png(Uint8List bytes, {int maxSide = 900}) async {
  final probe = await ui.instantiateImageCodec(bytes);
  final first = (await probe.getNextFrame()).image;
  final w = first.width, h = first.height;
  first.dispose();
  probe.dispose();

  final scale = (w > h ? maxSide / w : maxSide / h).clamp(0.0, 1.0);
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: (w * scale).round().clamp(1, maxSide),
    targetHeight: (h * scale).round().clamp(1, maxSide),
  );
  final image = (await codec.getNextFrame()).image;
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  codec.dispose();
  if (data == null) throw const FormatException('Imagem ilegível');
  return base64Encode(data.buffer.asUint8List());
}
