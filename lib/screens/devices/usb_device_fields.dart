import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/modbus/modbus_exception.dart';
import '../../core/serial/serial_params.dart';
import '../../core/serial/usb_serial.dart';
import '../../core/theme/app_theme.dart';
import '../../models/serial_config.dart';
import '../../services/runtime/drivers/raw_driver.dart';
import '../../services/runtime/hmi_runtime.dart';
import '../../widgets/common/common.dart';
import 'raw_device_fields.dart';

/// Estado dos campos do cabo USB no cadastro de equipamento: o adaptador, o
/// que fala pelo cabo e como os bits andam no fio. Fica fora do formulário
/// para ele só ganhar ganchos, como no S7 e no Arduino.
class UsbDeviceFields {
  UsbDeviceFields(SerialConfig c)
      : port = c.port,
        protocol = c.protocol,
        params = c.params,
        discardEcho = c.discardEcho;

  UsbPortRef? port;
  SerialProtocol protocol;
  SerialParams params;
  bool discardEcho;

  /// Os aparelhos no USB na última procura (nulo = ainda não procurou).
  List<UsbPortInfo>? connected;

  bool get isRaw => protocol == SerialProtocol.raw;

  SerialConfig build() => SerialConfig(port: port, params: params, protocol: protocol, discardEcho: discardEcho);

  List<UsbPortInfo> get _serial => [for (final p in connected ?? const <UsbPortInfo>[]) if (p.supported) p];

  /// O adaptador escolhido, se está plugado agora.
  UsbPortInfo? get plugged => port?.find(_serial);

  /// Procura os adaptadores. Sem escolha e com um só plugado, ele vira o
  /// escolhido — plugou, está pronto.
  Future<void> refresh() async {
    connected = await UsbSerial.platform.list();
    final serial = _serial;
    if (port == null && serial.length == 1) port = UsbPortRef.of(serial.single);
    // Com a permissão dada, o chip informa o número de série: guarda, para
    // dois adaptadores iguais no mesmo hub não se confundirem.
    final p = plugged;
    if (p != null && p.serialNumber != null && port!.serialNumber == null) port = UsbPortRef.of(p);
  }

  /// ASCII quase sempre é 7E1; RTU e Arduino, 8N1. Quem já mexeu nos bits fica
  /// com o que escolheu.
  void setProtocol(SerialProtocol p) {
    final ascii = protocol == SerialProtocol.ascii;
    final untouched = params.dataBits == (ascii ? 7 : 8) && params.parity == (ascii ? SerialParity.even : SerialParity.none) && params.stopBits == 1;
    if (untouched) {
      final toAscii = p == SerialProtocol.ascii;
      params = params.copyWith(dataBits: toAscii ? 7 : 8, parity: toAscii ? SerialParity.even : SerialParity.none);
    }
    protocol = p;
  }

  /// Resumo de "Mais opções" fechado: "Modbus RTU · 9600 8N1 · ID 1".
  String summary(String unit, {String? profileName}) => [
        protocol.label,
        params.label,
        if (!isRaw) 'ID $unit',
        if (!isRaw && discardEcho) 'descarta eco',
        if (!isRaw && profileName != null) profileName,
      ].join(' · ');
}

/// "Adaptador USB" — à vista no cadastro, no lugar do IP. Mostra o escolhido
/// e se ele está plugado; acompanha o adaptador sendo ligado e tirado.
class UsbAdapterRow extends StatefulWidget {
  const UsbAdapterRow({super.key, required this.fields, required this.onChanged});

  final UsbDeviceFields fields;
  final VoidCallback onChanged;

  @override
  State<UsbAdapterRow> createState() => _UsbAdapterRowState();
}

class _UsbAdapterRowState extends State<UsbAdapterRow> {
  StreamSubscription<UsbSerialEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _refresh();
    _sub = UsbSerial.platform.events.where((e) => e is UsbDevicesChanged).listen((_) => _refresh());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final before = widget.fields.port;
    await widget.fields.refresh();
    if (!mounted) return;
    setState(() {});
    if (before != widget.fields.port) widget.onChanged();
  }

  Future<void> _pick() async {
    final chosen = await UsbAdapterSheet.show(context, widget.fields);
    if (!mounted) return;
    if (chosen != null) {
      widget.fields.port = UsbPortRef.of(chosen);
      widget.onChanged();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.fields;
    final plugged = f.plugged;
    final serial = f._serial;
    final (String text, Color color) = switch (f) {
      _ when !UsbSerial.platform.supported => (UsbHint.unsupported, Ind.textMuted),
      _ when f.connected == null => ('Procurando…', Ind.textMuted),
      _ when plugged != null => ('${plugged.title} · conectado', Ind.textFor(Ind.ok)),
      _ when f.port != null => ('${f.port!.title} · não está plugado agora', Ind.textFor(Ind.warn)),
      _ when serial.isEmpty => ('Nenhum adaptador no USB: ligue o adaptador no cabo OTG', Ind.textFor(Ind.warn)),
      _ => ('${serial.length} adaptadores plugados: toque para escolher', Ind.textFor(Ind.warn)),
    };
    return Material(
      color: Ind.surfaceHigh,
      borderRadius: BorderRadius.circular(Ind.radiusSmall),
      child: ListTile(
        key: const ValueKey('adaptador-usb'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ind.radiusSmall)),
        leading: Icon(Icons.usb_rounded, color: Ind.accent),
        title: const Text('Adaptador USB'),
        subtitle: Text(text, key: const ValueKey('adaptador-usb-estado'), style: TextStyle(color: color, fontSize: 13)),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: _pick,
      ),
    );
  }
}

/// A lista dos aparelhos no USB, cada um com o nome do chip. Os que não são
/// adaptador serial aparecem apagados: "há algo no cabo, mas não serve" já é
/// meio diagnóstico.
class UsbAdapterSheet extends StatefulWidget {
  const UsbAdapterSheet({super.key, required this.fields});

  final UsbDeviceFields fields;

  static Future<UsbPortInfo?> show(BuildContext context, UsbDeviceFields fields) => showModalBottomSheet<UsbPortInfo>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => UsbAdapterSheet(fields: fields),
      );

  @override
  State<UsbAdapterSheet> createState() => _UsbAdapterSheetState();
}

class _UsbAdapterSheetState extends State<UsbAdapterSheet> {
  StreamSubscription<UsbSerialEvent>? _sub;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _sub = UsbSerial.platform.events.where((e) => e is UsbDevicesChanged).listen((_) => _refresh());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    await widget.fields.refresh();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.fields;
    final all = [...(f.connected ?? const <UsbPortInfo>[])]..sort((a, b) => (a.supported ? 0 : 1) - (b.supported ? 0 : 1));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Adaptador USB', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('O adaptador RS-485 ou RS-232 (ou o Arduino) ligado no celular pelo cabo OTG.', style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.35)),
          const SizedBox(height: Ind.space),
          if (!UsbSerial.platform.supported)
            Text('O cabo USB funciona no celular ou tablet Android.', style: TextStyle(color: Ind.textDim, height: 1.35))
          else if (all.isEmpty && !_busy)
            Text('Nenhum aparelho no USB. Ligue o adaptador no cabo OTG e o cabo no celular — a lista se atualiza sozinha.',
                key: const ValueKey('usb-nenhum'), style: TextStyle(color: Ind.textDim, height: 1.35))
          else
            for (final p in all)
              ListTile(
                key: ValueKey('usb-porta-${p.key}'),
                contentPadding: EdgeInsets.zero,
                enabled: p.supported,
                leading: Icon(Icons.usb_rounded, color: p.supported ? Ind.accent : Ind.textMuted),
                title: Text(p.title),
                subtitle: Text(
                  p.supported ? '${p.ids}${p.hasPermission ? '' : ' · o Android vai pedir permissão'}' : '${p.ids} · não é um adaptador serial conhecido',
                  style: TextStyle(color: Ind.textMuted, fontSize: 13),
                ),
                trailing: f.port != null && f.port!.matches(p) ? Icon(Icons.check_rounded, color: Ind.accent) : null,
                onTap: p.supported ? () => Navigator.pop(context, p) : null,
              ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('usb-procurar'),
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Procurar de novo'),
            ),
          ),
        ]),
      ),
    );
  }
}

/// "Mais opções" do cabo USB: o que fala pelo cabo, velocidade, bits,
/// paridade, parada e, no Modbus, ID do escravo e eco.
class UsbMoreOptions extends StatelessWidget {
  const UsbMoreOptions({
    super.key,
    required this.fields,
    required this.unit,
    required this.timeout,
    required this.poll,
    required this.onChanged,
  });

  final UsbDeviceFields fields;
  final TextEditingController unit;
  final TextEditingController timeout;
  final TextEditingController poll;
  final VoidCallback onChanged;

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: Ind.space, bottom: 8),
        child: Text(text, style: TextStyle(color: Ind.textDim, fontWeight: FontWeight.w600)),
      );

  Widget _chips<T>(String key, List<T> values, T selected, String Function(T) label, void Function(T) pick) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final v in values)
          ChoiceChip(
            key: ValueKey('$key-$v'),
            label: Text(label(v)),
            selected: v == selected,
            onSelected: (_) {
              pick(v);
              onChanged();
            },
          ),
      ]);

  @override
  Widget build(BuildContext context) {
    final f = fields;
    final p = f.params;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 6),
      Text('Velocidade, bits, paridade e parada precisam ser iguais aos do equipamento (veja no manual ou na tela dele).',
          style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.35)),
      _label('O que fala pelo cabo'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final sp in SerialProtocol.values)
          ChoiceChip(
            key: ValueKey('usb-protocolo-${sp.name}'),
            label: Text(sp.label),
            selected: f.protocol == sp,
            onSelected: (_) {
              f.setProtocol(sp);
              onChanged();
            },
          ),
      ]),
      _label('Velocidade (baud)'),
      _chips<int>('usb-baud', SerialParams.bauds, p.baud, (b) => '$b', (b) => f.params = p.copyWith(baud: b)),
      _label('Bits de dados'),
      _chips<int>('usb-bits', const [7, 8], p.dataBits, (b) => '$b', (b) => f.params = p.copyWith(dataBits: b)),
      _label('Paridade'),
      _chips<SerialParity>('usb-paridade', SerialParity.values, p.parity, (x) => x.label, (x) => f.params = p.copyWith(parity: x)),
      _label('Bits de parada'),
      _chips<int>('usb-parada', const [1, 2], p.stopBits, (b) => '$b', (b) => f.params = p.copyWith(stopBits: b)),
      if (!f.isRaw) ...[
        const SizedBox(height: Ind.spaceLarge),
        StepperField(
          fieldKey: const ValueKey('usb-id'),
          label: 'ID do escravo',
          controller: unit,
          min: 1,
          max: 247,
          helper: 'O endereço do equipamento na linha RS-485. Vários na mesma linha: um cadastro para cada ID, mesmo adaptador.',
          onChanged: onChanged,
        ),
        SwitchListTile(
          key: const ValueKey('usb-eco'),
          contentPadding: EdgeInsets.zero,
          value: f.discardEcho,
          onChanged: (v) {
            f.discardEcho = v;
            onChanged();
          },
          title: const Text('Descartar eco'),
          subtitle: const Text('Adaptador RS-485 de 2 fios que devolve o que o app manda. O app percebe sozinho na primeira leitura; ligue se o primeiro comando depois de conectar falhar.'),
        ),
      ],
      const SizedBox(height: Ind.space),
      StepperField(label: 'Tempo de resposta (ms)', controller: timeout, min: 200, max: 10000),
      if (!f.isRaw) ...[
        const SizedBox(height: Ind.space),
        StepperField(label: 'Ler a cada (ms)', controller: poll, min: 100, max: 60000),
      ],
    ]);
  }
}

// ── Permissão do Android ───────────────────────────────────────────────────────

/// Antes da pergunta do Android, a explicação em palavras de operador. Devolve
/// se a permissão foi dada.
Future<bool> askUsbPermission(BuildContext context, UsbPortInfo port) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('usb-permissao'),
      icon: Icon(Icons.usb_rounded, color: Ind.accent),
      title: const Text('Permitir o adaptador USB'),
      content: Text(
        'O Android vai perguntar se o Ware IoT pode usar o ${port.title}. Toque em OK: sem essa permissão o app não fala com o equipamento pelo cabo.\n\n'
        'Se aparecer a opção de usar sempre com este adaptador, marque — assim o Android não pergunta de novo.',
        style: const TextStyle(height: 1.4),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Agora não')),
        FilledButton(key: const ValueKey('usb-permissao-continuar'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Continuar')),
      ],
    ),
  );
  if (go != true) return false;
  return UsbSerial.platform.requestPermission(port, insist: true);
}

// ── Testar conexão ─────────────────────────────────────────────────────────────

bool _usbProblem(ProbeResult r) => const {
      UsbHint.unsupported,
      UsbHint.noAdapter,
      UsbHint.notChosen,
      UsbHint.permission,
      UsbHint.openFailed,
      UsbHint.lost,
    }.contains(r.message);

/// Título do cartão do teste pelo cabo. Quando o adaptador abriu e o problema
/// é do outro lado, "Não conectou" seria mentira.
String usbProbeTitle(ProbeResult r, {required bool raw}) {
  if (raw && !_usbProblem(r)) return rawProbeTitle(r);
  if (r.ok) return 'Equipamento respondeu${r.elapsedMs != null ? ' em ${r.elapsedMs} ms' : ''}';
  if (_usbProblem(r)) return 'Não conectou: ${r.message}';
  return capitalized(r.message);
}

/// A frase antes da lista do que conferir.
String usbProbeHeader(ProbeResult r) => _usbProblem(r) ? 'Confira:' : 'O adaptador abriu. Confira, nesta ordem:';

/// O que conferir, na ordem em que os problemas costumam acontecer: o
/// adaptador foi reconhecido? a permissão? velocidade e paridade? A e B
/// invertidos? o ID?
List<String> usbProbeChecks(ProbeResult r, {required bool raw}) {
  switch (r.message) {
    case UsbHint.unsupported:
      return const ['O cabo USB funciona no celular ou tablet Android com USB-OTG.'];
    case UsbHint.noAdapter:
      return const [
        'O adaptador está encaixado no cabo OTG, e o cabo no celular? O LED do adaptador acende?',
        'Alguns celulares só aceitam OTG depois de ligar a opção "OTG" nas configurações.',
        'Toque em "Adaptador USB": se o aparelho aparece como "não é um adaptador serial conhecido", o chip dele não é suportado.',
      ];
    case UsbHint.notChosen:
      return const ['Há mais de um adaptador plugado: toque em "Adaptador USB" e escolha qual usar.'];
    case UsbHint.permission:
      return const [
        'Toque em Testar conexão de novo e, na pergunta do Android, toque em OK.',
        'Se aparecer a opção de usar sempre com este adaptador, marque: o Android não pergunta mais.',
      ];
    case UsbHint.openFailed:
    case UsbHint.lost:
      return const [
        'Tire o adaptador do cabo, ligue de novo e teste.',
        'Outro app está usando o adaptador? Feche-o.',
      ];
  }
  if (raw) {
    if (r.message.startsWith(RawProbeError.notUnderstood)) {
      return const [
        'A mensagem chegou: abra "Mensagem do equipamento" e ajuste até a prévia mostrar os campos.',
        'Mensagem embaralhada? A velocidade precisa ser a mesma do Serial.begin() do programa (Mais opções).',
      ];
    }
    return const [
      'A velocidade é a mesma do Serial.begin() do programa? (Mais opções)',
      'O programa manda pela Serial (Serial.print)? Se ele só responde quando perguntam, escolha "O app pergunta" em "Mensagem do equipamento".',
      'Ao abrir a porta o Arduino reinicia: o programa leva 1 a 2 s para começar a mandar.',
    ];
  }
  if (r.message == ModbusProtocolError.garbledMessage) {
    return const [
      'Velocidade, bits, paridade e parada iguais aos do equipamento? Bytes sem sentido são o sinal mais comum de velocidade ou paridade diferente (Mais opções).',
      'Adaptador RS-485 de 2 fios que devolve o que o app manda: ligue "Descartar eco" em Mais opções.',
      'Há outro mestre ou outro equipamento com o mesmo ID falando na linha?',
    ];
  }
  if (r.message == 'resposta inválida do equipamento') {
    return const [
      'Interferência no cabo? Use par trançado, ligue o terra (GND) e, em linha longa, o resistor de 120 Ω nas duas pontas.',
      'Velocidade e paridade iguais aos do equipamento? (Mais opções)',
    ];
  }
  return const [
    'Velocidade, bits, paridade e parada iguais aos do equipamento? Confira no manual dele e em "Mais opções".',
    'Os fios A e B (D+ e D−) não estão invertidos? Inverter não estraga nada: troque os dois e teste de novo.',
    'O ID do escravo é o configurado no equipamento?',
    'O equipamento está ligado e com o Modbus habilitado na porta serial? No RS-232, o TX de um vai no RX do outro e o GND precisa estar ligado.',
  ];
}
