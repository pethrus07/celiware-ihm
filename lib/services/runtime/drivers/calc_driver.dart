import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../../../core/modbus/modbus_client.dart';
import '../../../models/project.dart';
import '../../../models/tag.dart';
import '../../calc/calc_evaluator.dart';
import '../../calc/calc_graph.dart';
import '../tag_codec.dart';
import '../tag_store.dart';
import 'device_driver.dart';

/// A conta ainda não tem valor (entrada sem primeira leitura, taxa sem
/// histórico). Não é erro: o "Lendo agora" mostra em tom neutro.
class CalcWaiting extends TagValueError {
  const CalcWaiting(super.message);
}

/// O "driver" do equipamento virtual das calculadas ([CalcDevice]).
///
/// Não fala com rede nenhuma: lê o [TagStore], onde os outros drivers
/// publicam, e publica o resultado das contas lá mesmo. Por isso a variável
/// calculada se comporta como qualquer outra — elemento de tela, alarme,
/// narração e registro de dados não sabem a diferença.
///
/// Trabalha como o `MqttDriver`, em modo assinatura: a varredura reconcilia
/// quem ouvir (as entradas das contas em uso) e recalcula tudo — a cada
/// `pollMs`, para a taxa andar com o relógio e o registro ver leitura fresca —
/// e cada entrada nova recalcula na hora (juntando, numa microtarefa, as
/// entradas que chegam no mesmo bloco de leitura). Fora da varredura publica
/// só o que mudou.
///
/// Quem garante que as entradas são lidas é o `HmiRuntime`: uma calculada em
/// uso põe as entradas dela em uso também (`CalcGraph.expand`).
class CalcDriver extends DeviceDriver {
  CalcDriver({required this.store, required Project Function() project}) : _calc = CalcEvaluator(project);

  final TagStore store;
  final CalcEvaluator _calc;
  final ValueNotifier<ModbusLinkState> _state = ValueNotifier(ModbusLinkState.disconnected);

  List<Tag> _tags = const [];
  List<Tag> _order = const [];
  Set<String> _cyclic = const {};
  final Map<String, VoidCallback> _listening = {};
  bool _evaluating = false;
  bool _scheduled = false;
  bool _disposed = false;

  @override
  ValueListenable<ModbusLinkState> get state => _state;

  /// Não pergunta nada a ninguém: o tempo da "varredura" seria sempre 0 ms.
  @override
  bool get reportsScanTime => false;

  @override
  Future<void> connect() async {
    if (_disposed) return;
    _state.value = ModbusLinkState.connected;
    _listen();
  }

  @override
  Future<void> disconnect() async {
    _unlistenAll();
    if (!_disposed) _state.value = ModbusLinkState.disconnected;
  }

  @override
  void tagsChanged(List<Tag> previous, List<Tag> current) => _setTags(current);

  void _setTags(List<Tag> tags) {
    _tags = tags;
    final (order, cyclic) = CalcGraph.order([for (final t in tags) if (t.calc != null) t]);
    _order = order;
    _cyclic = cyclic;
    if (isConnected) _listen();
  }

  /// Ouve as entradas das contas em uso: entrada nova → conta nova na hora.
  void _listen() {
    final want = {for (final t in _tags) ...?t.calc?.inputIds};
    for (final id in _listening.keys.where((k) => !want.contains(k)).toList()) {
      store.watch(id).removeListener(_listening.remove(id)!);
    }
    for (final id in want) {
      if (_listening.containsKey(id)) continue;
      void l() => _schedule();
      _listening[id] = l;
      store.watch(id).addListener(l);
    }
  }

  void _unlistenAll() {
    for (final e in _listening.entries) {
      store.watch(e.key).removeListener(e.value);
    }
    _listening.clear();
  }

  void _schedule() {
    // A própria publicação (calculada que é entrada de outra) não reagenda:
    // a ordem de cálculo já passa pela de cima depois.
    if (_evaluating || _scheduled || _disposed) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (isConnected && !_disposed) _evaluateAll(force: false);
    });
  }

  void _evaluateAll({required bool force}) {
    _evaluating = true;
    try {
      for (final t in _order) {
        final before = store.read(t.id);
        final next = _cyclic.contains(t.id)
            ? TagReading(quality: TagQuality.configError, message: 'a conta fica em círculo', at: clock.now())
            : _calc.evaluate(t.id, t.calc!, store.read, previous: before);
        if (force || _differs(before, next)) store.publish(t.id, next);
      }
    } finally {
      _evaluating = false;
    }
  }

  static bool _differs(TagReading a, TagReading b) => a.quality != b.quality || a.message != b.message || a.value != b.value;

  @override
  Future<int> scan(List<Tag> tags, TagStore store, {required bool Function() stillCurrent}) async {
    if (!isConnected) await connect();
    if (!identical(tags, _tags)) _setTags(tags);
    // Variável no equipamento das calculadas sem conta (arquivo editado à mão).
    for (final t in tags.where((t) => t.calc == null)) {
      if (store.read(t.id).quality != TagQuality.configError) {
        store.publish(t.id, TagReading(quality: TagQuality.configError, message: 'variável sem conta', at: clock.now()));
      }
    }
    _evaluateAll(force: true);
    return 0;
  }

  @override
  Future<Object> readOnce(Tag tag) async {
    final spec = tag.calc;
    if (spec == null) throw const TagValueError('variável sem conta');
    final r = _calc.evaluate('lendo:${tag.id}', spec, store.read);
    if (r.isGood) return r.value!;
    if (r.quality == TagQuality.waiting) throw CalcWaiting(r.message);
    throw TagValueError(r.message);
  }

  @override
  Future<void> write(Tag tag, Object value) async => throw TagValueError('"${tag.name}" é calculada: só leitura');

  @override
  Future<void> ping() async {}

  @override
  Future<void> dispose() async {
    _unlistenAll();
    _disposed = true;
    _state.dispose();
  }
}
