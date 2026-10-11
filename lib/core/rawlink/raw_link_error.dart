/// Erros do protocolo cru (Arduino, ESP, balança, leitor por TCP/UDP/serial).
///
/// São [CommError] como os do Modbus: a sessão trata queda e silêncio do
/// mesmo jeito para qualquer protocolo ("sem comunicação", último valor
/// esmaecido). O que muda é o texto para o operador — aqui não existe
/// "resposta Modbus", existe "mensagem do equipamento".
library;

import '../comm/comm_error.dart';

sealed class RawLinkError extends CommError {
  const RawLinkError(super.message);
}

/// O cano (socket TCP, UDP, porta serial) não abriu ou caiu.
class RawConnectionError extends RawLinkError {
  const RawConnectionError(super.message, {this.refused = false});

  /// Ver `ModbusConnectionError.refused`: o aparelho existe, nada escuta na
  /// porta. Só faz sentido em TCP — UDP não tem conexão para recusar.
  @override
  final bool refused;

  @override
  String get userMessage => refused ? 'o equipamento recusou a conexão nesta porta' : 'sem conexão com o equipamento';
}

/// O equipamento não mandou mensagem válida dentro do prazo: não respondeu ao
/// pedido (polling) ou parou de transmitir (streaming).
class RawTimeout extends RawLinkError {
  const RawTimeout(super.message);

  @override
  String get userMessage => 'sem mensagem do equipamento';
}

/// O perfil de mensagem não fecha (regex inválida, tamanho impossível,
/// modelo de comando sem o campo). É erro de configuração, não de
/// comunicação: tentar de novo não resolve.
class RawProfileError extends RawLinkError {
  const RawProfileError(super.message);

  @override
  String get userMessage => 'perfil de mensagem inválido: $message';
}

/// O comando não pôde ser montado com o valor pedido (não cabe no tipo,
/// falta um marcador). Nada foi enviado.
class RawCommandError extends RawLinkError {
  const RawCommandError(super.message);

  @override
  String get userMessage => message;
}
