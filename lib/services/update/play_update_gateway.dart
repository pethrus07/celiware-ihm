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
    );
  }

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
