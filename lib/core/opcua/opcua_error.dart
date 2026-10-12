/// Erros da pilha OPC UA.
///
/// Mesma ideia do Modbus e do S7: cada falha é uma exceção tipada, com uma
/// mensagem para o operador, e todas são [CommError] — o motor trata queda e
/// falta de resposta igual para qualquer protocolo.
///
/// Como no S7, existe o **erro por nó**: uma leitura leva vários nós e o
/// servidor responde cada um com o seu StatusCode. Um nó que não existe volta
/// como [OpcUaNodeError] só nele, sem derrubar os outros.
library;

import '../comm/comm_error.dart';
import 'opcua_status.dart';
import 'opcua_types.dart';

/// As mensagens que pedem uma ação no servidor ou no cadastro. O "Testar
/// conexão" reconhece estas e mostra o que conferir.
abstract final class OpcUaHint {
  static const String security = 'o servidor só aceita conexão segura (Sign ou SignAndEncrypt), que esta versão ainda não faz';
  static const String user = 'o servidor recusou o usuário';
  static const String needsUser = 'o servidor não aceita conexão anônima: informe usuário e senha';
  static const String noUserName = 'o servidor não aceita usuário e senha';
  static const String endpoint = 'o servidor não tem esse endpoint: confira o caminho';
  static const String license = 'o servidor OPC UA recusou por licença';
}

/// Base de todas as falhas OPC UA.
sealed class OpcUaError extends CommError {
  const OpcUaError(super.message);
}

/// Por que a conexão foi recusada (quando foi).
enum OpcUaRefusal {
  /// O IP respondeu "recusado" na hora: nada escuta na porta.
  port,

  /// A porta atendeu, mas o servidor disse que o endpoint (o caminho depois
  /// da porta) não existe.
  endpoint,
}

/// Não foi possível abrir ou manter a conexão (IP errado, rede fora, porta
/// fechada, servidor que derrubou o canal ou a sessão).
class OpcUaConnectionError extends OpcUaError {
  const OpcUaConnectionError(super.message, {this.refusal});

  final OpcUaRefusal? refusal;

  @override
  bool get refused => refusal != null;

  @override
  String get userMessage => switch (refusal) {
        OpcUaRefusal.port => 'o servidor recusou a conexão nesta porta',
        OpcUaRefusal.endpoint => OpcUaHint.endpoint,
        null => 'sem conexão com o servidor OPC UA',
      };
}

/// Nenhuma resposta dentro do tempo-limite.
class OpcUaTimeout extends OpcUaError {
  const OpcUaTimeout(super.message);

  @override
  String get userMessage => 'sem resposta do servidor OPC UA';
}

/// A resposta chegou, mas não é o que a norma diz (mensagem cortada, tipo
/// inesperado, pedaço fora de ordem).
class OpcUaProtocolError extends OpcUaError {
  const OpcUaProtocolError(super.message);

  @override
  String get userMessage => 'resposta inválida do servidor OPC UA';
}

/// O pedido não pode ir para a rede (NodeId inválido, valor que não cabe).
/// É erro de configuração, não de comunicação.
class OpcUaRequestError extends OpcUaError {
  const OpcUaRequestError(super.message);

  @override
  String get userMessage => message;
}

/// O servidor recusou o pedido inteiro (ServiceFault ou ServiceResult ruim).
class OpcUaServiceError extends OpcUaError {
  OpcUaServiceError(this.code, String service) : super('$service: ${UaStatus.name(code)}');

  final int code;

  bool get _license => const {UaStatus.badLicenseExpired, UaStatus.badLicenseLimitsExceeded, UaStatus.badLicenseNotAvailable}.contains(code & 0xFFFF0000);

  /// O servidor foi achado e disse não (sessões demais, licença).
  @override
  bool get refused => _license || code & 0xFFFF0000 == UaStatus.badTooManySessions || code & 0xFFFF0000 == UaStatus.badTcpServerTooBusy;

  @override
  String get userMessage {
    if (_license) return OpcUaHint.license;
    return switch (code & 0xFFFF0000) {
      UaStatus.badTooManySessions => 'o servidor recusou: sessões demais abertas',
      UaStatus.badTcpServerTooBusy => 'o servidor está ocupado demais e recusou a conexão',
      UaStatus.badTooManyOperations => 'pedido maior que o servidor aceita',
      UaStatus.badServiceUnsupported => 'o servidor não faz esse serviço',
      UaStatus.badTimeout || UaStatus.badRequestTimeout => 'o servidor demorou demais para responder',
      _ => 'o servidor recusou o pedido (${UaStatus.name(code)})',
    };
  }
}

/// O servidor só oferece endpoints com segurança (Sign/SignAndEncrypt) —
/// esta versão do app só fala o modo None.
class OpcUaSecurityRequired extends OpcUaError {
  OpcUaSecurityRequired(this.offered) : super('o servidor só oferece: ${offered.isEmpty ? '(nada)' : offered.join(', ')}');

  /// "Basic256Sha256 · SignAndEncrypt", um por endpoint oferecido.
  final List<String> offered;

  @override
  bool get refused => true;

  @override
  String get userMessage => OpcUaHint.security;
}

/// Problema com a identificação do usuário na sessão.
enum OpcUaAuthProblem {
  /// Usuário ou senha errados (ou sem permissão).
  rejected,

  /// Sem usuário, e o servidor não aceita anônimo.
  needsUser,

  /// Com usuário, e o servidor não aceita usuário e senha.
  noUserName,

  /// O servidor pede a senha cifrada de um jeito que o app não faz.
  cipher,
}

class OpcUaAuthError extends OpcUaError {
  const OpcUaAuthError(this.problem, super.message, {this.policy});

  final OpcUaAuthProblem problem;

  /// Política de cifra da senha pedida (em [OpcUaAuthProblem.cipher]).
  final String? policy;

  /// O servidor foi achado e recusou: conferir Wi-Fi e IP é perda de tempo.
  @override
  bool get refused => true;

  @override
  String get userMessage => switch (problem) {
        OpcUaAuthProblem.rejected => OpcUaHint.user,
        OpcUaAuthProblem.needsUser => OpcUaHint.needsUser,
        OpcUaAuthProblem.noUserName => OpcUaHint.noUserName,
        OpcUaAuthProblem.cipher => 'o servidor pede a senha cifrada com ${UaSecurity.policyName(policy)}, que esta versão ainda não faz',
      };
}

/// O servidor respondeu ao pedido, mas recusou **um nó** dele (StatusCode
/// ruim naquele resultado). Volta dentro da leitura/escrita, sem derrubar os
/// outros nós nem a conexão.
class OpcUaNodeError extends OpcUaError {
  OpcUaNodeError(this.nodeId, this.code, {this.writing = false}) : super('$nodeId: ${UaStatus.name(code)}${writing ? ' (gravação)' : ''}');

  final NodeId nodeId;
  final int code;

  /// Veio de uma gravação: "sem acesso" ali é "não deixa gravar" (o asyncua
  /// responde BadUserAccessDenied a quem grava num nó só leitura).
  final bool writing;

  int get _c => code & 0xFFFF0000;

  /// O nó não existe no servidor (o "endereço inexistente" do Modbus).
  bool get isAddressError => _c == UaStatus.badNodeIdUnknown || _c == UaStatus.badNodeIdInvalid;

  /// O servidor está de pé, mas sem comunicação com o equipamento por trás
  /// dele: a variável fica "sem comunicação", com o último valor.
  bool get isDeviceComm => UaStatus.isDeviceComm(code);

  /// O servidor negou o acesso.
  @override
  bool get refused => _c == UaStatus.badUserAccessDenied || _c == UaStatus.badNotReadable || _c == UaStatus.badNotWritable;

  @override
  String get userMessage => switch (_c) {
        UaStatus.badNodeIdUnknown => 'nó inexistente: $nodeId',
        UaStatus.badNodeIdInvalid => 'NodeId inválido para o servidor: $nodeId',
        UaStatus.badAttributeIdInvalid => '$nodeId não é uma variável (não tem valor)',
        UaStatus.badNotReadable => 'o servidor não deixa ler $nodeId',
        UaStatus.badNotWritable => 'o servidor não deixa gravar em $nodeId',
        UaStatus.badUserAccessDenied => writing ? 'o servidor não deixa gravar em $nodeId' : 'o usuário não tem acesso a $nodeId',
        UaStatus.badTypeMismatch => 'o servidor recusou o tipo do valor',
        UaStatus.badOutOfRange => 'valor fora da faixa aceita pelo servidor',
        UaStatus.badWriteNotSupported => 'o servidor não aceita gravação neste nó',
        UaStatus.badWaitingForInitialData => 'o servidor ainda não tem o valor deste nó',
        UaStatus.badNoCommunication || UaStatus.badNotConnected || UaStatus.badCommunicationError => 'o servidor está sem comunicação com o equipamento',
        UaStatus.badDeviceFailure || UaStatus.badSensorFailure => 'o servidor acusa falha no equipamento',
        UaStatus.badOutOfService => 'o nó está fora de serviço no servidor',
        _ => 'o servidor recusou o nó (${UaStatus.name(code)})',
      };
}
