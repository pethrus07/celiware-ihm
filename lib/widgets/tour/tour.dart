import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';

// Tutorial guiado dentro do app — o método do onboarding da Retífica
// (sinapse/07-FONTES/onboarding-dentro-do-sistema.md) portado para Flutter.
//
// Peças:
//   • [TourStep]  — um passo: alvo (GlobalKey), título, texto;
//   • [TourSpec]  — uma trilha com id e versão;
//   • [TourHost]  — envolve a página e desenha o tour POR CIMA DELA, dentro
//                   da própria árvore. Morre junto com a página: não há camada
//                   global que sobreviva à navegação e trave o app (armadilha
//                   3 da Retífica — o overlay que travava o login);
//   • [TourMemory] — "já vi", com a VERSÃO na chave (armadilha 4): subir
//                   [TourSpec.version] faz a trilha reaparecer para todos.
//
// O realce: pintura escura em tela cheia com um "buraco" (Path evenOdd) no
// retângulo do alvo + contorno âmbar. É o equivalente Flutter da box-shadow
// gigante do HTML.
//
// Passo essencial sem alvo na tela (lista vazia, elemento rolado para fora)
// aparece CENTRALIZADO em vez de sumir (armadilha 2) — quem entra no primeiro
// dia, com tudo vazio, é justamente quem mais precisa do passo.

/// Um passo do tutorial.
class TourStep {
  const TourStep({
    required this.title,
    required this.body,
    this.target,
    this.essential = false,
  });

  /// Elemento a realçar. Nulo = passo de texto, centralizado.
  final GlobalKey? target;
  final String title;
  final String body;

  /// Mostra mesmo sem alvo na tela (centralizado). Não essencial sem alvo é
  /// pulado.
  final bool essential;
}

/// Uma trilha de tutorial.
class TourSpec {
  const TourSpec({required this.id, required this.version, required this.title, required this.steps});

  /// Identificador estável ("inicio", "editor"...). Entra na chave do "já vi".
  final String id;

  /// Suba este número quando a trilha mudar de verdade — ela reaparece para
  /// quem já tinha visto a versão anterior.
  final int version;

  /// Nome na tela de tutoriais.
  final String title;
  final List<TourStep> steps;
}

/// Memória de "já vi", por aparelho.
///
/// Sem login no app, o escopo é o aparelho (a matriz pessoa × aparelho da
/// Retífica colapsa numa linha só). Se um dia houver login, a chave ganha o
/// usuário — ou a marca vai para o servidor.
class TourMemory {
  TourMemory._();

  static String key(TourSpec spec) => 'tour:v${spec.version}:${spec.id}';

  static Future<bool> seen(TourSpec spec) async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getBool(key(spec)) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> markSeen(TourSpec spec) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(key(spec), true);
    } catch (_) {/* sem armazenamento: o tour só volta a aparecer */}
  }

  /// "Rever todos os tutoriais" — apaga todas as marcas.
  static Future<void> resetAll() async {
    try {
      final p = await SharedPreferences.getInstance();
      for (final k in p.getKeys().where((k) => k.startsWith('tour:')).toList()) {
        await p.remove(k);
      }
    } catch (_) {}
  }
}

/// Envolve uma página e é dono do tutorial dela.
///
/// [autoStart] mostra a trilha sozinha na primeira visita (se ainda não vista
/// nesta versão). O botão "?" da página chama `TourHost.of(context).start()`.
class TourHost extends StatefulWidget {
  const TourHost({super.key, required this.child, this.spec, this.autoStart = true, this.forceStart = false});

  final Widget child;
  final TourSpec? spec;
  final bool autoStart;

  /// Começa já, mesmo se visto — usado pela tela de tutoriais ("Ver agora").
  final bool forceStart;

  static TourHostState? maybeOf(BuildContext context) => context.findAncestorStateOfType<TourHostState>();

  @override
  State<TourHost> createState() => TourHostState();
}

class TourHostState extends State<TourHost> {
  final GlobalKey _hostKey = GlobalKey();
  List<TourStep> _steps = const [];
  int _index = -1;
  Rect? _hole;

  bool get isActive => _index >= 0;
  TourSpec? get spec => widget.spec;

  @override
  void initState() {
    super.initState();
    if ((widget.autoStart || widget.forceStart) && widget.spec != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        if (widget.forceStart || !await TourMemory.seen(widget.spec!)) {
          // Deixa a página assentar (listas carregando, animação de rota).
          await Future<void>.delayed(const Duration(milliseconds: 450));
          if (mounted) start();
        }
      });
    }
  }

  /// Começa a trilha do início (ou [spec] passada, para tutoriais sob demanda).
  void start([TourSpec? spec]) {
    final s = spec ?? widget.spec;
    if (s == null || s.steps.isEmpty) return;
    _steps = s.steps;
    _activeSpec = s;
    _go(0, forward: true);
  }

  TourSpec? _activeSpec;

  Future<void> _go(int i, {required bool forward}) async {
    // Pula passos não essenciais sem alvo, na direção do movimento.
    while (i >= 0 && i < _steps.length) {
      final step = _steps[i];
      final ctx = step.target?.currentContext;
      if (ctx != null || step.essential) break;
      i += forward ? 1 : -1;
    }
    if (i < 0) i = 0;
    if (i >= _steps.length) {
      _finish();
      return;
    }
    final ctx = _steps[i].target?.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 250), alignment: 0.3);
    }
    if (!mounted) return;
    setState(() => _index = i);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    if (!mounted || _index < 0) return;
    final target = _steps[_index].target?.currentContext?.findRenderObject();
    final host = _hostKey.currentContext?.findRenderObject();
    Rect? hole;
    if (target is RenderBox && host is RenderBox && target.attached && target.hasSize) {
      final topLeft = target.localToGlobal(Offset.zero, ancestor: host);
      final r = topLeft & target.size;
      final bounds = Offset.zero & host.size;
      // Folga de 6 px em volta do alvo, mas sem sair da tela: o "?" colado
      // na borda tinha o contorno âmbar cortado ao meio.
      if (r.overlaps(bounds)) hole = r.intersect(bounds).inflate(6).intersect(bounds.deflate(3));
    }
    if (hole != _hole) setState(() => _hole = hole);
  }

  void _finish() {
    final s = _activeSpec;
    if (s != null) unawaited(TourMemory.markSeen(s));
    if (mounted) {
      setState(() {
        _index = -1;
        _hole = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Com o tutorial aberto, o "voltar" do Android fecha o TUTORIAL — sem
    // isso ele fechava a página (ou o app inteiro, na tela inicial).
    return PopScope(
      canPop: !isActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && isActive) _finish();
      },
      child: _buildStack(context),
    );
  }

  Widget _buildStack(BuildContext context) {
    return Stack(
      key: _hostKey,
      children: [
        widget.child,
        if (isActive)
          Positioned.fill(
            child: NotificationListener<SizeChangedLayoutNotification>(
              onNotification: (_) {
                WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
                return true;
              },
              child: LayoutBuilder(builder: (context, box) {
                WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
                return _TourLayer(
                  step: _steps[_index],
                  index: _index,
                  total: _steps.length,
                  hole: _hole,
                  area: Size(box.maxWidth, box.maxHeight),
                  onNext: () => _go(_index + 1, forward: true),
                  onBack: _index > 0 ? () => _go(_index - 1, forward: false) : null,
                  onSkip: _finish,
                );
              }),
            ),
          ),
      ],
    );
  }
}

class _TourLayer extends StatelessWidget {
  const _TourLayer({
    required this.step,
    required this.index,
    required this.total,
    required this.hole,
    required this.area,
    required this.onNext,
    required this.onBack,
    required this.onSkip,
  });

  final TourStep step;
  final int index;
  final int total;
  final Rect? hole;
  final Size area;
  final VoidCallback onNext;
  final VoidCallback? onBack;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final last = index == total - 1;
    final width = (area.width - 32).clamp(240.0, 380.0);

    final card = Material(
      key: const ValueKey('tour-balao'),
      color: Ind.surfaceHigher,
      elevation: 8,
      borderRadius: BorderRadius.circular(Ind.radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${index + 1} de $total', style: Ind.tag(color: Ind.accent)),
            const SizedBox(height: 6),
            Text(step.title, style: const TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w700, fontSize: 20)),
            const SizedBox(height: 6),
            Text(step.body, style: const TextStyle(color: Ind.textDim, height: 1.4, fontSize: 15)),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(onPressed: onSkip, child: const Text('Pular')),
                const Spacer(),
                if (onBack != null) TextButton(onPressed: onBack, child: const Text('Voltar')),
                const SizedBox(width: 4),
                FilledButton(onPressed: onNext, child: Text(last ? 'Entendi' : 'Próximo')),
              ],
            ),
          ],
        ),
      ),
    );

    // Onde o balão cabe: abaixo do alvo, senão acima, senão por cima do
    // rodapé (alvo alto, como uma lista inteira). Nunca sob a barra de status.
    const need = 230.0;
    final safeTop = MediaQuery.paddingOf(context).top + 8;
    final safeBottom = MediaQuery.paddingOf(context).bottom + 12;
    Widget placed;
    final h = hole;
    if (h == null) {
      placed = Center(child: SizedBox(width: width, child: card));
    } else {
      final left = (h.center.dx - width / 2).clamp(16.0, area.width - width - 16);
      final spaceBelow = area.height - h.bottom - safeBottom;
      final spaceAbove = h.top - safeTop;
      if (spaceBelow >= need) {
        placed = Positioned(left: left, width: width, top: h.bottom + 12, child: card);
      } else if (spaceAbove >= need) {
        placed = Positioned(left: left, width: width, bottom: area.height - h.top + 12, child: card);
      } else {
        placed = Positioned(left: left, width: width, bottom: safeBottom + 12, child: card);
      }
    }

    return Stack(
      children: [
        // Captura todo toque fora do balão: durante o tour a página não reage
        // (o usuário não navega para outra tela no meio de uma explicação).
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: CustomPaint(painter: _HolePainter(h)),
          ),
        ),
        placed,
      ],
    );
  }
}

class _HolePainter extends CustomPainter {
  _HolePainter(this.hole);
  final Rect? hole;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.72);
    final all = Path()..addRect(Offset.zero & size);
    final h = hole;
    if (h == null) {
      canvas.drawPath(all, dim);
      return;
    }
    final rr = RRect.fromRectAndRadius(h, const Radius.circular(Ind.radius));
    canvas.drawPath(Path.combine(PathOperation.difference, all, Path()..addRRect(rr)), dim);
    canvas.drawRRect(
      rr,
      Paint()
        ..color = Ind.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_HolePainter old) => old.hole != hole;
}

/// Botão "?" padrão — mora no topo de toda página, sempre visível (lição da
/// Retífica: ajuda não desce para a barra inferior do celular).
class HelpButton extends StatelessWidget {
  const HelpButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey('ajuda'),
      tooltip: 'Como usar esta tela',
      icon: const Icon(Icons.help_outline_rounded),
      onPressed: () => TourHost.maybeOf(context)?.start(),
    );
  }
}
