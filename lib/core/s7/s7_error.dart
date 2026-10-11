/// Erros da pilha Siemens S7.
///
/// Mesma ideia da pilha Modbus: cada falha é uma exceção tipada com uma
/// mensagem para o operador, e todas são [CommError] — o motor trata queda e
/// falta de resposta igual para qualquer protocolo.
///
/// A diferença importante do S7 é o **erro por item**: um pedido de leitura
/// leva várias variáveis, e o CLP responde item a item. Um DB que não existe
/// volta como [S7ItemError] só naquele item, sem derrubar os outros — o motor
/// marca só a variável errada.
library;

import '../comm/comm_error.dart';
import 's7_address.dart';

/// Base de todas as falhas S7.
sealed class S7Error extends CommError {
  const S7Error(super.message);
}

/// Por que a conexão foi recusada (quando foi).
enum S7Refusal {
  /// O IP respondeu "recusado" na hora: nada escuta na porta (porta errada,
  /// ou o aparelho não é um CLP Siemens).
  port,

  /// A porta 102 atendeu, mas o CLP recusou a conexão ISO (COTP). Quase
  /// sempre é rack/slot errados — o TSAP de destino sai deles.
  rackSlot,
}

/// Não foi possível abrir ou manter a conexão (IP errado, rede fora, porta
/// fechada, rack/slot errados, cabo/Wi-Fi caiu).
class S7ConnectionError extends S7Error {
  const S7ConnectionError(super.message, {this.refusal});

  final S7Refusal? refusal;

  /// O aparelho foi achado e recusou (porta ou rack/slot) — diferente de IP
  /// errado ou rede fora, que só estoura o tempo. Conferir Wi-Fi e IP nesse
  /// caso é perda de tempo do técnico.
  @override
  bool get refused => refusal != null;

  @override
  String get userMessage => switch (refusal) {
        S7Refusal.port => 'o CLP recusou a conexão nesta porta',
        S7Refusal.rackSlot => 'o CLP recusou a conexão: confira rack e slot',
        null => 'sem conexão com o CLP',
      };
}

/// Nenhuma resposta dentro do tempo-limite.
class S7Timeout extends S7Error {
  const S7Timeout(super.message);

  @override
  String get userMessage => 'sem resposta do CLP';
}

/// A resposta chegou, mas não bate com o pedido (cabeçalho, função,
/// quantidade de itens, tamanho).
class S7ProtocolError extends S7Error {
  const S7ProtocolError(super.message);

  @override
  String get userMessage => 'resposta inválida do CLP';
}

/// O pedido viola um limite antes de ir para a rede (ex.: lista vazia,
/// dado maior que o endereço). É erro de configuração, não de comunicação.
class S7RequestError extends S7Error {
  const S7RequestError(super.message);

  @override
  String get userMessage => 'pedido fora dos limites do S7';
}

/// A conexão foi aceita, mas o CLP recusou o pedido inteiro (erro no
/// cabeçalho da resposta, não num item).
///
/// No S7-1200/1500 este é o sintoma clássico de **PUT/GET desligado** (vem
/// assim de fábrica): COTP e Setup Communication passam, e toda leitura volta
/// com "função não disponível" (classe 0x81, código 0x04). Por isso a
/// mensagem já diz o que fazer no TIA Portal.
class S7RequestRefused extends S7Error {
  S7RequestRefused({required this.errorClass, required this.errorCode, String detail = ''})
      : super('CLP recusou o pedido: classe 0x${_hex(errorClass)}, código 0x${_hex(errorCode)}'
            '${detail.isEmpty ? '' : ' ($detail)'}');

  final int errorClass;
  final int errorCode;

  /// 0x8500: o pedido passou do tamanho de PDU negociado. Não é configuração
  /// do CLP; é defeito de quem montou o pedido.
  bool get pduOverflow => errorClass == 0x85 && errorCode == 0x00;

  @override
  String get userMessage => pduOverflow
      ? 'pedido maior que o CLP aceita'
      : 'o CLP recusou: habilite PUT/GET e desligue o acesso otimizado do DB';
}

/// O CLP respondeu ao pedido, mas recusou **um item** dele (código de
/// retorno ≠ 0xFF). Volta dentro do resultado da leitura/escrita, não derruba
/// os outros itens nem a conexão.
class S7ItemError extends S7Error {
  S7ItemError(this.address, this.code)
      : super('$address: ${_describe(address, code)} (código 0x${_hex(code)})');

  final S7Address address;

  /// Código de retorno do item no protocolo S7.
  final int code;

  static const int hardwareFault = 0x01;
  static const int accessDenied = 0x03;
  static const int addressOutOfRange = 0x05;
  static const int typeNotSupported = 0x06;
  static const int typeInconsistent = 0x07;
  static const int objectMissing = 0x0A;

  /// Endereço que não existe no CLP (DB inexistente ou além do fim da área).
  bool get isAddressError => code == addressOutOfRange || code == objectMissing;

  /// O CLP negou o acesso (proteção, PUT/GET desligado).
  bool get isAccessDenied => code == accessDenied;

  @override
  String get userMessage => _describe(address, code);

  static String _describe(S7Address a, int code) {
    final db = a.area == S7Area.db;
    switch (code) {
      case hardwareFault:
        return 'falha de hardware no CLP';
      case accessDenied:
        return 'o CLP negou o acesso: habilite PUT/GET e desligue o acesso otimizado do DB';
      case addressOutOfRange:
        // No 1200/1500, DB com acesso otimizado também cai aqui: o CLP não
        // expõe endereço absoluto dentro dele.
        return db ? 'endereço fora do DB (DB menor ou com acesso otimizado)' : 'endereço fora da área do CLP';
      case typeNotSupported:
        return 'tipo de dado não aceito pelo CLP';
      case typeInconsistent:
        return 'tamanho do dado não confere';
      case objectMissing:
        return db ? 'DB inexistente no CLP' : 'área inexistente no CLP';
      default:
        return 'o CLP recusou o endereço (código 0x${_hex(code)})';
    }
  }
}

String _hex(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
