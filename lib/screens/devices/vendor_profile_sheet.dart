import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/vendor_profiles.dart';
import '../../widgets/common/common.dart';

/// Escolha de marca e modelo do equipamento (perfil de fabricante).
///
/// Uma linha em "Mais opções" que abre esta folha, em vez de uma fileira de
/// chips: são oito modelos hoje e serão mais, e quem usa Modbus genérico nunca
/// precisa ver nenhum. Cada modelo diz, discreto, de onde veio a tabela — o de
/// fonte de terceiros avisa que não foi validado em bancada (MP-6).
class VendorProfileSheet extends StatelessWidget {
  const VendorProfileSheet({super.key, required this.current});

  /// Id do perfil marcado agora (nulo = Genérico).
  final String? current;

  /// Devolve `(id: ...)` com o escolhido — `id` nulo é Genérico — ou nulo se a
  /// pessoa fechou a folha sem escolher.
  static Future<({String? id})?> show(BuildContext context, String? current) => showModalBottomSheet<({String? id})>(
        context: context,
        isScrollControlled: true,
        builder: (_) => VendorProfileSheet(current: current),
      );

  @override
  Widget build(BuildContext context) {
    Widget option({required String? id, required String title, required String subtitle, Key? key}) {
      final selected = id == current;
      return ListTile(
        key: key,
        contentPadding: const EdgeInsets.symmetric(horizontal: Ind.page),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: TextStyle(color: Ind.textMuted, fontSize: 12.5)),
        trailing: selected ? Icon(Icons.check_rounded, color: Ind.accent) : null,
        onTap: () => Navigator.pop(context, (id: id)),
      );
    }

    final plcs = VendorProfiles.all.where((p) => p.kind == ProfileKind.plc);
    final drives = VendorProfiles.all.where((p) => p.kind == ProfileKind.drive);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 4),
            child: Text('Marca e modelo', style: Theme.of(context).textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 8),
            child: Text('Com a marca, as variáveis aceitam a memória como no manual ("D200", "X10").',
                style: TextStyle(color: Ind.textDim, height: 1.35)),
          ),
          option(id: null, title: 'Genérico', subtitle: 'Endereço Modbus direto', key: const ValueKey('perfil-generico')),
          const SectionHeader('CLP'),
          for (final p in plcs) option(id: p.id, title: p.name, subtitle: p.origin.caption, key: ValueKey('perfil-${p.id}')),
          const SectionHeader('Inversor'),
          for (final p in drives) option(id: p.id, title: p.name, subtitle: p.origin.caption, key: ValueKey('perfil-${p.id}')),
        ],
      ),
    );
  }
}
