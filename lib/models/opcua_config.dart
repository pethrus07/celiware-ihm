// Configuração OPC UA: a do equipamento (servidor, caminho do endpoint,
// usuário) e a da variável (o NodeId do nó).
//
// Como no S7 e no MQTT, fica fora de Device e Tag para os dois continuarem com
// cara de Modbus no arquivo de quem não usa OPC UA: os campos daqui só vão
// para o JSON quando o equipamento é OPC UA ou a variável tem NodeId.

import 'package:flutter/foundation.dart';

import '../core/opcua/opcua_client.dart' show OpcUaClient;
import '../core/opcua/opcua_types.dart';

/// Como o app fala com um servidor OPC UA. O IP e a porta continuam em
/// `Device.host` / `Device.port` (4840); o endereço completo é
/// `opc.tcp://IP:porta` + [path].
///
/// Segurança: só o modo None nesta versão (sem campo — quando Sign entrar,
/// entra o campo com None de padrão e o arquivo de hoje continua valendo).
@immutable
class OpcUaConfig {
  const OpcUaConfig({this.path = '', this.username = '', this.password = ''});

  /// Porta padrão do OPC UA (registrada na IANA). Kepware usa 49320.
  static const int defaultPort = 4840;

  /// O que vem depois da porta no endereço ("/OPCUA/SimulationServer").
  /// Vazio na maioria dos CLPs (S7-1500, CODESYS).
  final String path;

  /// Vazio = anônimo.
  final String username;
  final String password;

  bool get anonymous => username.isEmpty;

  /// "opc.tcp://192.168.0.10:4840/OPCUA/SimulationServer".
  String endpointUrl(String host, int port) => 'opc.tcp://$host:$port${OpcUaClient.normalizePath(path)}';

  /// Lê um endereço colado inteiro ("opc.tcp://10.0.0.5:4840/caminho"):
  /// IP, porta e caminho. Nulo se o texto não começa com opc.tcp://.
  static ({String host, int port, String path})? parseEndpoint(String text) {
    final t = text.trim();
    if (!t.toLowerCase().startsWith('opc.tcp://')) return null;
    final rest = t.substring('opc.tcp://'.length);
    final slash = rest.indexOf('/');
    final authority = slash < 0 ? rest : rest.substring(0, slash);
    final path = slash < 0 ? '' : rest.substring(slash);
    if (authority.isEmpty) return null;
    // [IPv6]:porta não aparece em CLP; host:porta ou só host.
    final colon = authority.lastIndexOf(':');
    final port = colon < 0 ? null : int.tryParse(authority.substring(colon + 1));
    final host = colon < 0 || port == null ? authority : authority.substring(0, colon);
    return (host: host, port: port ?? defaultPort, path: OpcUaClient.normalizePath(path));
  }

  /// Só o que difere do padrão: servidor anônimo na raiz não grava nada.
  Map<String, dynamic> toJson() => {
        if (path.isNotEmpty) 'path': path,
        if (username.isNotEmpty) 'username': username,
        if (password.isNotEmpty) 'password': password,
      };

  factory OpcUaConfig.fromJson(Map<String, dynamic> j) => OpcUaConfig(
        path: OpcUaClient.normalizePath((j['path'] as String?) ?? ''),
        username: (j['username'] as String?) ?? '',
        password: (j['password'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) => other is OpcUaConfig && other.path == path && other.username == username && other.password == password;

  @override
  int get hashCode => Object.hash(path, username, password);
}

/// Onde mora uma variável OPC UA: o NodeId do nó, como no UaExpert, no
/// Kepware e no TIA Portal ("ns=2;s=Maquina.Temperatura", "ns=3;i=1001",
/// `ns=3;s="DB1"."Velocidade"`).
///
/// Guarda o texto: é o que a pessoa conhece e o que a lista mostra. O tipo
/// do valor quem diz é o servidor — a variável só escolhe como mostrar
/// (`Tag.dataType`).
@immutable
class OpcUaTagAddress {
  const OpcUaTagAddress(this.nodeId);

  /// O NodeId já arrumado por [normalize] (texto inválido fica como veio).
  final String nodeId;

  /// O NodeId lido; nulo se o texto não for um NodeId.
  NodeId? get parsed => NodeId.tryParse(nodeId);

  bool get isValid => parsed != null;

  /// O texto canônico: " NS=2; s=Temp" → "ns=2;s=Temp", "ns=0;i=85" → "i=85".
  /// Texto que não é NodeId volta só sem os espaços das pontas.
  static String normalize(String text) => NodeId.tryParse(text)?.toString() ?? text.trim();

  Map<String, dynamic> toJson() => {'nodeId': nodeId};

  factory OpcUaTagAddress.fromJson(Map<String, dynamic> j) => OpcUaTagAddress((j['nodeId'] as String?) ?? '');

  @override
  bool operator ==(Object other) => other is OpcUaTagAddress && other.nodeId == nodeId;

  @override
  int get hashCode => nodeId.hashCode;
}
