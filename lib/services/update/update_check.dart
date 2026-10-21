// Verificação de atualização pela Play (reunião de 19–20/10/2026, D2: no
// futuro, a versão antiga poderá ser "bloqueada para forçar a atualização").
//
// Usa a API oficial Play In-App Updates: ao abrir o app, se a Play disser que
// há versão nova, oferece a atualização FLEXÍVEL (baixa em segundo plano, o
// operador continua trabalhando e reinicia quando quiser); se a versão
// publicada tiver prioridade alta (inAppUpdatePriority ≥ 4, definida no envio
// pela Play Developer API — ver docs/PUBLICACAO.md), pede a IMEDIATA (tela
// cheia da Play). Cancelada a imediata, ela só volta depois de 24 h — a não
// ser com prioridade 5, que é a "bloqueada" do D2 e volta a cada abertura.
// Flexível já baixada (de uma abertura anterior) não baixa de novo: oferece
// "Reiniciar".
//
// O app é offline e IHM de máquina: sem internet, instalado fora da Play, em
// teste ou com qualquer erro, NÃO faz nada e nunca trava a operação (NR-12:
// a falta de rede não pode impedir de operar). A decisão fica numa função
// pura ([UpdatePolicy]) separada da chamada nativa ([UpdateGateway]), para
// testar sem a Play.

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Onde está o download da atualização, pelo que a Play informou
/// (`installStatus`), no mínimo que a decisão precisa.
enum UpdateInstall {
  /// Nada começou (ou falhou, ou foi cancelado).
  none,

  /// Flexível na fila ou baixando.
  downloading,

  /// Flexível baixada, esperando instalar.
  downloaded,
}

/// O que a Play informou, no mínimo que a decisão precisa.
class UpdateStatus {
  const UpdateStatus({
    required this.available,
    this.priority = 0,
    this.immediateAllowed = false,
    this.flexibleAllowed = false,
    this.inProgress = false,
    this.install = UpdateInstall.none,
  });

  /// Há versão nova na loja para este aparelho.
  final bool available;

  /// Prioridade da versão publicada (0 a 5), definida no envio.
  final int priority;
  final bool immediateAllowed;
  final bool flexibleAllowed;

  /// A Play diz que uma atualização disparada pelo app está em andamento
  /// (`developerTriggeredUpdateInProgress`). Sozinho não decide nada: a
  /// imediata só é retomada com prioridade alta.
  final bool inProgress;

  /// Estado do download (`installStatus`).
  final UpdateInstall install;
}

enum UpdateAction {
  /// Nada a fazer (sem versão nova, sem permissão da Play).
  none,

  /// Baixar em segundo plano; reiniciar quando a pessoa quiser.
  flexible,

  /// Tela cheia da Play: a versão publicada pede atualizar já.
  immediate,

  /// A flexível já está baixada: só falta a pessoa tocar em "Reiniciar".
  restart,
}

/// A decisão, sem Play nem tela.
class UpdatePolicy {
  UpdatePolicy._();

  /// Prioridade a partir da qual a atualização é imediata.
  static const immediatePriority = 4;

  /// Prioridade que pede a imediata mesmo logo depois de cancelada.
  static const alwaysPriority = 5;

  /// [immediateSnoozed]: a pessoa cancelou a imediata há pouco
  /// ([UpdateChecker.immediateSnooze]); só a prioridade 5 pede de novo.
  static UpdateAction decide(UpdateStatus s, {bool immediateSnoozed = false}) {
    if (s.install == UpdateInstall.downloaded) return UpdateAction.restart;
    final urgent = s.priority >= immediatePriority && s.immediateAllowed && (!immediateSnoozed || s.priority >= alwaysPriority);
    // Em andamento: retoma a imediata só se ela é de fato a pedida.
    if (s.inProgress) return urgent ? UpdateAction.immediate : UpdateAction.none;
    if (!s.available) return UpdateAction.none;
    if (urgent) return UpdateAction.immediate;
    // Imediata cancelada há pouco: não troca por outra janela da Play.
    if (immediateSnoozed && s.priority >= immediatePriority && s.immediateAllowed) return UpdateAction.none;
    // Já baixando: espera terminar (a próxima conferida oferece reiniciar).
    if (s.install == UpdateInstall.downloading) return UpdateAction.none;
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
  /// pedida é conferida de novo a cada volta).
  static const recheckAfter = Duration(hours: 6);

  /// Imediata cancelada: não abre de novo antes disto (prioridade 5 abre).
  /// Sem o intervalo, cada volta ao app reabria a tela cheia da Play — em
  /// laço, para quem cancelou.
  static const immediateSnooze = Duration(hours: 24);

  /// Quando a imediata foi mostrada pela última vez e não instalou
  /// (`shared_preferences`, para valer entre aberturas).
  static const snoozeKey = 'atualizacao:imediata-cancelada';

  final UpdateGateway gateway;
  final Duration timeout;
  final DateTime Function() _now;

  DateTime? _lastCheck;
  UpdateAction _last = UpdateAction.none;
  bool _running = false;

  /// Atualização flexível baixada, esperando a pessoa reiniciar.
  bool downloaded = false;

  /// Abrir o app ou voltar para ele. [onDownloaded] avisa que a flexível
  /// está baixada (a tela oferece "Reiniciar") — uma vez por abertura.
  Future<UpdateAction> run({bool resumed = false, void Function()? onDownloaded}) async {
    if (_running) return UpdateAction.none;
    final last = _lastCheck;
    if (resumed && _last != UpdateAction.immediate && last != null && _now().difference(last) < recheckAfter) return UpdateAction.none;
    _running = true;
    try {
      _lastCheck = _now();
      final status = await gateway.check().timeout(timeout);
      final action = status == null ? UpdateAction.none : UpdatePolicy.decide(status, immediateSnoozed: await _snoozed());
      _last = action;
      switch (action) {
        case UpdateAction.none:
          break;
        case UpdateAction.immediate:
          try {
            await gateway.immediate();
          } finally {
            // Instalou: o app reinicia e isto não importa. Voltou para cá:
            // a pessoa cancelou (ou a Play falhou) — espera antes de pedir
            // de novo.
            await _snooze();
          }
        case UpdateAction.restart:
          _offer(onDownloaded);
        case UpdateAction.flexible:
          if (!downloaded) {
            await gateway.startFlexible();
            _offer(onDownloaded);
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

  void _offer(void Function()? onDownloaded) {
    if (downloaded) return;
    downloaded = true;
    onDownloaded?.call();
  }

  Future<bool> _snoozed() async {
    try {
      final p = await SharedPreferences.getInstance();
      final ms = p.getInt(snoozeKey);
      if (ms == null) return false;
      final since = _now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
      // Relógio voltou para trás: não segura a atualização para sempre.
      return !since.isNegative && since < immediateSnooze;
    } catch (_) {
      return false;
    }
  }

  Future<void> _snooze() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(snoozeKey, _now().millisecondsSinceEpoch);
    } catch (_) {/* sem armazenamento: pede de novo na próxima volta */}
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
