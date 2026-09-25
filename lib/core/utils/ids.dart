import 'dart:math';

final Random _rng = Random.secure();

/// Identificador curto e único o bastante para itens do projeto
/// ("t_lz3k9q_4f2a"). Prefixo ajuda a ler o arquivo exportado a olho.
String newId(String prefix) {
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rand = _rng.nextInt(0xFFFFFF).toRadixString(36).padLeft(5, '0');
  return '${prefix}_${time}_$rand';
}
