import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../core/modbus/modbus_client.dart';
import '../../core/theme/app_theme.dart';
import '../../models/device.dart';
import '../../services/runtime/device_session.dart';

/// Tela vazia que ensina o próximo passo — nunca só "nada aqui".
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(color: Ind.surfaceHigh, borderRadius: BorderRadius.circular(20)),
              child: Icon(icon, size: 34, color: Ind.accent),
            ),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center, style: TextStyle(color: Ind.textDim, height: 1.45)),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// Título de seção em placa (caixa alta condensada).
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.trailing, this.padding = const EdgeInsets.fromLTRB(Ind.page, 28, Ind.page, 12)});
  final String text;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(children: [
          Expanded(child: Text(text.toUpperCase(), style: Ind.tag(size: 12.5, color: Ind.textDim))),
          ?trailing,
        ]),
      );
}

/// Selo de comunicação de um equipamento, ao vivo.
///
/// Verde = respondendo; âmbar = conectando; vermelho = sem comunicação (com o
/// motivo); cinza = nada dele em uso agora (não está sendo lido).
class LinkChip extends StatelessWidget {
  const LinkChip({super.key, required this.device, this.compact = false});
  final Device device;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final runtime = AppScope.of(context).runtime;
    return ValueListenableBuilder<int>(
      valueListenable: runtime.sessionsRevision,
      builder: (context, _, _) => _forHealth(runtime.health(device.id)),
    );
  }

  Widget _forHealth(ValueListenable<DeviceHealth>? health) {
    if (health == null) return _chip(Ind.textMuted, compact ? device.name : 'Ocioso', Icons.pause_circle_outline_rounded);
    return ValueListenableBuilder<DeviceHealth>(
      valueListenable: health,
      builder: (context, h, _) {
        final (color, text, icon) = switch (h) {
          _ when h.online => (Ind.ok, compact ? device.name : 'Online${h.lastScanMs != null ? ' · ${h.lastScanMs} ms' : ''}', Icons.check_circle_rounded),
          // A mensagem vem em minúscula porque também entra no meio de frases
          // ("Não gravou: sem conexão…"); sozinha no selo, começa maiúscula,
          // como o "Online" ao lado.
          _ when h.message.isNotEmpty => (Ind.alarm, compact ? device.name : capitalized(h.message), Icons.error_rounded),
          _ when h.link == ModbusLinkState.connecting => (Ind.warn, compact ? device.name : 'Conectando…', Icons.sync_rounded),
          _ => (Ind.textMuted, compact ? device.name : 'Ocioso', Icons.pause_circle_outline_rounded),
        };
        return _chip(color, text, icon);
      },
    );
  }

  Widget _chip(Color color, String text, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(child: Text(text, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600))),
        ]),
      );
}

/// "sem conexão" → "Sem conexão".
String capitalized(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Depois de abrir um "Mais opções", rola a tela até ele: aberto no pé da
/// tela, o conteúdo novo ficava escondido atrás do botão Salvar e parecia que
/// nada tinha acontecido. Espera a animação de abrir antes de medir.
void revealAfterExpand(GlobalKey tileKey, bool opened) {
  if (!opened) return;
  Future.delayed(const Duration(milliseconds: 260), () {
    final ctx = tileKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    Scrollable.ensureVisible(ctx, alignment: 0.05, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
  });
}

/// Uma opção grande de escolha — ícone, título e explicação curta.
class ChoiceOption<T> {
  const ChoiceOption({required this.value, required this.title, this.subtitle, this.icon});
  final T value;
  final String title;
  final String? subtitle;
  final IconData? icon;
}

/// Cartões de escolha em grade. Mais fácil que uma lista suspensa para quem
/// não é técnico: todas as opções à vista, cada uma com uma frase.
class ChoiceCards<T> extends StatelessWidget {
  const ChoiceCards({super.key, required this.options, required this.selected, required this.onChanged, this.columns = 2});
  final List<ChoiceOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;
  final int columns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth < 340 ? 1 : columns;
      final w = (box.maxWidth - (cols - 1) * 12) / cols;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final o in options)
            SizedBox(
              width: w,
              child: _ChoiceCard(option: o, selected: o.value == selected, onTap: () => onChanged(o.value)),
            ),
        ],
      );
    });
  }
}

class _ChoiceCard<T> extends StatelessWidget {
  const _ChoiceCard({required this.option, required this.selected, required this.onTap});
  final ChoiceOption<T> option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Ind.accent.withValues(alpha: 0.14) : Ind.surfaceHigh,
      borderRadius: BorderRadius.circular(Ind.radiusSmall),
      child: InkWell(
        key: ValueKey('opcao-${option.value}'),
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Ind.radiusSmall),
            border: selected ? Border.all(color: Ind.accent, width: 2) : null,
          ),
          child: Row(
            children: [
              if (option.icon != null) ...[
                Icon(option.icon, color: selected ? Ind.accent : Ind.textDim, size: 22),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(option.title, style: TextStyle(fontWeight: FontWeight.w700, color: selected ? Ind.text : Ind.text)),
                    if (option.subtitle != null)
                      Padding(padding: const EdgeInsets.only(top: 2), child: Text(option.subtitle!, style: TextStyle(color: Ind.textMuted, fontSize: 12.5, height: 1.3))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Campo numérico inteiro com botões − / + (endereço, porta, ID) — errar um
/// dígito no teclado pequeno é o erro de cadastro mais comum.
class StepperField extends StatelessWidget {
  const StepperField({
    super.key,
    required this.label,
    required this.controller,
    this.min = 0,
    this.max = 65535,
    this.helper,
    this.onChanged,
    this.fieldKey,
  });

  final String label;
  final TextEditingController controller;
  final int min;
  final int max;
  final String? helper;
  final VoidCallback? onChanged;
  final Key? fieldKey;

  void _bump(int d) {
    final v = (int.tryParse(controller.text) ?? min) + d;
    controller.text = v.clamp(min, max).toString();
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextFormField(
            key: fieldKey,
            controller: controller,
            keyboardType: TextInputType.number,
            // O teclado numérico do Android tem "." e ",": num inteiro sem
            // sinal, só algarismos entram ("5020." virava erro no Salvar).
            inputFormatters: [if (min >= 0) FilteringTextInputFormatter.digitsOnly],
            style: Ind.number(20),
            decoration: InputDecoration(labelText: label, helperText: helper),
            onChanged: (_) => onChanged?.call(),
            validator: (t) {
              final v = int.tryParse(t ?? '');
              if (v == null) return 'Número inteiro';
              if (v < min || v > max) return 'De $min a $max';
              return null;
            },
          ),
        ),
        const SizedBox(width: 6),
        StepButton(icon: Icons.remove_rounded, onTap: () => _bump(-1)),
        const SizedBox(width: 6),
        StepButton(icon: Icons.add_rounded, onTap: () => _bump(1)),
      ],
    );
  }
}

/// Botão − / + ao lado de um campo numérico (mesma altura do campo).
class StepButton extends StatelessWidget {
  const StepButton({super.key, required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 56,
        height: 58,
        // Fundo em vez de contorno: combina com o campo sem borda ao lado.
        child: FilledButton.tonal(
          onPressed: onTap,
          style: FilledButton.styleFrom(padding: EdgeInsets.zero, backgroundColor: Ind.surfaceHigh, foregroundColor: Ind.text),
          child: Icon(icon),
        ),
      );
}

/// Sugestão que se aplica com um toque ("Parece a notação de manual…",
/// "Tente palavras trocadas…"). Azul de informação: não é erro, é atalho. Só
/// aparece quando o problema existe.
class SuggestionTile extends StatelessWidget {
  const SuggestionTile({super.key, required this.text, required this.onTap, this.icon = Icons.auto_fix_high_rounded});
  final String text;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Material(
        color: Ind.info.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        child: InkWell(
          borderRadius: BorderRadius.circular(Ind.radiusSmall),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(icon, color: Ind.info),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
            ]),
          ),
        ),
      );
}

/// Confirmação de ação destrutiva, com o que vai ser perdido escrito.
Future<bool> confirmDelete(BuildContext context, {required String title, required String body}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.delete_outline_rounded, color: Ind.alarm),
      title: Text(title),
      content: Text(body, style: const TextStyle(height: 1.4)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Ind.alarm, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Apagar'),
        ),
      ],
    ),
  );
  return r ?? false;
}
