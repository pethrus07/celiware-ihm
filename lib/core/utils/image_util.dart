// Imagens embutidas no projeto: reduzir antes de guardar e decodificar uma vez só.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Reduz uma imagem para caber no projeto e devolve PNG em base64.
///
/// Foto de celular tem 3–8 MB; embutida em base64 incharia o arquivo do
/// projeto (que vai por WhatsApp) e a memória do app. [maxSide] px no maior
/// lado é nítido para qualquer elemento de tela e fica na casa dos 100–400 KB.
/// Usa só `dart:ui` — sem pacote extra de imagem.
Future<String> shrinkToBase64Png(Uint8List bytes, {int maxSide = 900}) async => (await shrinkImage(bytes, maxSide: maxSide)).data;

/// O mesmo que [shrinkToBase64Png], devolvendo também a largura e a altura
/// da imagem guardada (a imagem de fundo da tela precisa da proporção sem
/// decodificar nada).
Future<({String data, int width, int height})> shrinkImage(Uint8List bytes, {int maxSide = 900}) async {
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
  final size = (width: image.width, height: image.height);
  image.dispose();
  codec.dispose();
  if (data == null) throw const FormatException('Imagem ilegível');
  return (data: base64Encode(data.buffer.asUint8List()), width: size.width, height: size.height);
}

// Decodificar base64 a cada desenho gastaria bateria à toa com imagem de
// página inteira (e trocaria os bytes da imagem, que redecodifica e pisca):
// guarda as últimas decodificadas. Usado pelo elemento imagem e pelo fundo.
final _cache = <String, Uint8List>{};

/// Bytes de uma imagem em base64, decodificados uma vez só por conteúdo.
Uint8List decodeBase64Cached(String b64) {
  final key = '${b64.length}:${b64.hashCode}';
  final hit = _cache[key];
  if (hit != null) return hit;
  if (_cache.length > 40) _cache.remove(_cache.keys.first);
  return _cache[key] = base64Decode(b64);
}
