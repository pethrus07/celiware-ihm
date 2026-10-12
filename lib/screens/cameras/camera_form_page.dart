import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../core/utils/validators.dart';
import '../../models/camera.dart';
import '../../models/hmi_screen.dart';
import '../../services/cameras/camera_vault.dart';
import '../../widgets/common/adaptive.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/write_actions.dart';
import '../screens_page.dart';

enum _Leave { save, discard, keep }

/// Cadastro de câmera (CM-1): nome, máquina, endereço do vídeo, usuário e
/// senha à vista; fluxo leve e foto em "Mais opções".
///
/// A senha vai para o cofre do aparelho ao salvar — nunca para o projeto.
/// Endereço colado com usuário e senha dentro (`rtsp://admin:1234@…`) é
/// separado na hora: o usuário e a senha vão para os campos.
class CameraFormPage extends StatefulWidget {
  const CameraFormPage({super.key, this.camera, this.deviceId});
  final IpCamera? camera;

  /// Máquina já escolhida (câmera nova criada pelo botão de uma tela).
  final String? deviceId;

  @override
  State<CameraFormPage> createState() => _CameraFormPageState();
}

class _CameraFormPageState extends State<CameraFormPage> {
  final _form = GlobalKey<FormState>();
  final _moreKey = GlobalKey();
  final _more = ExpansibleController();
  late final String _id = widget.camera?.id ?? newId('cam');
  late final _name = TextEditingController(text: widget.camera?.name ?? '');
  late final _url = TextEditingController(text: widget.camera?.url ?? '');
  late final _sub = TextEditingController(text: widget.camera?.substreamUrl ?? '');
  late final _photo = TextEditingController(text: widget.camera?.snapshotUrl ?? '');
  late final _user = TextEditingController(text: widget.camera?.username ?? '');
  final _pass = TextEditingController();
  String? _deviceId;
  bool _showPass = false;
  bool _saving = false;

  /// A senha guardada está no cofre deste aparelho (nulo = conferindo).
  bool? _stored;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;
  late String _initial;

  bool get _editing => widget.camera != null;

  @override
  void initState() {
    super.initState();
    _deviceId = widget.camera?.deviceId ?? widget.deviceId;
    _initial = _snapshot();
    final ref = widget.camera?.secretRef;
    if (ref != null) {
      CameraVault.instance.read(ref).then((v) {
        if (mounted) setState(() => _stored = v != null);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Câmera nova num projeto de uma máquina só: já vem com ela.
    if (!_editing && _deviceId == null) {
      final machines = AppScope.of(context).controller.project.equipment;
      if (machines.length == 1) {
        _deviceId = machines.single.id;
        _initial = _snapshot();
      }
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _url, _sub, _photo, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  String _snapshot() => jsonEncode([_name.text.trim(), _url.text.trim(), _sub.text.trim(), _photo.text.trim(), _user.text.trim(), _pass.text, _deviceId]);

  /// Endereço colado com usuário e senha: separa na hora.
  void _urlChanged(TextEditingController c) {
    final parts = CameraUrl.split(c.text);
    if (parts.user != null || parts.password != null) {
      c.value = TextEditingValue(text: parts.url, selection: TextSelection.collapsed(offset: parts.url.length));
      if (parts.user != null) _user.text = parts.user!;
      if (parts.password != null) _pass.text = parts.password!;
      WriteActions.toast(context, 'Usuário e senha saíram do endereço e foram para os campos: a senha fica só neste aparelho.');
    }
    setState(() {});
  }

  Future<void> _fromBrand(CameraBrand brand) async {
    final ip = await askText(context,
        title: 'IP da câmera ${brand.name}', label: 'IP', hint: 'Ex.: 192.168.1.64', initial: CameraUrl.host(_url.text) ?? '',
        // O mesmo teclado do IP do equipamento: números e ponto, sem trocar de teclado.
        keyboardType: const TextInputType.numberWithOptions(decimal: true));
    if (ip == null || !mounted) return;
    final err = Validators.host(ip);
    if (err != null) {
      WriteActions.toast(context, err.replaceAll('do equipamento', 'da câmera'), error: true);
      return;
    }
    setState(() {
      _url.text = brand.fill(brand.main, ip);
      _sub.text = brand.fill(brand.sub, ip);
      _photo.text = brand.fill(brand.photo, ip);
      if (_user.text.trim().isEmpty) _user.text = 'admin';
    });
  }

  String _moreSummary() {
    final parts = [
      if (_sub.text.trim().isNotEmpty) 'Fluxo leve',
      if (_photo.text.trim().isNotEmpty) 'Foto',
    ];
    return parts.isEmpty ? 'Fluxo leve e foto da câmera' : parts.join(' · ');
  }

  String _passHelper() {
    if (_pass.text.isNotEmpty || !(widget.camera?.hasPassword ?? false)) {
      return 'Fica guardada só neste aparelho, fora do arquivo do projeto.';
    }
    if (_stored == false) return 'A senha não veio com o projeto: digite de novo.';
    return 'Guardada neste aparelho. Vazio = continua a mesma.';
  }

  Future<void> _save() async {
    // "Mais opções" fechado não monta os campos de dentro: confere à mão.
    final moreError = (_sub.text.trim().isEmpty ? null : CameraUrl.rtspError(_sub.text)) ?? CameraUrl.httpError(_photo.text);
    final ok = (_form.currentState?.validate() ?? false) && moreError == null;
    if (!ok) {
      setState(() => _autovalidate = AutovalidateMode.onUserInteraction);
      if (moreError != null && !_more.isExpanded) {
        _more.expand();
        Timer(const Duration(milliseconds: 280), () {
          if (mounted) _form.currentState?.validate();
        });
      }
      return;
    }
    final vault = CameraVault.instance;
    final c = AppScope.of(context).controller;
    final user = _user.text.trim();
    final password = _pass.text;
    var ref = widget.camera?.secretRef;
    setState(() => _saving = true);
    try {
      if (user.isEmpty && password.isEmpty) {
        if (ref != null) await vault.delete(ref);
        ref = null;
      } else if (password.isNotEmpty) {
        ref ??= IpCamera.newSecretRef();
        await vault.write(ref, password);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        WriteActions.toast(context, 'Não consegui guardar a senha neste aparelho.', error: true);
      }
      return;
    }
    c.saveCamera(IpCamera(
      id: _id,
      name: _name.text.trim(),
      deviceId: _deviceId,
      url: _url.text.trim(),
      substreamUrl: _sub.text.trim(),
      snapshotUrl: _photo.text.trim(),
      username: user,
      secretRef: ref,
    ));
    if (mounted) Navigator.pop(context, _id);
  }

  Future<void> _leave() async {
    if (_snapshot() == _initial) {
      Navigator.pop(context);
      return;
    }
    final choice = await showDialog<_Leave>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('descartar-alteracoes'),
        title: const Text('Descartar alterações?'),
        content: const Text('O que foi mudado nesta câmera ainda não foi salvo.', style: TextStyle(height: 1.4)),
        actions: [
          TextButton(key: const ValueKey('continuar-editando'), onPressed: () => Navigator.pop(ctx, _Leave.keep), child: const Text('Continuar editando')),
          TextButton(
            key: const ValueKey('descartar'),
            style: TextButton.styleFrom(foregroundColor: Ind.textFor(Ind.alarm)),
            onPressed: () => Navigator.pop(ctx, _Leave.discard),
            child: const Text('Descartar'),
          ),
          FilledButton(key: const ValueKey('salvar-e-sair'), onPressed: () => Navigator.pop(ctx, _Leave.save), child: const Text('Salvar')),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case _Leave.save:
        await _save();
      case _Leave.discard:
        Navigator.pop(context);
      case _Leave.keep || null:
        break;
    }
  }

  Future<void> _delete() async {
    final c = AppScope.of(context).controller;
    final camera = widget.camera!;
    final buttons = [
      for (final s in c.project.screens)
        for (final e in s.elements)
          if (e.type == ElementType.button && e.props['cameraId'] == camera.id) e,
    ].length;
    final body = [
      'A câmera sai do projeto e a senha sai deste aparelho.',
      if (buttons == 1) 'Um botão de tela abre esta câmera e vai ficar sem câmera.',
      if (buttons > 1) '$buttons botões de tela abrem esta câmera e vão ficar sem câmera.',
    ].join(' ');
    if (!await confirmDelete(context, title: 'Apagar "${camera.name}"?', body: body)) return;
    if (camera.secretRef != null) await CameraVault.instance.delete(camera.secretRef!);
    c.deleteCamera(camera.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final project = AppScope.watch(context).controller.project;
    final machines = project.equipment;
    final guess = _sub.text.trim().isEmpty ? CameraUrl.substreamGuess(_url.text) : null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_editing ? 'Câmera' : 'Nova câmera'),
          actions: [
            if (_editing) IconButton(tooltip: 'Apagar', icon: Icon(Icons.delete_outline_rounded, color: Ind.alarm), onPressed: _delete),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton.icon(
              key: const ValueKey('salvar-camera'),
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Salvar'),
            ),
          ),
        ),
        body: FormWidth(
          child: Form(
            key: _form,
            autovalidateMode: _autovalidate,
            child: ListView(
              key: const ValueKey('formulario-camera'),
              padding: const EdgeInsets.fromLTRB(Ind.page, 20, Ind.page, 32),
              children: [
                TextFormField(
                  key: const ValueKey('campo-nome-camera'),
                  controller: _name,
                  validator: Validators.name,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Nome', hintText: 'Ex.: Saída da cortadora'),
                ),
                if (machines.isNotEmpty) ...[
                  const SectionHeader('Máquina', padding: EdgeInsets.fromLTRB(0, 24, 0, 10)),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final d in machines)
                      ChoiceChip(
                        key: ValueKey('maquina-${d.id}'),
                        label: Text(d.name),
                        selected: _deviceId == d.id,
                        onSelected: (_) => setState(() => _deviceId = d.id),
                      ),
                    ChoiceChip(
                      key: const ValueKey('maquina-nenhuma'),
                      label: const Text('Nenhuma'),
                      selected: _deviceId == null,
                      onSelected: (_) => setState(() => _deviceId = null),
                    ),
                  ]),
                ],
                const SizedBox(height: Ind.spaceLarge),
                TextFormField(
                  key: const ValueKey('campo-url-camera'),
                  controller: _url,
                  validator: (v) => CameraUrl.rtspError(v ?? ''),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Endereço do vídeo (RTSP)',
                    hintText: 'rtsp://192.168.1.64:554/…',
                    helperText: 'Vem no manual ou no app da câmera.',
                  ),
                  onChanged: (_) => _urlChanged(_url),
                ),
                const SizedBox(height: 8),
                Text('Não sabe o endereço? Escolha a marca e digite o IP:', style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final b in CameraBrand.all)
                    ActionChip(key: ValueKey('marca-${b.name}'), label: Text(b.name), onPressed: () => _fromBrand(b)),
                ]),
                if (guess != null) ...[
                  const SizedBox(height: 10),
                  SuggestionTile(
                    key: const ValueKey('sugestao-fluxo-leve'),
                    icon: Icons.speed_rounded,
                    text: 'Usar também o fluxo leve desta câmera: abre mais rápido e gasta menos Wi-Fi.',
                    onTap: () => setState(() => _sub.text = guess),
                  ),
                ],
                const SizedBox(height: Ind.spaceLarge),
                TextFormField(
                  key: const ValueKey('campo-usuario-camera'),
                  controller: _user,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Usuário', hintText: 'Ex.: admin'),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: Ind.space),
                TextFormField(
                  key: const ValueKey('campo-senha-camera'),
                  controller: _pass,
                  obscureText: !_showPass,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Senha',
                    helperText: _passHelper(),
                    helperMaxLines: 2,
                    helperStyle: _stored == false && _pass.text.isEmpty ? TextStyle(color: Ind.textFor(Ind.warn)) : null,
                    suffixIcon: IconButton(
                      tooltip: _showPass ? 'Esconder' : 'Mostrar',
                      icon: Icon(_showPass ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      onPressed: () => setState(() => _showPass = !_showPass),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: Ind.spaceLarge),
                Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    key: _moreKey,
                    controller: _more,
                    onExpansionChanged: (open) => revealAfterExpand(_moreKey, open),
                    tilePadding: EdgeInsets.zero,
                    // O primeiro filho é um campo: o rótulo dele flutua acima da caixa
                    // e era cortado pela borda da seção.
                    childrenPadding: const EdgeInsets.only(top: 10, bottom: 8),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    title: const Text('Mais opções'),
                    subtitle: Text(_moreSummary(), style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                    children: [
                      TextFormField(
                        key: const ValueKey('campo-fluxo-leve'),
                        controller: _sub,
                        validator: (v) => (v ?? '').trim().isEmpty ? null : CameraUrl.rtspError(v!),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Fluxo leve (substream)',
                          hintText: 'rtsp://…/102',
                          helperText: 'Resolução baixa, em H.264: é o que a tela abre. Vazio = só o endereço de cima.',
                          helperMaxLines: 2,
                        ),
                        onChanged: (_) => _urlChanged(_sub),
                      ),
                      const SizedBox(height: Ind.space),
                      TextFormField(
                        key: const ValueKey('campo-foto-camera'),
                        controller: _photo,
                        validator: (v) => CameraUrl.httpError(v ?? ''),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Foto (endereço HTTP)',
                          hintText: 'http://192.168.1.64/…',
                          helperText: 'Com ele, a tela da câmera ganha o botão de foto. Vazio = sem foto.',
                          helperMaxLines: 2,
                        ),
                        onChanged: (_) => _urlChanged(_photo),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
