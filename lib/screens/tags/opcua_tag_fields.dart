import 'package:flutter/material.dart';

import '../../core/comm/comm_error.dart';
import '../../core/opcua/opcua_types.dart';
import '../../core/theme/app_theme.dart';
import '../../models/device.dart';
import '../../models/opcua_config.dart';
import '../../models/tag.dart';
import '../../services/runtime/drivers/opcua_driver.dart';
import '../../widgets/common/common.dart';

/// Estado do NodeId no cadastro de variável — o "endereço" quando o
/// equipamento é um servidor OPC UA. Fica fora do formulário para ele só
/// trocar o bloco de endereço Modbus por este, como faz com o S7.
class OpcUaTagFields {
  OpcUaTagFields(OpcUaTagAddress? a) : nodeId = TextEditingController(text: a?.nodeId ?? '');

  final TextEditingController nodeId;

  String get _text => nodeId.text.trim();

  /// O NodeId lido; nulo enquanto o texto não for um NodeId.
  NodeId? get parsed => NodeId.tryParse(_text);

  /// O que está errado no NodeId — curto, em português. Nulo se está certo.
  String? error() {
    try {
      NodeId.parse(_text);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  /// O NodeId como vai para a variável, já arrumado (" NS=2; s=Temp" →
  /// "ns=2;s=Temp").
  OpcUaTagAddress build() => OpcUaTagAddress(OpcUaTagAddress.normalize(_text));

  void dispose() => nodeId.dispose();

  /// A prova da leitura do NodeId, em palavras: "namespace 2, nome
  /// Maquina.Temperatura".
  static String proof(NodeId n) {
    final what = switch (n.kind) {
      NodeIdKind.numeric => 'número ${n.identifier}',
      NodeIdKind.string => 'nome ${n.identifier}',
      NodeIdKind.guid => 'GUID',
      NodeIdKind.opaque => 'bytes',
    };
    return n.namespace == 0 ? 'namespace 0 (do próprio servidor), $what' : 'namespace ${n.namespace}, $what';
  }
}

/// O NodeId no lugar de "Onde fica" e "Endereço" do Modbus, com a prova
/// embaixo, e o "Navegar e escolher" — o servidor mostra a árvore e a pessoa
/// toca na variável, sem digitar NodeId de cabeça.
class OpcUaAddressBlock extends StatelessWidget {
  const OpcUaAddressBlock({super.key, required this.fields, required this.device, required this.onChanged, required this.onPick});

  final OpcUaTagFields fields;
  final Device? device;
  final VoidCallback onChanged;
  final ValueChanged<OpcUaPick> onPick;

  Future<void> _browse(BuildContext context) async {
    final d = device;
    if (d == null) return;
    final pick = await showOpcUaBrowseSheet(context, d);
    if (pick != null) onPick(pick);
  }

  @override
  Widget build(BuildContext context) {
    final typed = fields.nodeId.text.trim().isNotEmpty;
    final error = typed ? fields.error() : null;
    final n = fields.parsed;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextFormField(
        key: const ValueKey('campo-nodeid'),
        controller: fields.nodeId,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.visiblePassword,
        style: Ind.number(18),
        decoration: InputDecoration(
          // Rótulo do chão de fábrica, termo do manual entre parênteses.
          labelText: 'Endereço (NodeId)',
          hintText: 'Ex.: ns=2;s=Maquina.Temperatura',
          helperText: error == null && n != null ? OpcUaTagFields.proof(n) : null,
          helperMaxLines: 2,
          errorText: error,
          errorMaxLines: 3,
        ),
        onChanged: (_) => onChanged(),
        validator: (_) => fields.error(),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('navegar-opcua'),
          onPressed: device == null ? null : () => _browse(context),
          icon: const Icon(Icons.account_tree_outlined),
          label: const Text('Navegar e escolher'),
        ),
      ),
    ]);
  }
}

// ── Navegar e escolher (OP-2) ──────────────────────────────────────────────────

/// Variável escolhida na navegação: o NodeId, o nome, o tipo que combina com
/// o valor e se o servidor deixa gravar.
class OpcUaPick {
  const OpcUaPick({required this.nodeId, required this.name, required this.type, required this.writable, this.count = 1, this.decimals = 0});
  final String nodeId;
  final String name;
  final TagDataType type;
  final bool writable;

  /// Quantos valores o nó tem (lista do servidor); 1 = valor único.
  final int count;

  /// Casas decimais do valor visto na navegação.
  final int decimals;

  /// Nome sugerido para variável sem nome: o do nó, com espaço no lugar de _.
  String get suggestedName => capitalized(name.replaceAll('_', ' '));
}


Future<OpcUaPick?> showOpcUaBrowseSheet(BuildContext context, Device device) => showModalBottomSheet<OpcUaPick>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _BrowseSheet(device: device),
    );

/// A árvore do servidor, um nível por vez: pasta entra, variável escolhe.
class _BrowseSheet extends StatefulWidget {
  const _BrowseSheet({required this.device});
  final Device device;

  @override
  State<_BrowseSheet> createState() => _BrowseSheetState();
}

class _BrowseSheetState extends State<_BrowseSheet> {
  late final OpcUaBrowser _browser = OpcUaBrowser(widget.device);

  /// Caminho até aqui: (NodeId, nome). Vazio = pasta Objects.
  final List<(String, String)> _path = [];
  List<OpcUaBrowseItem>? _items;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _browser.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final gen = ++_generation;
    setState(() {
      _items = null;
      _error = null;
    });
    try {
      final items = await _browser.children(_path.isEmpty ? null : _path.last.$1);
      if (mounted && gen == _generation) setState(() => _items = items);
    } on CommError catch (e) {
      if (mounted && gen == _generation) setState(() => _error = e.userMessage);
    } on FormatException catch (e) {
      if (mounted && gen == _generation) setState(() => _error = e.message);
    }
  }

  void _enter(OpcUaBrowseItem it) {
    _path.add((it.nodeId, it.name));
    _load();
  }

  void _up() {
    if (_path.isEmpty) return;
    _path.removeLast();
    _load();
  }

  void _pick(OpcUaBrowseItem it) =>
      Navigator.pop(context, OpcUaPick(nodeId: it.nodeId, name: it.name, type: it.suggestedType, writable: it.writable, count: it.count, decimals: it.decimals));

  static String _valueText(OpcUaBrowseItem it) {
    if (it.problem != null) return it.problem!;
    final v = it.value;
    final type = it.type?.label ?? 'sem valor';
    final text = switch (v) {
      null => '—',
      bool b => b ? 'ligado' : 'desligado',
      List l => 'lista de ${l.length}',
      // Até 3 casas, sem zeros sobrando: 72,5 e não 72,500.
      double d => d.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '').replaceAll('.', ','),
      String s => '"${s.length > 40 ? '${s.substring(0, 40)}…' : s}"',
      LocalizedText t => '"${t.text ?? ''}"',
      _ => '$v',
    };
    return '$text · $type';
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final where = ['Objects', for (final p in _path) p.$2].join(' › ');
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, Ind.page, 4),
          child: Row(children: [
            IconButton(
              key: const ValueKey('navegar-voltar'),
              tooltip: 'Voltar um nível',
              onPressed: _path.isEmpty ? null : _up,
              icon: const Icon(Icons.arrow_upward_rounded),
            ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Navegar no servidor', style: Theme.of(context).textTheme.titleLarge),
                Text(where, key: const ValueKey('navegar-onde'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Ind.textDim)),
              ]),
            ),
          ]),
        ),
        if (items == null && _error == null) const LinearProgressIndicator(),
        Expanded(
          child: _error != null
              ? Padding(
                  padding: const EdgeInsets.all(Ind.page),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Não conectou: ${_error!}', key: const ValueKey('navegar-erro'), style: TextStyle(color: Ind.textFor(Ind.alarm), height: 1.4)),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: const Text('Tentar de novo')),
                  ]),
                )
              : items == null
                  ? const SizedBox.shrink()
                  : items.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(Ind.page),
                          child: Text('Nada aqui. As variáveis da máquina costumam ficar numa pasta com o nome do CLP ou do projeto.',
                              style: TextStyle(color: Ind.textDim, height: 1.4)),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(Ind.page, 4, Ind.page, 16),
                          itemCount: items.length,
                          itemBuilder: (_, i) {
                            final it = items[i];
                            return ListTile(
                              key: ValueKey('no-${it.nodeId}'),
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(it.isVariable ? Icons.sensors_rounded : Icons.folder_outlined, color: it.isVariable ? Ind.accent : Ind.textDim),
                              title: Text(it.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: it.isVariable
                                  ? Text(_valueText(it), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: it.problem != null ? Ind.textFor(Ind.alarm) : Ind.textDim))
                                  : null,
                              trailing: it.isVariable ? null : const Icon(Icons.chevron_right_rounded),
                              onTap: () => it.isVariable ? _pick(it) : _enter(it),
                            );
                          },
                        ),
        ),
      ]),
    );
  }
}
