import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/camera.dart';
import '../../services/cameras/camera_players.dart';
import '../../services/cameras/camera_session.dart';
import '../../services/cameras/camera_snapshot.dart';
import '../../services/cameras/camera_vault.dart';
import '../../widgets/cameras/camera_password_dialog.dart';
import '../../widgets/cameras/camera_status_pill.dart';
import '../../widgets/hmi/write_actions.dart';
import 'camera_form_page.dart';

/// Câmera em tela cheia (CM-2, CM-3): o vídeo, o estado com o atraso e, se a
/// câmera tiver, a foto.
///
/// Abre pelo botão "Abrir câmera" da tela de operação ou por Mais → Câmeras.
/// Fechar a página ou mandar o app para segundo plano **descarta o player**:
/// nada fica recebendo nem decodificando vídeo escondido.
class CameraViewPage extends StatefulWidget {
  const CameraViewPage({super.key, required this.cameraId});
  final String cameraId;

  static Future<void> open(BuildContext context, String cameraId) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => CameraViewPage(cameraId: cameraId)));

  @override
  State<CameraViewPage> createState() => _CameraViewPageState();
}

class _CameraViewPageState extends State<CameraViewPage> with WidgetsBindingObserver {
  CameraSession? _session;
  bool _asked = false;
  bool _photo = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Tela cheia de verdade: as barras do Android somem e voltam com um gesto.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session != null) return;
    final camera = AppScope.of(context).controller.project.camera(widget.cameraId);
    if (camera == null) return;
    _session = CameraSession(camera, vault: CameraVault.instance, newPlayer: CameraPlayers.factory)..addListener(_changed);
    unawaited(_session!.start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session?.removeListener(_changed);
    _session?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _session?.pause();
      case AppLifecycleState.resumed:
        _session?.resume();
      default:
        break;
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    // Projeto importado: a senha não veio no arquivo. Pede uma vez, sozinho.
    final s = _session!;
    if (s.status.link == CameraLink.needsPassword && !_asked) {
      _asked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _askPassword(reason: 'A senha não vem no arquivo do projeto: digite uma vez neste aparelho.');
      });
    }
  }

  Future<void> _askPassword({String? reason}) async {
    final s = _session;
    if (s == null) return;
    final next = await askCameraPassword(context, s.camera, reason: reason);
    if (next != null && mounted) await s.update(next);
  }

  Future<void> _takePhoto(IpCamera camera) async {
    setState(() => _photo = true);
    try {
      final ref = camera.secretRef;
      final password = ref == null ? null : await CameraVault.instance.read(ref);
      final bytes = await CameraSnapshot.fetch(camera.snapshotUrl, user: camera.username, password: password);
      if (!mounted) return;
      setState(() => _photo = false);
      await _showPhoto(camera, bytes);
    } on SnapshotError catch (e) {
      if (mounted) WriteActions.toast(context, 'Sem foto: ${e.message}.', error: true);
    } finally {
      if (mounted) setState(() => _photo = false);
    }
  }

  Future<void> _showPhoto(IpCamera camera, Uint8List bytes) async {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final when = '${two(now.day)}/${two(now.month)} ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, Ind.page),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${camera.name} · $when', style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(Ind.radiusSmall),
            child: Image.memory(bytes, key: const ValueKey('foto-camera'), fit: BoxFit.contain),
          ),
          const SizedBox(height: Ind.space),
          FilledButton.icon(
            key: const ValueKey('enviar-foto'),
            icon: const Icon(Icons.share_rounded),
            label: const Text('Enviar'),
            onPressed: () async {
              try {
                final dir = await getTemporaryDirectory();
                final name = 'camera-${_fileSafe(camera.name)}-$stamp.jpg';
                final file = File('${dir.path}/$name');
                await file.writeAsBytes(bytes, flush: true);
                await SharePlus.instance.share(ShareParams(
                  files: [XFile(file.path, mimeType: 'image/jpeg')],
                  subject: '${camera.name} · $when',
                ));
              } catch (e) {
                if (ctx.mounted) WriteActions.toast(ctx, 'Não consegui enviar a foto.', error: true);
              }
            },
          ),
        ]),
      ),
    );
  }

  static String _fileSafe(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');

  @override
  Widget build(BuildContext context) {
    final project = AppScope.watch(context).controller.project;
    final session = _session;
    final camera = project.camera(widget.cameraId);
    if (session == null || camera == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: const Center(child: Text('Esta câmera foi apagada.', style: TextStyle(color: Colors.white70))),
      );
    }
    final status = session.status;
    final player = session.player;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(child: player == null ? const SizedBox() : KeyedSubtree(key: const ValueKey('video-camera'), child: player.view())),
        if (status.link != CameraLink.live) Positioned.fill(child: _StateNotice(status: status, camera: camera, onPassword: () => _askPassword(), onRetry: session.start)),
        // Barra de cima, sobre o vídeo, num degradê que some.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xB0000000), Color(0x00000000)]),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 20),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  IconButton(
                    key: const ValueKey('fechar-camera'),
                    tooltip: 'Fechar',
                    color: Colors.white,
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(camera.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        CameraStatusPill(status: status),
                      ]),
                    ),
                  ),
                  if (camera.snapshotUrl.isNotEmpty)
                    IconButton(
                      key: const ValueKey('foto-da-camera'),
                      tooltip: 'Foto',
                      color: Colors.white,
                      icon: _photo
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.photo_camera_outlined),
                      onPressed: _photo ? null : () => _takePhoto(camera),
                    ),
                  PopupMenuButton<String>(
                    key: const ValueKey('menu-camera'),
                    iconColor: Colors.white,
                    tooltip: 'Mais opções',
                    onSelected: (v) async {
                      switch (v) {
                        case 'alta':
                          await session.setHighQuality(true);
                        case 'leve':
                          await session.setHighQuality(false);
                        case 'senha':
                          await _askPassword();
                        case 'editar':
                          await Navigator.push(context, MaterialPageRoute(builder: (_) => CameraFormPage(camera: camera)));
                          final edited = mounted ? AppScope.of(this.context).controller.project.camera(camera.id) : null;
                          if (edited != null) await session.update(edited);
                      }
                    },
                    itemBuilder: (_) => [
                      if (session.canSwitchQuality)
                        session.highQuality
                            ? const PopupMenuItem(value: 'leve', child: Text('Ver no fluxo leve'))
                            : const PopupMenuItem(value: 'alta', child: Text('Ver em alta qualidade')),
                      const PopupMenuItem(value: 'senha', child: Text('Usuário e senha')),
                      const PopupMenuItem(value: 'editar', child: Text('Editar câmera')),
                    ],
                  ),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// O que aparece no lugar do vídeo enquanto não há imagem: o estado em
/// letra grande, o motivo e o único botão que resolve.
class _StateNotice extends StatelessWidget {
  const _StateNotice({required this.status, required this.camera, required this.onPassword, required this.onRetry});
  final CameraStatus status;
  final IpCamera camera;
  final VoidCallback onPassword;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final (color, icon, _) = CameraStatusPill.describe(status);
    final (title, body) = switch (status.link) {
      CameraLink.connecting => ('Conectando à câmera', camera.host),
      CameraLink.noSignal => ('Sem sinal', status.detail),
      CameraLink.authFailed => (
          'Senha recusada',
          '${camera.username.isEmpty ? 'A câmera pede usuário e senha.' : 'A câmera recusou o usuário "${camera.username}" ou a senha.'} '
              'O app não tenta de novo sozinho: muita câmera bloqueia o usuário depois de algumas tentativas erradas.',
        ),
      CameraLink.needsPassword => ('Falta a senha', 'A senha não vem no arquivo do projeto: digite uma vez neste aparelho.'),
      CameraLink.paused || CameraLink.live => ('', ''),
    };
    if (title.isEmpty) return const SizedBox();
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 96, 32, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (status.link == CameraLink.connecting)
            SizedBox(width: 40, height: 40, child: CircularProgressIndicator(color: color, strokeWidth: 3))
          else
            Icon(icon, size: 44, color: color),
          const SizedBox(height: 16),
          Text(title, key: const ValueKey('estado-camera'), style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
          if (body.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(body[0].toUpperCase() + body.substring(1),
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, height: 1.4)),
          ],
          if (status.link == CameraLink.noSignal) ...[
            const SizedBox(height: 16),
            OutlinedButton(
              key: const ValueKey('tentar-agora'),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
              onPressed: onRetry,
              child: const Text('Tentar agora'),
            ),
          ],
          if (status.link == CameraLink.authFailed || status.link == CameraLink.needsPassword) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('digitar-senha'),
              onPressed: onPassword,
              icon: const Icon(Icons.key_rounded),
              label: const Text('Digitar a senha'),
            ),
          ],
        ]),
      ),
    );
  }
}
