import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_theme.dart';

/// Aparência do app: automático (segue o celular), claro ou escuro.
///
/// Guardada **por aparelho**, não no projeto: o mesmo projeto roda num
/// tablet preso na máquina (luz fixa, quer claro) e no celular do líder
/// (quer seguir o sistema). Claro é o padrão de dia no chão de fábrica — a
/// pesquisa (docs/PESQUISA-UI-UX.md §1.3) mostrou tema claro lendo melhor
/// com luz ambiente e no sol; escuro serve para noite e sala fechada.
class AppearanceController extends ValueNotifier<Appearance> {
  AppearanceController._() : super(Appearance.auto);

  static final instance = AppearanceController._();
  static const _key = 'aparencia';

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      value = Appearance.values.firstWhere((a) => a.name == saved, orElse: () => Appearance.auto);
    } catch (_) {/* sem preferência: automático */}
  }

  Future<void> set(Appearance a) async {
    value = a;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, a.name);
    } catch (_) {}
  }

  /// Paleta efetiva para a preferência atual e o brilho do sistema.
  IndPalette resolve([Brightness? platform]) {
    switch (value) {
      case Appearance.claro:
        return IndPalette.claro;
      case Appearance.escuro:
        return IndPalette.escuro;
      case Appearance.auto:
        final b = platform ?? SchedulerBinding.instance.platformDispatcher.platformBrightness;
        return b == Brightness.dark ? IndPalette.escuro : IndPalette.claro;
    }
  }
}
