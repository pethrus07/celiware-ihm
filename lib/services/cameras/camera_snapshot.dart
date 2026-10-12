// Foto da câmera pela URL HTTP (CM-4): um JPEG na hora, para guardar ou
// mandar. Basic e Digest (o padrão de Hikvision e Intelbras) pelo próprio
// HttpClient do Dart.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../models/camera.dart';
import '../net/local_network.dart';

/// Foto que não veio, com o motivo em palavras.
class SnapshotError implements Exception {
  const SnapshotError(this.message);
  final String message;

  @override
  String toString() => message;
}

class CameraSnapshot {
  CameraSnapshot._();

  /// Foto maior que isto não é foto de câmera (proteção contra resposta errada).
  static const maxBytes = 12 * 1024 * 1024;

  static Future<Uint8List> fetch(String url, {String user = '', String? password, Duration timeout = const Duration(seconds: 6)}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || CameraUrl.httpError(url) != null) throw const SnapshotError('o endereço da foto não está certo');
    await LocalNetwork.prepare(uri.host);
    final client = HttpClient()..connectionTimeout = timeout;
    if (user.isNotEmpty) {
      // Uma tentativa com a senha: se a câmera recusar de novo, o 401 volta
      // para cá em vez de o cliente insistir (câmera bloqueia o usuário).
      var tried = false;
      client.authenticate = (u, scheme, realm) async {
        if (tried) return false;
        tried = true;
        final creds = scheme.toLowerCase() == 'digest'
            ? HttpClientDigestCredentials(user, password ?? '')
            : HttpClientBasicCredentials(user, password ?? '');
        client.addCredentials(u, realm ?? '', creds);
        return true;
      };
    }
    try {
      final req = await client.getUrl(uri).timeout(timeout);
      final res = await req.close().timeout(timeout);
      if (res.statusCode == HttpStatus.unauthorized) {
        await res.drain<void>();
        throw const SnapshotError('a câmera recusou o usuário ou a senha');
      }
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>();
        throw SnapshotError('a câmera respondeu ${res.statusCode}: confira o endereço da foto');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > maxBytes) throw const SnapshotError('a resposta da câmera é grande demais para uma foto');
      }
      final bytes = builder.takeBytes();
      if (!isImage(bytes)) throw const SnapshotError('a câmera não mandou uma imagem: confira o endereço da foto');
      return bytes;
    } on TimeoutException {
      throw const SnapshotError('a câmera não respondeu a tempo');
    } on SocketException {
      throw const SnapshotError('não consegui falar com a câmera: confira o IP e o Wi-Fi');
    } on HttpException {
      throw const SnapshotError('a câmera respondeu algo que não é uma foto');
    } finally {
      client.close(force: true);
    }
  }

  /// JPEG ou PNG pelos primeiros bytes (câmera às vezes devolve uma página
  /// de erro em HTML com 200).
  static bool isImage(List<int> b) =>
      (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) ||
      (b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47);
}
