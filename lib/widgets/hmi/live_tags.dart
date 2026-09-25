import 'package:flutter/widgets.dart';

import '../../app/app_scope.dart';
import '../../services/runtime/hmi_runtime.dart';

/// Mantém [tagIds] sendo lidas enquanto este widget estiver na tela.
///
/// É a forma declarativa de "esta parte da interface precisa destes valores
/// ao vivo": a tela em operação, o editor, a lista de variáveis e as folhas de
/// escolha usam. Ao sair da tela a inscrição é cancelada e, se ninguém mais
/// precisa daquele equipamento, a varredura dele para.
///
/// A (re)inscrição roda **depois do quadro**: inscrever mexe no runtime, que
/// notifica outros widgets — dentro do build isso dispararia "setState
/// durante o build".
class LiveTags extends StatefulWidget {
  const LiveTags({super.key, required this.tagIds, required this.child, this.releaseOnDispose = false});

  final Set<String> tagIds;
  final Widget child;

  /// Soltar os botões de pulso ao sair (tela em operação).
  final bool releaseOnDispose;

  @override
  State<LiveTags> createState() => _LiveTagsState();
}

class _LiveTagsState extends State<LiveTags> {
  HmiRuntime? _runtime;
  TagSubscription? _sub;
  Set<String> _current = const {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runtime = AppScope.of(context).runtime;
    _sync();
  }

  @override
  void didUpdateWidget(LiveTags old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final ids = widget.tagIds;
    if (_sub != null && ids.length == _current.length && ids.containsAll(_current)) return;
    _current = Set.of(ids);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final old = _sub;
      _sub = _runtime!.subscribe(_current);
      old?.cancel();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (widget.releaseOnDispose) _runtime?.releaseAll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
