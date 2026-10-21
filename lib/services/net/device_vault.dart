// Cofre dos segredos de equipamento (senha do Basic e token dos equipamentos
// HTTP). Como o das câmeras (`CameraVault`, §5.7): a senha nunca entra no
// projeto; o projeto guarda a chave ([HttpConfig.secretRef]) e o cofre guarda
// a senha, cifrada com uma chave do Android Keystore (`flutter_secure_storage`).
//
// Prefixo próprio (`equipamento-segredo:`): o cofre das câmeras pode limpar
// as chaves dele sem tocar nestas.

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';

/// Onde as senhas e tokens dos equipamentos moram neste aparelho.
abstract class DeviceVault {
  /// O cofre do app. Os testes trocam por um [MemoryDeviceVault].
  static DeviceVault instance = SecureDeviceVault();

  /// Muda a cada gravação ou remoção: quem guardou a senha em memória (o
  /// driver HTTP, para não abrir o Keystore a cada leitura) lê de novo.
  static int revision = 0;

  /// O segredo guardado para [ref]; nulo se este aparelho não tem (projeto
  /// importado, cofre apagado).
  Future<String?> read(String ref);

  Future<void> write(String ref, String secret);

  Future<void> delete(String ref);
}

/// O cofre de verdade: Android Keystore (AES-GCM com a chave protegida pelo
/// hardware quando o aparelho tem).
class SecureDeviceVault implements DeviceVault {
  static final Logger _log = Logger('DeviceVault');
  static const _prefix = 'equipamento-segredo:';
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String ref) async {
    try {
      return await _storage.read(key: '$_prefix$ref');
    } catch (e) {
      // Chave do Keystore perdida (troca de bloqueio de tela, restauração):
      // o segredo é pedido de novo, em vez de travar o equipamento.
      _log.warning('Não li o segredo do equipamento: $e');
      return null;
    }
  }

  @override
  Future<void> write(String ref, String secret) async {
    await _storage.write(key: '$_prefix$ref', value: secret);
    DeviceVault.revision++;
  }

  @override
  Future<void> delete(String ref) async {
    try {
      await _storage.delete(key: '$_prefix$ref');
    } catch (e) {
      _log.warning('Não apaguei o segredo do equipamento: $e');
    }
    DeviceVault.revision++;
  }
}

/// Cofre em memória: testes e plataformas sem cofre. Some com o app.
class MemoryDeviceVault implements DeviceVault {
  @visibleForTesting
  final Map<String, String> entries = {};

  @override
  Future<String?> read(String ref) async => entries[ref];

  @override
  Future<void> write(String ref, String secret) async {
    entries[ref] = secret;
    DeviceVault.revision++;
  }

  @override
  Future<void> delete(String ref) async {
    entries.remove(ref);
    DeviceVault.revision++;
  }
}
