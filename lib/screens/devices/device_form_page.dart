import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/modbus/modbus_framing.dart';
import '../../core/mqtt/mqtt_error.dart';
import '../../core/mqtt/mqtt_topic.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../core/utils/validators.dart';
import '../../models/device.dart';
import '../../models/mqtt_config.dart';
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
  late bool _demo = widget.device?.isDemo ?? false;

  /// Protocolo de rede: Modbus TCP, RTU/ASCII "cru" por um gateway serial,
  /// ou MQTT (o IP passa a ser o do broker).
  late _Protocol _protocol = switch (widget.device) {
    Device(kind: DeviceKind.modbusRtuTcp, framing: ModbusFraming.ascii) => _Protocol.ascii,
    Device(kind: DeviceKind.modbusRtuTcp) => _Protocol.rtu,
    Device(kind: DeviceKind.mqtt) => _Protocol.mqtt,
    _ => _Protocol.tcp,
  };
  late final MqttBroker _broker = widget.device?.mqtt ?? const MqttBroker();
  late bool _tls = _broker.tls;
  late final _user = TextEditingController(text: _broker.username);
  late final _pass = TextEditingController(text: _broker.password);
  late final _clientId = TextEditingController(text: _broker.clientId);
  late final _keepAlive = TextEditingController(text: '${_broker.keepAliveSec}');
  late final _statusTopic = TextEditingController(text: _broker.statusTopic);
  late final _offline = TextEditingController(text: _broker.offlinePayload);
  bool _showPass = false;

  bool get _mqtt => !_demo && _protocol == _Protocol.mqtt;
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
    for (final c in [_name, _host, _port, _unit, _timeout, _poll, _user, _pass, _clientId, _keepAlive, _statusTopic, _offline]) {
      c.dispose();
    }
    super.dispose();
  }

  Device _build() => Device(
        id: _id,
        name: _name.text.trim().isEmpty ? 'Equipamento' : _name.text.trim(),
        kind: _demo
            ? DeviceKind.demo
            : switch (_protocol) {
                _Protocol.tcp => DeviceKind.modbusTcp,
                _Protocol.mqtt => DeviceKind.mqtt,
                _ => DeviceKind.modbusRtuTcp,
              },
        framing: _protocol == _Protocol.ascii ? ModbusFraming.ascii : ModbusFraming.rtu,
        host: _host.text.trim(),
        port: int.tryParse(_port.text) ?? 502,
        unitId: int.tryParse(_unit.text) ?? 1,
        timeoutMs: (int.tryParse(_timeout.text) ?? 1500).clamp(200, 10000),
        pollMs: (int.tryParse(_poll.text) ?? 500).clamp(100, 60000),
        // Só MQTT guarda broker; nos outros fica o padrão (e o arquivo, igual).
        mqtt: _mqtt
            ? MqttBroker(
                tls: _tls,
                username: _user.text.trim(),
                password: _pass.text,
                keepAliveSec: (int.tryParse(_keepAlive.text) ?? 30).clamp(0, 65535),
                clientId: _clientId.text.trim(),
                statusTopic: _statusTopic.text.trim(),
                offlinePayload: _offline.text.trim().isEmpty ? 'offline' : _offline.text.trim(),
              )
            : const MqttBroker(),
      );

  /// Trocar de protocolo leva junto a porta padrão — quem escolhe MQTT quase
  /// nunca quer a 502 que já estava no campo.
  void _setProtocol(_Protocol p) {
    final port = int.tryParse(_port.text);
    if (p == _Protocol.mqtt && (port == 502 || port == null)) {
      _port.text = '${_tls ? MqttBroker.tlsPort : MqttBroker.defaultPort}';
    } else if (p != _Protocol.mqtt && (port == MqttBroker.defaultPort || port == MqttBroker.tlsPort)) {
      _port.text = '502';
    }
    _protocol = p;
    _probe = null;
  }

  void _setTls(bool on) {
    final port = int.tryParse(_port.text);
    if (on && port == MqttBroker.defaultPort) _port.text = '${MqttBroker.tlsPort}';
    if (!on && port == MqttBroker.tlsPort) _port.text = '${MqttBroker.defaultPort}';
    _tls = on;
    _probe = null;
  }

  /// Resumo de "Mais opções" fechado.
  String _moreSummary() {
    if (!_mqtt) return '${_protocol.short} · Porta ${_port.text} · ID ${_unit.text}';
    return [
      'MQTT · Porta ${_port.text}',
      if (_tls) 'TLS',
      if (_user.text.trim().isNotEmpty) _user.text.trim(),
      if (_statusTopic.text.trim().isNotEmpty) 'aviso de queda',
    ].join(' · ');
  }

  Future<void> _test() async {
    // Testar só exige o IP — validar o formulário inteiro marcava erro no
    // nome, que não tem nada a ver com o teste.
    if (!_demo && !(_ipField.currentState?.validate() ?? false)) return;
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
    final tcp = !_demo;
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
            ChoiceCards<bool>(
              options: [
                ChoiceOption(value: false, title: 'Na rede', subtitle: _protocol.subtitle, icon: Icons.router_outlined),
                const ChoiceOption(value: true, title: 'Demonstração', subtitle: 'Simulada', icon: Icons.smart_toy_outlined),
              ],
              selected: _demo,
              onChanged: (k) => setState(() {
                _demo = k;
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
                decoration: InputDecoration(labelText: _mqtt ? 'IP do broker' : 'IP do equipamento', hintText: '192.168.0.10'),
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
            if (_probe != null) ...[const SizedBox(height: 12), KeyedSubtree(key: _probeKey, child: _ProbeCard(result: _probe!, tcp: tcp, mqtt: _mqtt))],
            if (tcp) ...[
              const SizedBox(height: Ind.spaceLarge),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: _moreKey,
                  onExpansionChanged: (open) => revealAfterExpand(_moreKey, open),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  title: const Text('Mais opções'),
                  subtitle: Text(_moreSummary(), style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                  children: [
                    // Gateway serial→Ethernet (RS-485 do outro lado) que repassa
                    // RTU/ASCII cru, ou um broker MQTT: escolhas raras, por isso
                    // ficam aqui.
                    Text('Protocolo', style: TextStyle(color: Ind.textDim, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final p in _Protocol.values)
                        ChoiceChip(
                          key: ValueKey('protocolo-${p.name}'),
                          label: Text(p.chip),
                          selected: _protocol == p,
                          onSelected: (_) => setState(() => _setProtocol(p)),
                        ),
                    ]),
                    if (_protocol == _Protocol.rtu || _protocol == _Protocol.ascii) ...[
                      const SizedBox(height: 6),
                      Text('Para conversor RS-485 → Ethernet que repassa os bytes sem converter. Se o conversor faz a conversão para Modbus TCP, use Modbus TCP.',
                          style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.35)),
                    ],
                    if (_mqtt) ..._mqttOptions() else ...[
                      const SizedBox(height: Ind.space),
                      StepperField(label: 'Porta', controller: _port, min: 1, max: 65535, helper: _protocol == _Protocol.tcp ? 'Modbus TCP usa 502.' : 'A do gateway (veja o manual dele; ex.: 4001, 8899).', onChanged: () => setState(() {})),
                      const SizedBox(height: Ind.space),
                      StepperField(label: 'ID do escravo', controller: _unit, min: 0, max: 255, helper: 'Quase sempre 1.', onChanged: () => setState(() {})),
                      const SizedBox(height: Ind.space),
                      StepperField(label: 'Tempo de resposta (ms)', controller: _timeout, min: 200, max: 10000),
                      const SizedBox(height: Ind.space),
                      StepperField(label: 'Ler a cada (ms)', controller: _poll, min: 100, max: 60000),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _refresh([VoidCallback? change]) => setState(change ?? () {});

  /// "Mais opções" do MQTT, na ordem em que costumam ser mexidas: porta,
  /// usuário e senha, TLS. Aviso de queda, sinal de vida, ID e tempo são raros.
  List<Widget> _mqttOptions() => [
        const SizedBox(height: 6),
        Text('O app assina os tópicos num broker da rede (Mosquitto, Node-RED, CLP ou ESP32 com MQTT). O IP acima é o do broker.',
            style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.35)),
        const SizedBox(height: Ind.space),
        StepperField(label: 'Porta', controller: _port, min: 1, max: 65535, helper: 'MQTT usa 1883; com TLS, 8883.', onChanged: () => _refresh()),
        const SizedBox(height: Ind.space),
        TextFormField(
          key: const ValueKey('campo-usuario-mqtt'),
          controller: _user,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Usuário', hintText: 'Vazio = broker sem senha'),
          onChanged: (_) => _refresh(),
        ),
        const SizedBox(height: Ind.space),
        TextFormField(
          key: const ValueKey('campo-senha-mqtt'),
          controller: _pass,
          obscureText: !_showPass,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Senha',
            suffixIcon: IconButton(
              tooltip: _showPass ? 'Esconder' : 'Mostrar',
              icon: Icon(_showPass ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () => _refresh(() => _showPass = !_showPass),
            ),
          ),
        ),
        SwitchListTile(
          key: const ValueKey('mqtt-tls'),
          contentPadding: EdgeInsets.zero,
          value: _tls,
          onChanged: (v) => _refresh(() => _setTls(v)),
          title: const Text('Conexão segura (TLS)'),
          subtitle: const Text('O certificado do broker precisa ser confiável para o celular.'),
        ),
        const SizedBox(height: Ind.spaceSmall),
        TextFormField(
          controller: _statusTopic,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Tópico de aviso de queda (LWT)',
            hintText: 'Ex.: cortadora/status',
            helperText: 'Se o equipamento deixa testamento no broker, as variáveis dele ficam "sem comunicação" quando ele cai.',
            helperMaxLines: 3,
          ),
          validator: (v) => v == null || v.trim().isEmpty || MqttTopic.isValidFilter(v.trim()) ? null : 'Tópico inválido',
          onChanged: (_) => _refresh(),
        ),
        if (_statusTopic.text.trim().isNotEmpty) ...[
          const SizedBox(height: Ind.space),
          TextFormField(
            controller: _offline,
            decoration: const InputDecoration(labelText: 'Mensagem de queda', helperText: 'O que o testamento publica. Qualquer outra mensagem ali = voltou.', helperMaxLines: 2),
          ),
        ],
        const SizedBox(height: Ind.space),
        StepperField(label: 'Sinal de vida a cada (s)', controller: _keepAlive, min: 0, max: 65535, helper: 'Keep-alive: avisa o broker que o app está vivo e percebe Wi-Fi que caiu. 0 desliga.'),
        const SizedBox(height: Ind.space),
        TextFormField(
          controller: _clientId,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'ID do cliente', hintText: 'Automático', helperText: 'Vazio: um ID novo a cada conexão. Fixo só se o broker exigir.', helperMaxLines: 2),
        ),
        const SizedBox(height: Ind.space),
        StepperField(label: 'Tempo de resposta (ms)', controller: _timeout, min: 200, max: 10000),
      ];
}

class _ProbeCard extends StatelessWidget {
  const _ProbeCard({required this.result, required this.tcp, this.mqtt = false});
  final ProbeResult result;
  final bool tcp;
  final bool mqtt;

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
                ok ? '${mqtt ? 'Broker' : 'Equipamento'} respondeu${result.elapsedMs != null ? ' em ${result.elapsedMs} ms' : ''}' : 'Não conectou: ${result.message}',
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
            Text(result.refused ? '${mqtt ? 'O broker' : 'O equipamento'} está na rede, mas não aceitou:' : 'Confira, nesta ordem:',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            // Recusou = achou o aparelho; o problema é porta ou Modbus
            // desligado. Nem vale mandar conferir Wi-Fi e IP.
            for (final t in mqtt ? _mqttChecks() : result.refused
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

  /// O que conferir quando o broker não conecta. Senha recusada tem uma
  /// conferência só; porta recusada aponta o tropeço mais comum: o Mosquitto 2
  /// vem aceitando só conexões do próprio computador.
  List<String> _mqttChecks() {
    if (result.message == MqttCommError.badCredentials) {
      return const ['Usuário e senha estão iguais aos do broker? Maiúsculas contam — confira em "Mais opções".'];
    }
    if (result.refused) {
      return const [
        'A porta está certa? MQTT usa 1883; com TLS, 8883.',
        'O broker aceita conexões da rede? O Mosquitto 2 só aceita do próprio computador até ganhar "listener 1883" e "allow_anonymous true" (ou usuário e senha) no mosquitto.conf.',
      ];
    }
    return [
      if (result.hint == null) 'O celular está no mesmo Wi-Fi do broker?',
      'O IP é o do broker (o computador, CLP ou ESP32 que roda o MQTT)?',
      'O broker está rodando? (ex.: serviço Mosquitto)',
      'A porta é 1883 (8883 com TLS)?',
    ];
  }
}

/// Protocolo de um equipamento na rede.
enum _Protocol {
  tcp('Modbus TCP', 'Modbus TCP', 'Modbus TCP'),
  rtu('RTU (gateway)', 'Modbus RTU · gateway', 'RTU'),
  ascii('ASCII (gateway)', 'Modbus ASCII · gateway', 'ASCII'),
  mqtt('MQTT', 'MQTT · broker', 'MQTT');

  const _Protocol(this.chip, this.subtitle, this.short);
  final String chip;
  final String subtitle;
  final String short;
}
