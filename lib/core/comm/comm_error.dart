/// Falha de comunicação com um equipamento — de qualquer protocolo.
///
/// O motor ([DeviceSession]) e as telas tratam falha por aqui, sem saber se
/// por baixo é Modbus, MQTT ou Siemens: queda vira "sem comunicação" com o
/// último valor esmaecido, e [userMessage] é o que o operador lê. Cada
/// protocolo tem as suas subclasses (ex.: `ModbusError`).
library;

abstract class CommError implements Exception {
  const CommError(this.message);

  /// Detalhe técnico, para o log.
  final String message;

  /// Texto curto para o operador (pt-BR, sem jargão de socket).
  String get userMessage;

  /// O aparelho foi achado e recusou a conexão (porta ou serviço errados) —
  /// diferente de IP errado ou rede fora, que só estoura o tempo.
  bool get refused => false;

  @override
  String toString() => '$runtimeType: $message';
}
