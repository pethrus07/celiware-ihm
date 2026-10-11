import 'package:flutter/foundation.dart';
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

/// [LiveTags] para listas longas: lê só as variáveis cujos itens estão
/// montados agora. Num `ListView.builder` isso é o que está à vista (mais a
/// margem de pré-carga) — uma lista de 2.000 variáveis lê umas vinte por vez,
/// em vez de varrer o CLP inteiro só porque a aba foi aberta.
///
/// Cada linha se registra com [LiveTagItem]. As entradas e saídas de um quadro
/// viram **uma** inscrição no fim dele: rolar a lista não replaneja a
/// varredura a cada linha que aparece.
class VisibleLiveTags extends StatefulWidget {
  const VisibleLiveTags({super.key, required this.child});
  final Widget child;

  @override
  State<VisibleLiveTags> createState() => _VisibleLiveTagsState();
}

class _VisibleLiveTagsState extends State<VisibleLiveTags> {
  HmiRuntime? _runtime;
  TagSubscription? _sub;
  final Map<String, int> _mounted = {};
  bool _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runtime = AppScope.of(context).runtime;
  }

  void _add(String id) {
    _mounted[id] = (_mounted[id] ?? 0) + 1;
    _schedule();
  }

  void _remove(String id) {
    final n = (_mounted[id] ?? 1) - 1;
    if (n <= 0) {
      _mounted.remove(id);
    } else {
      _mounted[id] = n;
    }
    _schedule();
  }

  // Linhas nascem e morrem durante o quadro (build/finalização), então o fim
  // do quadro sempre vem; inscrever ali também evita "setState durante o
  // build" nos selos que ouvem o runtime.
  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final ids = _mounted.keys.toSet();
      if (setEquals(ids, _sub?.tagIds ?? const <String>{})) return;
      final old = _sub;
      _sub = ids.isEmpty ? null : _runtime!.subscribe(ids);
      old?.cancel();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _VisibleScope(state: this, child: widget.child);
}

class _VisibleScope extends InheritedWidget {
  const _VisibleScope({required this.state, required super.child});
  final _VisibleLiveTagsState state;

  @override
  bool updateShouldNotify(_VisibleScope old) => state != old.state;
}

/// Linha de lista cuja variável fica sendo lida enquanto a linha está montada
/// (dentro de um [VisibleLiveTags]).
class LiveTagItem extends StatefulWidget {
  const LiveTagItem({super.key, required this.tagId, required this.child});
  final String tagId;
  final Widget child;

  @override
  State<LiveTagItem> createState() => _LiveTagItemState();
}

class _LiveTagItemState extends State<LiveTagItem> {
  _VisibleLiveTagsState? _owner;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final owner = context.getInheritedWidgetOfExactType<_VisibleScope>()?.state;
    if (owner == _owner) return;
    _owner?._remove(widget.tagId);
    _owner = owner?.._add(widget.tagId);
  }

  @override
  void didUpdateWidget(LiveTagItem old) {
    super.didUpdateWidget(old);
    // O builder reaproveita a linha para outra variável quando a lista muda.
    if (old.tagId != widget.tagId) {
      _owner?._remove(old.tagId);
      _owner?._add(widget.tagId);
    }
  }

  @override
  void dispose() {
    _owner?._remove(widget.tagId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
