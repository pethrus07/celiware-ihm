import 'package:flutter/foundation.dart';

import '../../../core/modbus/modbus_client.dart';
import '../../../core/opcua/opcua_client.dart';
import '../../../core/opcua/opcua_error.dart';
import '../../../core/opcua/opcua_status.dart';
import '../../../core/opcua/opcua_types.dart';
import '../../../models/device.dart';
import '../../../models/tag.dart';
import '../../net/local_network.dart';
import '../opcua_tag_codec.dart';
import '../tag_codec.dart';
import '../tag_store.dart';
import 'device_driver.dart';

/// OPC UA atrás do contrato de [DeviceDriver], em modo **varredura**, como o
/// Modbus e o S7.
///
/// A varredura vira **um** Read com todos os nós em uso (o mesmo nó em duas
/// variáveis vai uma vez só); o [OpcUaClient] divide pelo limite de nós por
/// pedido do servidor. O servidor responde nó a nó: um NodeId que não existe
/// volta como erro só dele — a variável fica marcada e as outras seguem, sem
/// precisar separar para achar a errada (diferente do Modbus).
///
/// Nó com StatusCode de "sem comunicação" (BadNoCommunication, comum em
/// Kepware e gateways com o CLP desligado) fica "sem comunicação" com o
/// último valor, como uma queda — mas só ele: o servidor está de pé.
///
/// Gravar usa o tipo do nó no servidor, aprendido na leitura (ou lido na
/// hora, na primeira gravação): Double num nó UInt16 o servidor recusa.
///
/// Subscription (o servidor avisar quando muda) fica para depois: a leitura
/// agrupada funciona com qualquer servidor e cabe no laço da sessão.
class OpcUaDriver extends DeviceDriver {
  OpcUaDriver(Device device) : client = clientFor(device);

  final OpcUaClient client;

  /// Tipo de cada nó no servidor, visto na última leitura.
  final Map<NodeId, UaType> _types = {};

  /// O cliente com a configuração do equipamento.
  static OpcUaClient clientFor(Device device) => OpcUaClient(
        host: device.host,
        port: device.port,
        path: device.opcua.path,
        username: device.opcua.username,
        password: device.opcua.password,
        responseTimeout: Duration(milliseconds: device.timeoutMs),
        // Wi-Fi da máquina sem internet + dados móveis: sem isto a conexão
        // sairia pelo 4G (ver LocalNetwork).
        beforeConnect: LocalNetwork.prepare,
      );

  @override
  ValueListenable<ModbusLinkState> get state => client.state;

  @override
  bool get isConnected => client.isConnected;

  @override
  Future<void> connect() => client.connect();

  @override
  Future<void> disconnect() => client.disconnect();

  @override
  Future<int> scan(List<Tag> tags, TagStore store, {required bool Function() stillCurrent}) async {
    // Depois de um "desconectar" pedido (saiu da tela) o cliente não
    // reconecta sozinho: quem volta a ler conecta.
    if (!client.isConnected) await client.connect();
    final plans = <(Tag, NodeId)>[];
    for (final t in tags) {
      try {
        plans.add((t, OpcUaTagCodec.plan(t)));
      } on TagValueError catch (e) {
        _publishProblem(store, t.id, e.message);
      }
    }
    if (plans.isEmpty) return 0;
    final nodes = {for (final p in plans) p.$2}.toList();
    final before = client.requests;
    final values = await client.read(nodes);
    if (!stillCurrent()) return client.requests - before;
    final byNode = {for (var i = 0; i < nodes.length; i++) nodes[i]: values[i]};
    final now = DateTime.now();
    for (final (t, node) in plans) {
      final dv = byNode[node]!;
      if (UaStatus.isBad(dv.status)) {
        final e = OpcUaNodeError(node, dv.status);
        if (e.isDeviceComm) {
          store.publish(t.id, store.read(t.id).degrade(TagQuality.commLost, e.userMessage));
        } else {
          store.publish(t.id, TagReading(quality: e.isAddressError ? TagQuality.addressError : TagQuality.configError, message: e.userMessage, at: now));
        }
        continue;
      }
      final type = dv.value.type;
      if (type != null) _types[node] = type;
      try {
        store.publish(t.id, TagReading(value: OpcUaTagCodec.decode(t, dv.value), quality: TagQuality.good, at: now));
      } on TagValueError catch (e) {
        store.publish(t.id, TagReading(quality: TagQuality.configError, message: e.message, at: now));
      }
    }
    return client.requests - before;
  }

  /// Erro de cadastro publicado uma vez só (a varredura roda a cada meio
  /// segundo; republicar redesenharia o elemento à toa).
  void _publishProblem(TagStore store, String id, String message) {
    final cur = store.read(id);
    if (cur.quality == TagQuality.configError && cur.message == message) return;
    store.publish(id, TagReading(quality: TagQuality.configError, message: message, at: DateTime.now()));
  }

  /// "Lendo agora" do cadastro e o teste com variável. Nó recusado sobe como
  /// o erro dele ("nó inexistente: ns=2;s=…").
  @override
  Future<Object> readOnce(Tag tag) async {
    final node = OpcUaTagCodec.plan(tag);
    if (!client.isConnected) await client.connect();
    final dv = (await client.read([node])).single;
    if (UaStatus.isBad(dv.status)) throw OpcUaNodeError(node, dv.status);
    final type = dv.value.type;
    if (type != null) _types[node] = type;
    return OpcUaTagCodec.decode(tag, dv.value);
  }

  @override
  Future<void> write(Tag tag, Object value) async {
    if (!tag.canWrite) throw TagValueError('"${tag.name}" é só leitura');
    if (tag.isArray) throw TagValueError('"${tag.name}" é uma lista; não é gravável pela tela');
    final node = OpcUaTagCodec.plan(tag);
    if (!client.isConnected) await client.connect();
    var type = _types[node];
    if (type == null) {
      // Primeira gravação sem leitura antes: pergunta o tipo ao servidor.
      final dv = (await client.read([node])).single;
      if (UaStatus.isBad(dv.status)) throw OpcUaNodeError(node, dv.status);
      type = dv.value.type;
      if (type == null) throw const TagValueError('o nó está sem valor no servidor; não dá para saber o tipo para gravar');
      _types[node] = type;
    }
    final variant = OpcUaTagCodec.encode(tag, type, value);
    final code = (await client.write([(node, variant)])).single;
    if (UaStatus.isBad(code)) {
      // O tipo mudou no servidor: a próxima gravação pergunta de novo.
      if (code & 0xFFFF0000 == UaStatus.badTypeMismatch) _types.remove(node);
      throw OpcUaNodeError(node, code, writing: true);
    }
  }

  /// Abre canal e sessão e lê o estado do servidor. As dicas saem do núcleo:
  /// segurança exigida, usuário recusado, endpoint errado.
  @override
  Future<void> ping() => client.ping();

  @override
  Future<void> dispose() => client.dispose();
}

/// Um filho de um nó, como a navegação mostra: pasta/objeto (entra) ou
/// variável (escolhe), com o valor de agora.
@immutable
class OpcUaBrowseItem {
  const OpcUaBrowseItem({required this.nodeId, required this.name, required this.isVariable, this.value, this.type, this.isArray = false, this.writable = false, this.problem});

  /// NodeId em texto ("ns=2;s=Maquina.Temperatura").
  final String nodeId;
  final String name;
  final bool isVariable;
  final Object? value;
  final UaType? type;
  final bool isArray;

  /// O usuário da sessão pode gravar (UserAccessLevel).
  final bool writable;

  /// Por que o valor não veio (StatusCode ruim), em português.
  final String? problem;

  /// Quantos valores o nó tem (lista do servidor); 1 = valor único.
  int get count => isArray && value is List ? (value as List).length : 1;

  /// O tipo de variável que combina com o nó.
  TagDataType get suggestedType => OpcUaTagCodec.suggestedType(type);

  /// Casas decimais do valor de agora (até 3): 72,5 → 1. Sem isto, um
  /// "número com vírgula" sem casas apareceria arredondado (73).
  int get decimals {
    final v = value;
    if (v is! double || !v.isFinite) return 0;
    final s = v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
    final dot = s.indexOf('.');
    return dot < 0 ? 0 : s.length - dot - 1;
  }
}

/// "Navegar e escolher": a árvore do servidor, um nível por vez, numa
/// conexão própria (fecha com a folha).
class OpcUaBrowser {
  OpcUaBrowser(Device device) : _client = OpcUaDriver.clientFor(device);

  final OpcUaClient _client;

  /// Os filhos de [nodeId] (nulo = pasta Objects). Na raiz, os objetos do
  /// próprio servidor (namespace 0: Server, Aliases, Locations…) ficam de
  /// fora — não são da máquina. Variáveis vêm com o valor e a permissão de
  /// gravar, lidos num pedido só.
  Future<List<OpcUaBrowseItem>> children([String? nodeId]) async {
    if (!_client.isConnected) await _client.connect();
    final node = nodeId == null ? NodeId.objectsFolder : NodeId.parse(nodeId);
    final seen = <NodeId>{};
    final refs = [
      for (final r in await _client.browse(node))
        if (r.isForward &&
            r.serverIndex == 0 &&
            (r.nodeClass == UaNodeClass.object || r.nodeClass == UaNodeClass.variable) &&
            (nodeId != null || r.nodeId.namespace != 0) &&
            seen.add(r.nodeId))
          r,
    ];
    final vars = [for (final r in refs) if (r.nodeClass == UaNodeClass.variable) r.nodeId];
    final attrs = vars.isEmpty
        ? const <UaDataValue>[]
        : await _client.readAttributes([for (final v in vars) ...[(v, UaAttribute.value), (v, UaAttribute.userAccessLevel)]]);
    final byNode = {for (var i = 0; i < vars.length; i++) vars[i]: (attrs[2 * i], attrs[2 * i + 1])};
    return [
      for (final r in refs)
        if (byNode[r.nodeId] case (final value, final access)?)
          OpcUaBrowseItem(
            nodeId: r.nodeId.toString(),
            name: r.name,
            isVariable: true,
            value: UaStatus.isBad(value.status) ? null : value.value.value,
            type: value.value.type,
            isArray: value.value.isArray,
            writable: access.value.value is int && (access.value.value as int) & UaAttribute.canWrite != 0,
            problem: UaStatus.isBad(value.status) ? OpcUaNodeError(r.nodeId, value.status).userMessage : null,
          )
        else
          OpcUaBrowseItem(nodeId: r.nodeId.toString(), name: r.name, isVariable: false),
    ];
  }

  Future<void> dispose() => _client.dispose();
}
