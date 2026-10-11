import '../comm/comm_error.dart';

/// Falha de comunicação com o broker MQTT (ou com o equipamento atrás dele).
///
/// É um [CommError] como os do Modbus: a sessão marca as variáveis "sem
/// comunicação" com o último valor esmaecido e tenta de novo com espera
/// crescente. As mensagens já vêm prontas para o operador porque a
/// biblioteca MQTT só devolve exceções genéricas ("NoConnectionException").
class MqttCommError extends CommError {
  const MqttCommError(super.message, this.userMessage, {this.refused = false});

  @override
  final String userMessage;

  /// O broker foi achado e disse não (porta sem broker, usuário/senha, ID do
  /// cliente). A rede está certa — não adianta mandar conferir Wi-Fi e IP.
  @override
  final bool refused;

  static const String badCredentials = 'o broker recusou o usuário ou a senha';
  static const String deviceOffline = 'o equipamento se desconectou do broker';

  const MqttCommError.timeout(String detail) : this(detail, 'sem resposta do broker');
  const MqttCommError.noConnection(String detail) : this(detail, 'sem conexão com o broker');
  const MqttCommError.refusedPort(String detail) : this(detail, 'o broker recusou a conexão nesta porta', refused: true);
  const MqttCommError.credentials(String detail) : this(detail, badCredentials, refused: true);
  const MqttCommError.dropped() : this('conexão com o broker caiu', 'a conexão com o broker caiu');

  /// O testamento (LWT) do equipamento chegou: o broker está de pé, quem caiu
  /// foi a máquina.
  const MqttCommError.offline(String topic) : this('LWT em $topic', deviceOffline);
}
