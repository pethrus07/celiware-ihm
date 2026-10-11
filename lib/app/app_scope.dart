import 'package:flutter/widgets.dart';

import '../services/alarms/alarm_engine.dart';
import '../services/logging/data_logger.dart';
import '../services/runtime/hmi_runtime.dart';
import 'project_controller.dart';

/// Injeção de dependência do app — o equivalente ao `AppDataSource` do
/// machine_monitor, mas por árvore de widgets em vez de estático global
/// (o que deixa os testes de widget montarem o app com um runtime simulado).
///
/// Qualquer tela pega o controlador, o runtime, os alarmes e o registro de
/// dados com `AppScope.of(context)`. Ouvir mudanças do projeto:
/// `AppScope.watch(context)` (reconstrói a tela quando o projeto muda).
class AppScope extends InheritedNotifier<ProjectController> {
  const AppScope({super.key, required ProjectController controller, required this.runtime, required this.alarms, required this.logger, required super.child})
      : super(notifier: controller);

  final HmiRuntime runtime;
  final AlarmEngine alarms;
  final DataLogger logger;

  ProjectController get controller => notifier!;

  /// Acesso sem se inscrever em mudanças (para ações: salvar, escrever).
  static AppScope of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope ausente acima deste widget');
    return scope!;
  }

  /// Acesso que reconstrói o widget quando o projeto muda.
  static AppScope watch(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope ausente acima deste widget');
    return scope!;
  }
}
