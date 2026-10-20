import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/services/update/update_check.dart';

/// Verificação de atualização (D2): a decisão sem a Play, e o verificador
/// que nunca trava o app — sem internet, fora da Play ou com erro, nada.
void main() {
  group('decisão', () {
    UpdateAction d({bool available = true, int priority = 0, bool immediate = true, bool flexible = true, bool inProgress = false}) =>
        UpdatePolicy.decide(UpdateStatus(available: available, priority: priority, immediateAllowed: immediate, flexibleAllowed: flexible, inProgress: inProgress));

    test('sem versão nova: nada', () => expect(d(available: false), UpdateAction.none));
    test('versão comum: flexível', () {
      expect(d(priority: 0), UpdateAction.flexible);
      expect(d(priority: 3), UpdateAction.flexible);
    });
    test('prioridade 4 ou 5: imediata', () {
      expect(d(priority: 4), UpdateAction.immediate);
      expect(d(priority: 5), UpdateAction.immediate);
    });
    test('prioridade alta sem imediata permitida: cai na flexível', () => expect(d(priority: 5, immediate: false), UpdateAction.flexible));
    test('prioridade baixa com só a imediata permitida: não interrompe', () => expect(d(priority: 1, flexible: false), UpdateAction.none));
    test('imediata interrompida: retoma', () => expect(d(available: false, inProgress: true), UpdateAction.immediate));
  });

  group('verificador', () {
    test('sem internet ou fora da Play: não faz nada e não lança', () async {
      for (final gw in [_Gateway(error: Exception('sem rede')), _Gateway(status: null), _Gateway(hang: true)]) {
        final c = UpdateChecker(gateway: gw, timeout: const Duration(milliseconds: 50));
        expect(await c.run(), UpdateAction.none);
        expect(gw.calls, isEmpty);
      }
    });

    test('flexível: baixa uma vez e avisa; reiniciar instala', () async {
      final gw = _Gateway(status: const UpdateStatus(available: true, priority: 1, flexibleAllowed: true, immediateAllowed: true));
      final c = UpdateChecker(gateway: gw);
      var told = 0;
      expect(await c.run(onDownloaded: () => told++), UpdateAction.flexible);
      expect(gw.calls, ['flexivel']);
      expect((told, c.downloaded), (1, true));
      await c.install();
      expect(gw.calls.last, 'instalar');
    });

    test('pessoa recusou a flexível: não marca como baixada', () async {
      final gw = _Gateway(status: const UpdateStatus(available: true, flexibleAllowed: true), flexibleError: true);
      final c = UpdateChecker(gateway: gw);
      expect(await c.run(), UpdateAction.none);
      expect(c.downloaded, isFalse);
    });

    test('voltar para o app: só confere de novo depois de 6 h, a não ser que a imediata esteja pendente', () async {
      var now = DateTime(2026, 10, 20, 8);
      final gw = _Gateway(status: const UpdateStatus(available: true, priority: 1, flexibleAllowed: true));
      final c = UpdateChecker(gateway: gw, now: () => now);
      await c.run();
      now = now.add(const Duration(hours: 1));
      await c.run(resumed: true);
      expect(gw.checks, 1);
      now = now.add(const Duration(hours: 6));
      await c.run(resumed: true);
      expect(gw.checks, 2);

      final urgent = _Gateway(status: const UpdateStatus(available: true, priority: 5, immediateAllowed: true));
      final u = UpdateChecker(gateway: urgent, now: () => now);
      await u.run();
      await u.run(resumed: true);
      expect(urgent.calls, ['imediata', 'imediata'], reason: 'cancelou a imediata: pede de novo ao voltar');
    });
  });
}

class _Gateway implements UpdateGateway {
  _Gateway({this.status, this.error, this.hang = false, this.flexibleError = false});
  final UpdateStatus? status;
  final Object? error;
  final bool hang;
  final bool flexibleError;
  final List<String> calls = [];
  int checks = 0;

  @override
  Future<UpdateStatus?> check() async {
    checks++;
    if (hang) return Completer<UpdateStatus?>().future;
    if (error != null) throw error!;
    return status;
  }

  @override
  Future<void> immediate() async => calls.add('imediata');

  @override
  Future<void> startFlexible() async {
    if (flexibleError) throw Exception('recusou');
    calls.add('flexivel');
  }

  @override
  Future<void> completeFlexible() async => calls.add('instalar');
}
