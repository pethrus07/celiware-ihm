import 'package:flutter/foundation.dart';

import '../../../core/modbus/modbus_client.dart';
import '../../../core/s7/s7_client.dart';
import '../../../models/device.dart';
import '../../../models/tag.dart';
import '../../net/local_network.dart';
import '../s7_tag_codec.dart';
import '../tag_codec.dart';
import '../tag_store.dart';
import 'device_driver.dart';

/// Siemens S7 ("S7 clássico", PUT/GET) atrás do contrato de [DeviceDriver],
/// em modo **varredura**, como o Modbus.
///
/// A varredura vira **uma** leitura de vários itens: as variáveis vizinhas
/// do mesmo DB viram um item só ([S7ScanPlanner]) e o [S7Client] divide os
/// itens no menor número de pedidos que cabe na PDU negociada com o CLP.
///
/// O CLP responde item a item, então um DB que não existe volta como erro
/// só daquele item: a variável dele fica marcada e as outras seguem. Se o
/// item com erro juntava várias variáveis, elas passam a ser lidas uma a uma
/// no ciclo seguinte para achar a errada — o mesmo isolamento do Modbus.
///
/// Queda, tempo esgotado, rack/slot errados e PUT/GET desligado são
/// `CommError` do núcleo, já com a mensagem do que fazer; a sessão marca
/// tudo "sem comunicação" com o último valor e tenta de novo.
class S7Driver extends DeviceDriver {
  S7Driver(Device device, {this.planner = const S7ScanPlanner()})
      : client = S7Client(
          host: device.host,
          port: device.port,
          rack: device.s7.rack,
          slot: device.s7.slot,
          responseTimeout: Duration(milliseconds: device.timeoutMs),
          // Wi-Fi da máquina sem internet + dados móveis: sem isto a conexão
          // sairia pelo 4G (ver LocalNetwork).
          beforeConnect: LocalNetwork.prepare,
        );

  final S7Client client;
  final S7ScanPlanner planner;
  final Set<String> _isolated = {};

  @override
  ValueListenable<ModbusLinkState> get state => client.state;

  @override
  bool get isConnected => client.isConnected;

  @override
  Future<void> connect() => client.connect();

  @override
  Future<void> disconnect() => client.disconnect();

  @override
  void tagsChanged(List<Tag> previous, List<Tag> current) {
    final before = {for (final t in previous) t.id: t};
    // Variável sumiu ou teve endereço/tipo corrigido → volta a ser juntada.
    _isolated.removeWhere((id) {
      final now = current.where((t) => t.id == id).firstOrNull;
      final old = before[id];
      return now == null || old == null || now.s7 != old.s7 || now.dataType != old.dataType || now.length != old.length;
    });
  }

  @override
  Future<int> scan(List<Tag> tags, TagStore store, {required bool Function() stillCurrent}) async {
    // Depois de um "desconectar" pedido (saiu da tela) o cliente não
    // reconecta sozinho: quem volta a ler conecta.
    if (!client.isConnected) await client.connect();
    final items = <(Tag, S7TagPlan)>[];
    for (final t in tags) {
      try {
        items.add((t, S7TagCodec.plan(t)));
      } on TagValueError catch (e) {
        _publishProblem(store, t.id, e.message);
      }
    }
    if (items.isEmpty) return 0;
    final blocks = planner.plan(items, isolated: _isolated);
    final before = client.requests;
    final results = await client.read([for (final b in blocks) b.address]);
    if (!stillCurrent()) return client.requests - before;
    final now = DateTime.now();
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final error = results[i].error;
      if (error != null) {
        if (block.members.length > 1) {
          // Algum endereço do item juntado não existe: separa para achar qual.
          _isolated.addAll(block.members.map((m) => m.$1.id));
          onWake?.call();
          continue;
        }
        store.publish(block.members.single.$1.id,
            TagReading(quality: error.isAddressError ? TagQuality.addressError : TagQuality.configError, message: error.userMessage, at: now));
        continue;
      }
      for (final (t, plan) in block.members) {
        try {
          store.publish(t.id, TagReading(value: S7TagCodec.decode(t, plan, block.bytesOf(plan, results[i].bytes!)), quality: TagQuality.good, at: now));
        } on TagValueError catch (e) {
          store.publish(t.id, TagReading(quality: TagQuality.configError, message: e.message, at: now));
        }
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

  /// "Lendo agora" do cadastro e o teste com variável. Item recusado pelo CLP
  /// sobe como o erro do item (DB inexistente, fora do DB, acesso negado).
  @override
  Future<Object> readOnce(Tag tag) async {
    final plan = S7TagCodec.plan(tag);
    if (!client.isConnected) await client.connect();
    final r = (await client.read([plan.address])).single;
    final e = r.error;
    if (e != null) throw e;
    return S7TagCodec.decode(tag, plan, r.bytes!);
  }

  @override
  Future<void> write(Tag tag, Object value) async {
    if (!tag.canWrite) throw TagValueError('"${tag.name}" é só leitura');
    if (tag.isArray) throw TagValueError('"${tag.name}" é uma lista; não é gravável pela tela');
    final item = S7TagCodec.encode(tag, S7TagCodec.plan(tag), value);
    if (!client.isConnected) await client.connect();
    final e = (await client.write([item])).single;
    if (e != null) throw e;
  }

  /// Conecta (COTP + Setup Communication) e lê MB0. As dicas saem do núcleo:
  /// "confira rack e slot" quando o CLP recusa a conexão ISO; "habilite
  /// PUT/GET…" quando ele aceita a conexão e recusa a leitura.
  @override
  Future<void> ping() => client.ping();

  @override
  Future<void> dispose() => client.dispose();
}
