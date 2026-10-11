import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../core/utils/validators.dart';
import '../../models/device.dart';
import '../../services/runtime/hmi_runtime.dart';
import '../../widgets/common/common.dart';

/// Cadastro/edição de equipamento.
///
/// A peça central é o **Testar conexão**: o usuário descobre na hora se o IP
/// está certo, antes de criar variável e montar tela em cima de um endereço
/// errado. Quando falha, a tela mostra o que conferir, na ordem em que os
/// problemas costumam acontecer.
class DeviceFormPage extends StatefulWidget {
  const DeviceFormPage({super.key, this.device});
  final Device? device;

  @override
  State<DeviceFormPage> createState() => _DeviceFormPageState();
}

class _DeviceFormPageState extends State<DeviceFormPage> {
  final _form = GlobalKey<FormState>();
  late final String _id = widget.device?.id ?? newId('d');
  late DeviceKind _kind = widget.device?.kind ?? DeviceKind.modbusTcp;
  late final _name = TextEditingController(text: widget.device?.name ?? '');
  late final _host = TextEditingController(text: widget.device?.host ?? '');
  late final _port = TextEditingController(text: '${widget.device?.port ?? 502}');
  late final _unit = TextEditingController(text: '${widget.device?.unitId ?? 1}');
  late final _timeout = TextEditingController(text: '${widget.device?.timeoutMs ?? 1500}');
  late final _poll = TextEditingController(text: '${widget.device?.pollMs ?? 500}');

  ProbeResult? _probe;
  bool _probing = false;

  bool get _editing => widget.device != null;

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _unit, _timeout, _poll]) {
      c.dispose();
    }
    super.dispose();
  }

  Device _build() => Device(
        id: _id,
        name: _name.text.trim().isEmpty ? 'Equipamento' : _name.text.trim(),
        kind: _kind,
        host: _host.text.trim(),
        port: int.tryParse(_port.text) ?? 502,
        unitId: int.tryParse(_unit.text) ?? 1,
        timeoutMs: (int.tryParse(_timeout.text) ?? 1500).clamp(200, 10000),
        pollMs: (int.tryParse(_poll.text) ?? 500).clamp(100, 60000),
      );

  Future<void> _test() async {
    // Testar só exige o IP — validar o formulário inteiro marcava erro no
    // nome, que não tem nada a ver com o teste.
    if (_kind == DeviceKind.modbusTcp && !(_ipField.currentState?.validate() ?? false)) return;
    setState(() {
      _probing = true;
      _probe = null;
    });
    final r = await AppScope.of(context).runtime.probe(_build());
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probe = r;
    });
    // O resultado nasce abaixo do botão — em celular, atrás da barra "Salvar".
    // Sem rolar até ele, o usuário acha que o botão não fez nada.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _probeKey.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.9);
    });
  }

  final _probeKey = GlobalKey();
  final _moreKey = GlobalKey();
  final _ipField = GlobalKey<FormFieldState<String>>();

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    AppScope.of(context).controller.saveDevice(_build());
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    final c = AppScope.of(context).controller;
    final n = c.project.tagsOf(_id).length;
    if (!await confirmDelete(context,
        title: 'Apagar "${widget.device!.name}"?',
        body: n == 0
            ? 'O equipamento sai do projeto.'
            : 'O equipamento e as $n variáveis dele saem do projeto. Os elementos de tela que usavam essas variáveis ficam avisando "Escolha a variável".')) {
      return;
    }
    c.deleteDevice(_id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final tcp = _kind == DeviceKind.modbusTcp;
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Equipamento' : 'Novo equipamento'),
        actions: [
          if (_editing) IconButton(tooltip: 'Apagar', icon: Icon(Icons.delete_outline_rounded, color: Ind.alarm), onPressed: _delete),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(key: const ValueKey('salvar-equipamento'), onPressed: _save, icon: const Icon(Icons.check_rounded), label: const Text('Salvar')),
        ),
      ),
      body: Form(
        key: _form,
        // Só o essencial à vista: tipo, nome, IP e o teste. Porta, ID e tempos
        // quase nunca mudam — ficam em "Mais opções", já mostrando o valor.
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Ind.page, 12, Ind.page, 32),
          children: [
            ChoiceCards<DeviceKind>(
              options: const [
                ChoiceOption(value: DeviceKind.modbusTcp, title: 'Na rede', subtitle: 'Modbus TCP', icon: Icons.router_outlined),
                ChoiceOption(value: DeviceKind.demo, title: 'Demonstração', subtitle: 'Simulada', icon: Icons.smart_toy_outlined),
              ],
              selected: _kind,
              onChanged: (k) => setState(() {
                _kind = k;
                _probe = null;
              }),
            ),
            const SizedBox(height: Ind.spaceLarge),
            TextFormField(
              key: const ValueKey('campo-nome-equipamento'),
              controller: _name,
              validator: Validators.name,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Nome', hintText: 'Ex.: CLP da cortadora'),
            ),
            if (tcp) ...[
              const SizedBox(height: Ind.space),
              TextFormField(
                key: _ipField,
                controller: _host,
                validator: (v) => tcp ? Validators.host(v) : null,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: Ind.number(20),
                decoration: const InputDecoration(labelText: 'IP do equipamento', hintText: '192.168.0.10'),
                onChanged: (_) => setState(() => _probe = null),
              ),
            ],
            const SizedBox(height: Ind.space),
            OutlinedButton.icon(
              key: const ValueKey('testar-conexao'),
              onPressed: _probing ? null : _test,
              icon: _probing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.network_check_rounded),
              label: Text(_probing ? 'Testando…' : 'Testar conexão'),
            ),
            if (_probe != null) ...[const SizedBox(height: 12), KeyedSubtree(key: _probeKey, child: _ProbeCard(result: _probe!, tcp: tcp))],
            if (tcp) ...[
              const SizedBox(height: Ind.spaceLarge),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: _moreKey,
                  onExpansionChanged: (open) => revealAfterExpand(_moreKey, open),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: const Text('Mais opções'),
                  subtitle: Text('Porta ${_port.text} · ID ${_unit.text}', style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                  children: [
                    StepperField(label: 'Porta', controller: _port, min: 1, max: 65535, helper: 'Modbus TCP usa 502.', onChanged: () => setState(() {})),
                    const SizedBox(height: Ind.space),
                    StepperField(label: 'ID do escravo', controller: _unit, min: 0, max: 255, helper: 'Quase sempre 1.', onChanged: () => setState(() {})),
                    const SizedBox(height: Ind.space),
                    StepperField(label: 'Tempo de resposta (ms)', controller: _timeout, min: 200, max: 10000),
                    const SizedBox(height: Ind.space),
                    StepperField(label: 'Ler a cada (ms)', controller: _poll, min: 100, max: 60000),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProbeCard extends StatelessWidget {
  const _ProbeCard({required this.result, required this.tcp});
  final ProbeResult result;
  final bool tcp;

  @override
  Widget build(BuildContext context) {
    final ok = result.ok;
    final color = ok ? Ind.ok : Ind.alarm;
    return Container(
      key: ValueKey(ok ? 'teste-ok' : 'teste-falhou'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Ind.radius),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(ok ? Icons.check_circle_rounded : Icons.error_rounded, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                ok ? 'Equipamento respondeu${result.elapsedMs != null ? ' em ${result.elapsedMs} ms' : ''}' : 'Não conectou: ${result.message}',
                style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
          ]),
          // Por onde a conexão sai: "Wi-Fi 192.168.1.23/24 · sem internet".
          if (result.network != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 34),
              child: Text(result.network!, key: const ValueKey('teste-rede'), style: TextStyle(color: Ind.textDim, fontSize: 13)),
            ),
          ],
          if (!ok && tcp) ...[
            const SizedBox(height: 10),
            // O celular já sabe a própria rede: diz o que achou antes da lista.
            if (result.hint != null) ...[
              Text(result.hint!, key: const ValueKey('teste-dica'), style: const TextStyle(fontWeight: FontWeight.w600, height: 1.35)),
              const SizedBox(height: 10),
            ],
            Text(result.refused ? 'O equipamento está na rede, mas não aceitou nesta porta:' : 'Confira, nesta ordem:',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            // Recusou = achou o aparelho; o problema é porta ou Modbus
            // desligado. Nem vale mandar conferir Wi-Fi e IP.
            for (final t in result.refused
                ? const [
                    'A porta está certa? Modbus TCP usa 502 — confira em "Mais opções".',
                    'O Modbus TCP está ligado no equipamento? Alguns vêm desligados de fábrica.',
                  ]
                : [
                    if (result.hint == null) 'O celular está no mesmo Wi-Fi da máquina?',
                    'O IP está certo? (um número trocado é o erro mais comum)',
                    'O Modbus TCP está ligado no equipamento? Alguns vêm desligados de fábrica.',
                    'A porta é 502? O ID é 1?',
                  ])
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('•  ', style: TextStyle(color: Ind.textDim)),
                  Expanded(child: Text(t, style: TextStyle(color: Ind.textDim, height: 1.35))),
                ]),
              ),
          ],
        ],
      ),
    );
  }
}
