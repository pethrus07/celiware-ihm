// Verificação de atualização pela Play (reunião de 19–20/10/2026, D2: no
// futuro, a versão antiga poderá ser "bloqueada para forçar a atualização").
//
// Usa a API oficial Play In-App Updates: ao abrir o app, se a Play disser que
// há versão nova, oferece a atualização FLEXÍVEL (baixa em segundo plano, o
// operador continua trabalhando e reinicia quando quiser); se a versão
// publicada tiver prioridade alta (inAppUpdatePriority ≥ 4, definida no envio
// pela Play Developer API — ver docs/PUBLICACAO.md), pede a IMEDIATA (tela
// cheia da Play).
//
// O app é offline e IHM de máquina: sem internet, instalado fora da Play, em
// teste ou com qualquer erro, NÃO faz nada e nunca trava a operação (NR-12:
// a falta de rede não pode impedir de operar). A decisão fica numa função
// pura ([UpdatePolicy]) separada da chamada nativa ([UpdateGateway]), para
// testar sem a Play.

import 'dart:async';

import 'package:logging/logging.dart';

/// O que a Play informou, no mínimo que a decisão precisa.
class UpdateStatus {
  const UpdateStatus({required this.available, this.priority = 0, this.immediateAllowed = false, this.flexibleAllowed = false, this.inProgress = false});

  /// Há versão nova na loja para este aparelho.
  final bool available;

  /// Prioridade da versão publicada (0 a 5), definida no envio.
  final int priority;
  final bool immediateAllowed;
  final bool flexibleAllowed;

  /// Uma atualização imediata já começou e foi interrompida (o app voltou):
  /// a Play pede para retomar.
  final bool inProgress;
}

enum UpdateAction {
  /// Nada a fazer (sem versão nova, sem permissão da Play).
  none,

  /// Baixar em segundo plano; reiniciar quando a pessoa quiser.
  flexible,

  /// Tela cheia da Play: a versão publicada pede atualizar já.
  immediate,
}

/// A decisão, sem Play nem tela.
class UpdatePolicy {
  UpdatePolicy._();

  /// Prioridade a partir da qual a atualização é imediata.
  static const immediatePriority = 4;

  static UpdateAction decide(UpdateStatus s) {
    if (s.inProgress && s.immediateAllowed) return UpdateAction.immediate;
    if (!s.available) return UpdateAction.none;
    if (s.priority >= immediatePriority && s.immediateAllowed) return UpdateAction.immediate;
    if (s.flexibleAllowed) return UpdateAction.flexible;
    // Prioridade baixa e a Play só aceita a imediata: não interrompe o
    // operador por uma versão que não pediu pressa.
    return UpdateAction.none;
  }
}

/// A Play do outro lado (o pacote `in_app_update` no app; um falso nos testes).
abstract class UpdateGateway {
  /// Nulo quando não dá para saber (fora do Android, sem a Play).
  Future<UpdateStatus?> check();
  Future<void> immediate();

  /// Começa a baixar; termina quando o download acabou.
  Future<void> startFlexible();

  /// Instala o que já baixou (o app reinicia).
  Future<void> completeFlexible();
}

/// Confere e age, engolindo qualquer falha: nunca derruba nem trava o app.
class UpdateChecker {
  UpdateChecker({required this.gateway, this.timeout = const Duration(seconds: 10), DateTime Function()? now}) : _now = now ?? DateTime.now;

  static final Logger _log = Logger('UpdateChecker');

  /// Conferir de novo ao voltar para o app só depois disto (a imediata
  /// interrompida é retomada sempre).
  static const recheckAfter = Duration(hours: 6);

  final UpdateGateway gateway;
  final Duration timeout;
  final DateTime Function() _now;

  DateTime? _lastCheck;
  UpdateAction _last = UpdateAction.none;
  bool _running = false;

  /// Atualização flexível baixada, esperando a pessoa reiniciar.
  bool downloaded = false;

  /// Abrir o app ou voltar para ele. [onDownloaded] avisa que a flexível
  /// terminou de baixar (a tela oferece "Reiniciar").
  Future<UpdateAction> run({bool resumed = false, void Function()? onDownloaded}) async {
    if (_running) return UpdateAction.none;
    final last = _lastCheck;
    if (resumed && _last != UpdateAction.immediate && last != null && _now().difference(last) < recheckAfter) return UpdateAction.none;
    _running = true;
    try {
      _lastCheck = _now();
      final status = await gateway.check().timeout(timeout);
      final action = status == null ? UpdateAction.none : UpdatePolicy.decide(status);
      _last = action;
      switch (action) {
        case UpdateAction.none:
          break;
        case UpdateAction.immediate:
          await gateway.immediate();
        case UpdateAction.flexible:
          if (!downloaded) {
            await gateway.startFlexible();
            downloaded = true;
            onDownloaded?.call();
          }
      }
      return action;
    } catch (e) {
      // Sem internet, fora da Play, pessoa cancelou: segue a vida.
      _log.info('Verificação de atualização sem resultado: $e');
      return UpdateAction.none;
    } finally {
      _running = false;
    }
  }

  /// "Reiniciar" depois da flexível baixada.
  Future<void> install() async {
    try {
      await gateway.completeFlexible();
    } catch (e) {
      _log.info('Não instalou a atualização: $e');
    }
  }
}
