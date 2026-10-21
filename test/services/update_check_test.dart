import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/services/update/update_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Verificação de atualização (D2): a decisão sem a Play, e o verificador
/// que nunca trava o app — sem internet, fora da Play ou com erro, nada.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
    test('imediata interrompida: retoma só com prioridade alta', () {
      expect(d(available: false, inProgress: true, priority: 4), UpdateAction.immediate);
      expect(d(available: false, inProgress: true), UpdateAction.none, reason: 'em andamento, sozinho, não vira imediata');
      expect(d(inProgress: true, priority: 2), UpdateAction.none);
    });
    test('flexível já baixada: reiniciar, não baixar de novo', () {
      UpdateAction s(UpdateInstall install, {int priority = 0, bool available = true}) =>
          UpdatePolicy.decide(UpdateStatus(available: available, priority: priority, immediateAllowed: true, flexibleAllowed: true, install: install));
      expect(s(UpdateInstall.downloaded), UpdateAction.restart);
      expect(s(UpdateInstall.downloaded, priority: 5), UpdateAction.restart, reason: 'já baixou: instalar é o caminho mais curto');
      expect(s(UpdateInstall.downloading), UpdateAction.none, reason: 'baixando: espera terminar');
      expect(s(UpdateInstall.none), UpdateAction.flexible);
    });
    test('imediata cancelada há pouco: só a prioridade 5 pede de novo', () {
      UpdateAction s(int priority) => UpdatePolicy.decide(
          UpdateStatus(available: true, priority: priority, immediateAllowed: true, flexibleAllowed: true), immediateSnoozed: true);
      expect(s(4), UpdateAction.none);
      expect(s(5), UpdateAction.immediate);
      expect(s(1), UpdateAction.flexible, reason: 'versão comum segue normal');
    });
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
      expect(urgent.calls, ['imediata', 'imediata'], reason: 'prioridade 5 cancelada: pede de novo ao voltar');
    });

    test('imediata (prioridade 4) cancelada: não reabre em laço; volta depois de 24 h, mesmo com o app reaberto', () async {
      var now = DateTime(2026, 10, 21, 8);
      final gw = _Gateway(status: const UpdateStatus(available: true, priority: 4, immediateAllowed: true, flexibleAllowed: true), immediateError: true);
      final c = UpdateChecker(gateway: gw, now: () => now);
      expect(await c.run(), UpdateAction.none, reason: 'cancelou: a Play devolve erro, engolido');
      expect(gw.calls, ['imediata']);
      for (var i = 0; i < 5; i++) {
        now = now.add(const Duration(minutes: 10));
        await c.run(resumed: true);
      }
      expect(gw.calls, ['imediata'], reason: 'voltar para o app não reabre a tela cheia');

      // Fechou e abriu o app: a marca está guardada.
      now = now.add(const Duration(hours: 2));
      final reopened = UpdateChecker(gateway: gw, now: () => now);
      await reopened.run();
      expect(gw.calls, ['imediata']);
      expect((await SharedPreferences.getInstance()).getInt(UpdateChecker.snoozeKey), isNotNull);

      now = now.add(const Duration(hours: 23));
      await UpdateChecker(gateway: gw, now: () => now).run();
      expect(gw.calls, ['imediata', 'imediata'], reason: 'passadas 24 h pede de novo');
    });

    test('flexível baixada numa abertura anterior: oferece reiniciar sem baixar de novo', () async {
      final gw = _Gateway(status: const UpdateStatus(available: true, priority: 1, flexibleAllowed: true, immediateAllowed: true, install: UpdateInstall.downloaded));
      final c = UpdateChecker(gateway: gw);
      var told = 0;
      expect(await c.run(onDownloaded: () => told++), UpdateAction.restart);
      expect(gw.calls, isEmpty, reason: 'startFlexible não é chamado de novo');
      expect((told, c.downloaded), (1, true));
      await c.run(onDownloaded: () => told++);
      expect(told, 1, reason: 'o aviso "Reiniciar" aparece uma vez');
      await c.install();
      expect(gw.calls, ['instalar']);
    });

    test('Play diz "em andamento" com prioridade baixa: nem imediata nem flexível', () async {
      final gw = _Gateway(status: const UpdateStatus(available: false, inProgress: true, priority: 0, immediateAllowed: true, flexibleAllowed: true));
      expect(await UpdateChecker(gateway: gw).run(), UpdateAction.none);
      expect(gw.calls, isEmpty);
    });
  });
}

class _Gateway implements UpdateGateway {
  _Gateway({this.status, this.error, this.hang = false, this.flexibleError = false, this.immediateError = false});
  final UpdateStatus? status;
  final Object? error;
  final bool hang;
  final bool flexibleError;

  /// A pessoa cancela a tela cheia (a Play devolve "recusou").
  final bool immediateError;
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
  Future<void> immediate() async {
    calls.add('imediata');
    if (immediateError) throw Exception('recusou');
  }

  @override
  Future<void> startFlexible() async {
    if (flexibleError) throw Exception('recusou');
    calls.add('flexivel');
  }

  @override
  Future<void> completeFlexible() async => calls.add('instalar');
}
