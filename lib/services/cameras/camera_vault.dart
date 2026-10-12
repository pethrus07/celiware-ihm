// Cofre das senhas das câmeras (CM-5). A senha nunca entra no projeto: o
// projeto guarda a chave ([IpCamera.secretRef]) e o cofre guarda a senha,
// cifrada com uma chave do Android Keystore (`flutter_secure_storage`).
//
// O arquivo cifrado fica fora do backup do Android (`res/xml/`): restaurado
// em outro aparelho, viria sem a chave do Keystore e não abriria.

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';

/// Onde as senhas das câmeras moram neste aparelho.
abstract class CameraVault {
  /// O cofre do app. Os testes trocam por um [MemoryCameraVault].
  static CameraVault instance = SecureCameraVault();

  /// A senha guardada para [ref]; nula se este aparelho não tem (projeto
  /// importado, cofre apagado).
  Future<String?> read(String ref);

  Future<void> write(String ref, String password);

  Future<void> delete(String ref);

  /// Apaga as senhas que o projeto não usa mais ([keep] = as chaves dele):
  /// câmera apagada, projeto trocado, importado ou restaurado.
  Future<void> prune(Set<String> keep);
}

/// O cofre de verdade: Android Keystore (AES-GCM com a chave protegida pelo
/// hardware quando o aparelho tem).
class SecureCameraVault implements CameraVault {
  static final Logger _log = Logger('CameraVault');
  static const _prefix = 'camera-senha:';
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String ref) async {
    try {
      return await _storage.read(key: '$_prefix$ref');
    } catch (e) {
      // Chave do Keystore perdida (troca de bloqueio de tela, restauração):
      // a senha é pedida de novo, em vez de travar a câmera.
      _log.warning('Não li a senha da câmera: $e');
      return null;
    }
  }

  @override
  Future<void> write(String ref, String password) => _storage.write(key: '$_prefix$ref', value: password);

  @override
  Future<void> delete(String ref) async {
    try {
      await _storage.delete(key: '$_prefix$ref');
    } catch (e) {
      _log.warning('Não apaguei a senha da câmera: $e');
    }
  }

  @override
  Future<void> prune(Set<String> keep) async {
    try {
      final all = await _storage.readAll();
      for (final key in all.keys) {
        if (key.startsWith(_prefix) && !keep.contains(key.substring(_prefix.length))) {
          await _storage.delete(key: key);
        }
      }
    } catch (e) {
      _log.warning('Não consegui limpar o cofre das câmeras: $e');
    }
  }
}

/// Cofre em memória: testes e plataformas sem cofre. Some com o app.
class MemoryCameraVault implements CameraVault {
  @visibleForTesting
  final Map<String, String> entries = {};

  @override
  Future<String?> read(String ref) async => entries[ref];

  @override
  Future<void> write(String ref, String password) async => entries[ref] = password;

  @override
  Future<void> delete(String ref) async => entries.remove(ref);

  @override
  Future<void> prune(Set<String> keep) async => entries.removeWhere((k, _) => !keep.contains(k));
}
