import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/hmi_screen.dart';
import '../../widgets/hmi/element_catalog.dart';

/// Paleta de elementos: cartões com ícone, nome e uma frase do que faz.
/// Devolve o tipo escolhido.
class PaletteSheet extends StatelessWidget {
  const PaletteSheet({super.key});

  static Future<ElementType?> show(BuildContext context) => showModalBottomSheet<ElementType>(
        context: context,
        isScrollControlled: true,
        builder: (_) => const PaletteSheet(),
      );

  @override
  Widget build(BuildContext context) {
    final items = ElementCatalog.all;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 16),
            child: Text('Escolha o elemento', style: Theme.of(context).textTheme.titleLarge),
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              final cols = box.maxWidth < 420 ? 2 : 3;
              return GridView.builder(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(Ind.page, 4, Ind.page, 32),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  mainAxisExtent: 132,
                ),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final info = items[i];
                  return Material(
                    color: Ind.surfaceHigh,
                    borderRadius: BorderRadius.circular(Ind.radius),
                    child: InkWell(
                      key: ValueKey('paleta-${info.type.name}'),
                      borderRadius: BorderRadius.circular(Ind.radius),
                      onTap: () => Navigator.pop(context, info.type),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(info.icon, color: Ind.accent, size: 26),
                              const Spacer(),
                              if (info.writes) const Tooltip(message: 'Grava no equipamento', child: Icon(Icons.edit_outlined, size: 16, color: Ind.textMuted)),
                            ]),
                            const SizedBox(height: 8),
                            Text(info.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                            const SizedBox(height: 3),
                            Expanded(
                              child: Text(info.description,
                                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Ind.textMuted, fontSize: 12.5, height: 1.3)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            }),
          ),
        ],
      ),
    );
  }
}
