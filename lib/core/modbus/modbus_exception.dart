/// Erros da pilha Modbus.
///
/// A versão anterior do cliente (machine_monitor / InoRobot) devolvia lista
/// vazia em qualquer falha — o chamador não sabia se o endereço não existia,
/// se o CLP estava fora do ar ou se a resposta veio corrompida. Numa IHM
/// configurável pelo usuário essa distinção é o que permite mostrar "endereço
/// inválido" em vez de uma tela em branco. Por isso toda falha agora é uma
/// exceção tipada, e cada tipo vira uma mensagem diferente na interface.
library;

/// Base de todas as falhas Modbus.
sealed class ModbusError implements Exception {
  const ModbusError(this.message);

  final String message;

  /// Texto curto para mostrar ao operador (pt-BR, sem jargão de socket).
  String get userMessage;

  @override
  String toString() => '$runtimeType: $message';
}

/// O equipamento respondeu, mas recusou o pedido (resposta com bit 0x80).
///
/// É o caso típico de endereço fora do mapa: o CLP está vivo, a conexão está
/// boa, só aquele endereço/quantidade não existe.
class ModbusExceptionResponse extends ModbusError {
  ModbusExceptionResponse({required this.functionCode, required this.code})
      : super('Função 0x${functionCode.toRadixString(16)} recusada: '
            '${describe(code)} (código $code)');

  /// Código da função pedida (sem o bit 0x80).
  final int functionCode;

  /// Código de exceção Modbus (1..11).
  final int code;

  static const int illegalFunction = 0x01;
  static const int illegalDataAddress = 0x02;
  static const int illegalDataValue = 0x03;
  static const int serverDeviceFailure = 0x04;
  static const int acknowledge = 0x05;
  static const int serverDeviceBusy = 0x06;
  static const int gatewayPathUnavailable = 0x0A;
  static const int gatewayTargetFailed = 0x0B;

  static String describe(int code) {
    switch (code) {
      case illegalFunction:
        return 'função não suportada pelo equipamento';
      case illegalDataAddress:
        return 'endereço inexistente no equipamento';
      case illegalDataValue:
        return 'valor ou quantidade inválidos';
      case serverDeviceFailure:
        return 'falha interna do equipamento';
      case acknowledge:
        return 'pedido aceito, processamento demorado';
      case serverDeviceBusy:
        return 'equipamento ocupado';
      case gatewayPathUnavailable:
        return 'gateway sem caminho para o destino';
      case gatewayTargetFailed:
        return 'destino do gateway não respondeu';
      default:
        return 'exceção desconhecida';
    }
  }

  @override
  String get userMessage => describe(code);
}

/// Nenhuma resposta dentro do tempo-limite.
class ModbusTimeout extends ModbusError {
  const ModbusTimeout(super.message);

  @override
  String get userMessage => 'sem resposta do equipamento';
}

/// Não foi possível abrir ou manter o socket (IP errado, rede fora, porta
/// fechada, cabo/Wi-Fi caiu).
class ModbusConnectionError extends ModbusError {
  const ModbusConnectionError(super.message);

  @override
  String get userMessage => 'sem conexão com o equipamento';
}

/// A resposta chegou, mas não bate com o pedido (tamanho, função, protocolo).
class ModbusProtocolError extends ModbusError {
  const ModbusProtocolError(super.message);

  @override
  String get userMessage => 'resposta inválida do equipamento';
}

/// O pedido viola um limite do protocolo antes mesmo de ir para a rede
/// (ex.: mais de 125 registradores numa leitura). É erro de configuração, não
/// de comunicação.
class ModbusRequestError extends ModbusError {
  const ModbusRequestError(super.message);

  @override
  String get userMessage => 'pedido fora dos limites do Modbus';
}
