import 'package:clock/clock.dart';

import '../../models/calc.dart';
import '../../models/project.dart';
import '../runtime/tag_store.dart';
import 'calc_expression.dart';
import 'calc_graph.dart';

/// Quanto um contador sobe por hora ("peças/hora", a `taxa( )` da conta).
///
/// Janela deslizante de [window] (5 min): rápido o bastante para ver a máquina
/// parar, lento o bastante para uma máquina de 1 peça por minuto não pular
/// entre 0 e 60/h. Contador que volta (zerou na troca de turno) recomeça a
/// janela em vez de dar taxa negativa.
class RateTracker {
  RateTracker({this.window = const Duration(minutes: 5), this.minSpan = const Duration(seconds: 10)});

  final Duration window;

  /// Menos que isto de histórico ainda não é taxa: é ruído.
  final Duration minSpan;

  final List<(DateTime, double)> _samples = [];

  void add(DateTime at, double value) {
    if (_samples.isNotEmpty) {
      final (lastAt, lastValue) = _samples.last;
      if (!at.isAfter(lastAt)) return; // a mesma leitura de novo
      if (value < lastValue) _samples.clear(); // zerou: começa de novo
    }
    // Um ponto por segundo basta; o mais novo substitui o do mesmo segundo.
    if (_samples.length >= 2 && at.difference(_samples[_samples.length - 2].$1) < const Duration(seconds: 1)) {
      _samples.removeLast();
    }
    _samples.add((at, value));
    // Fica um ponto antes do corte, para a janela estar sempre cheia.
    final cutoff = at.subtract(window);
    while (_samples.length > 2 && !_samples[1].$1.isAfter(cutoff)) {
      _samples.removeAt(0);
    }
  }

  /// Unidades por hora; nulo enquanto não há [minSpan] de histórico.
  double? perHour() {
    if (_samples.length < 2) return null;
    final (firstAt, firstValue) = _samples.first;
    final (lastAt, lastValue) = _samples.last;
    final span = lastAt.difference(firstAt);
    if (span < minSpan) return null;
    return (lastValue - firstValue) * 3600e6 / span.inMicroseconds;
  }
}

/// Faz uma conta a partir das leituras das entradas — o mesmo código no motor
/// (`CalcDriver`), no "Lendo agora" do cadastro e na condição das regras.
///
/// As regras de qualidade (LG-2) moram aqui:
///   • entrada com erro (endereço, configuração) → conta com erro;
///   • entrada **sem comunicação** → conta sem comunicação, mantendo o último
///     valor dela esmaecido — nunca um número calculado com dado velho;
///   • entrada ainda sem leitura → conta esperando;
///   • divisão por zero, resultado impossível → erro com o motivo.
class CalcEvaluator {
  CalcEvaluator(this.project);

  final Project Function() project;

  Project? _cachedFor;
  final Map<String, (CalcSpec, Object)> _compiled = {};
  final Map<String, RateTracker> _rates = {};

  /// A conta conferida contra o projeto de agora: [CalcProgram] ou [CalcError].
  Object compiled(String key, CalcSpec spec) {
    final p = project();
    if (!identical(p, _cachedFor)) {
      // Projeto mudou (variável renomeada, apagada, tipo trocado): confere de novo.
      _compiled.clear();
      _cachedFor = p;
    }
    final hit = _compiled[key];
    if (hit != null && hit.$1 == spec) return hit.$2;
    Object result;
    try {
      result = CalcGraph.compile(spec, p);
    } on CalcError catch (e) {
      result = e;
    }
    _compiled[key] = (spec, result);
    return result;
  }

  /// A leitura da conta [spec] agora. [key] separa o histórico da taxa de cada
  /// conta; [previous] é a leitura anterior dela (a queda de comunicação
  /// mantém o último valor).
  TagReading evaluate(String key, CalcSpec spec, TagReading Function(String id) read, {TagReading previous = TagReading.waiting}) {
    final c = compiled(key, spec);
    final now = clock.now();
    if (c is CalcError) return TagReading(quality: TagQuality.configError, message: c.message, at: now);
    final program = c as CalcProgram;
    final p = project();

    String? broken, lost, waiting;
    DateTime? newest;
    for (final id in program.inputIds) {
      final r = read(id);
      final tag = p.tag(id);
      final name = tag?.name ?? spec.names[id] ?? id;
      switch (r.quality) {
        case TagQuality.addressError || TagQuality.configError:
          broken ??= 'erro na entrada "$name"';
        case TagQuality.commLost:
          // Calculada que cita calculada: o motivo dela já diz qual equipamento.
          lost ??= tag?.calc != null ? r.message : 'sem comunicação com ${p.device(tag?.deviceId ?? '')?.name ?? 'o equipamento'}';
        case TagQuality.waiting:
          waiting ??= name;
        case TagQuality.good:
          final at = r.at;
          if (at != null && (newest == null || at.isAfter(newest))) newest = at;
      }
    }
    if (broken != null) return TagReading(quality: TagQuality.configError, message: broken, at: now);
    if (lost != null) return previous.degrade(TagQuality.commLost, lost);
    if (waiting != null) return TagReading(quality: TagQuality.waiting, message: 'esperando a leitura de "$waiting"');

    for (final id in program.rateIds) {
      final r = read(id);
      final v = r.value;
      if (v is num) _rates.putIfAbsent('$key>$id', RateTracker.new).add(r.at ?? now, v.toDouble());
    }
    try {
      final v = program.run(_Env(read, (id) => _rates['$key>$id']?.perHour()));
      return TagReading(value: v, quality: TagQuality.good, at: newest ?? now);
    } on CalcNotReady catch (e) {
      return TagReading(quality: TagQuality.waiting, message: e.message, at: now);
    } on CalcRuntimeError catch (e) {
      return TagReading(quality: TagQuality.configError, message: e.message, at: now);
    }
  }
}

class _Env implements CalcEnv {
  _Env(this._read, this._rate);
  final TagReading Function(String id) _read;
  final double? Function(String id) _rate;

  @override
  Object? valueOf(String id) => _read(id).value;

  @override
  double? perHour(String id) => _rate(id);
}
