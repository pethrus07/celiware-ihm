// A Play de verdade atrás do [UpdateGateway]: pacote `in_app_update`
// (Play In-App Updates, `com.google.android.play:app-update`). Só no
// Android; em qualquer outra plataforma responde "não sei" e nada acontece.
// Instalado fora da Play (APK, depuração), a Play responde com erro — que o
// [UpdateChecker] engole.

import 'dart:io';

import 'package:in_app_update/in_app_update.dart';

import 'update_check.dart';

class PlayUpdateGateway implements UpdateGateway {
  @override
  Future<UpdateStatus?> check() async {
    if (!Platform.isAndroid) return null;
    final info = await InAppUpdate.checkForUpdate();
    return UpdateStatus(
      available: info.updateAvailability == UpdateAvailability.updateAvailable,
      inProgress: info.updateAvailability == UpdateAvailability.developerTriggeredUpdateInProgress,
      priority: info.updatePriority,
      immediateAllowed: info.immediateUpdateAllowed,
      flexibleAllowed: info.flexibleUpdateAllowed,
      install: installOf(info.installStatus),
    );
  }

  /// O `installStatus` da Play no que a decisão usa: baixada (oferecer
  /// "Reiniciar" em vez de baixar de novo), baixando, ou nada.
  static UpdateInstall installOf(InstallStatus s) => switch (s) {
        InstallStatus.downloaded => UpdateInstall.downloaded,
        InstallStatus.pending || InstallStatus.downloading => UpdateInstall.downloading,
        _ => UpdateInstall.none,
      };

  @override
  Future<void> immediate() async {
    final r = await InAppUpdate.performImmediateUpdate();
    if (r != AppUpdateResult.success) throw StateError('Atualização imediata: $r');
  }

  @override
  Future<void> startFlexible() async {
    final r = await InAppUpdate.startFlexibleUpdate();
    if (r != AppUpdateResult.success) throw StateError('Atualização flexível: $r');
  }

  @override
  Future<void> completeFlexible() => InAppUpdate.completeFlexibleUpdate();
}
