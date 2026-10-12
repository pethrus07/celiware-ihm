import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/camera.dart';
import '../../services/cameras/camera_vault.dart';

/// Pede usuário e senha da câmera e guarda: a senha no cofre do aparelho; o
/// usuário e a chave do cofre no projeto. Devolve a câmera atualizada (já
/// salva) ou nulo se cancelou.
Future<IpCamera?> askCameraPassword(BuildContext context, IpCamera camera, {String? reason}) async {
  final controller = AppScope.of(context).controller;
  final user = TextEditingController(text: camera.username);
  final pass = TextEditingController();
  var show = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        key: const ValueKey('dialogo-senha-camera'),
        icon: Icon(Icons.key_rounded, color: Ind.accent),
        title: Text('Senha de "${camera.name}"'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (reason != null) ...[
              Text(reason, style: const TextStyle(height: 1.4)),
              const SizedBox(height: Ind.space),
            ],
            TextField(
              key: const ValueKey('campo-usuario-camera-dialogo'),
              controller: user,
              autofocus: camera.username.isEmpty,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Usuário'),
            ),
            const SizedBox(height: Ind.space),
            TextField(
              key: const ValueKey('campo-senha-camera-dialogo'),
              controller: pass,
              autofocus: camera.username.isNotEmpty,
              obscureText: !show,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Senha',
                suffixIcon: IconButton(
                  tooltip: show ? 'Esconder' : 'Mostrar',
                  icon: Icon(show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: () => setState(() => show = !show),
                ),
              ),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 10),
            Text('Fica guardada só neste aparelho: não vai no arquivo do projeto.',
                style: TextStyle(color: Ind.textMuted, fontSize: 12.5, height: 1.35)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(key: const ValueKey('ok-senha-camera'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Entrar')),
        ],
      ),
    ),
  );
  // Os campos não são descartados aqui: o diálogo ainda os desenha enquanto
  // some (como no askText das telas).
  final username = user.text.trim();
  final password = pass.text;
  if (ok != true) return null;
  final vault = CameraVault.instance;
  IpCamera next;
  if (password.isEmpty) {
    // Sem senha: a câmera passa a abrir sem senha.
    if (camera.secretRef != null) await vault.delete(camera.secretRef!);
    next = camera.copyWith(username: username, clearSecret: true);
  } else {
    final ref = camera.secretRef ?? IpCamera.newSecretRef();
    await vault.write(ref, password);
    next = camera.copyWith(username: username, secretRef: ref);
  }
  controller.saveCamera(next);
  return next;
}
