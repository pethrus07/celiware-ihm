// "Imagem de fundo" nas Regras da tela (item 62 da lista do cliente,
// sinótico): escolher, trocar ou tirar a planta/foto/diagrama que fica atrás
// dos elementos, e como ela encaixa.

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/image_util.dart';
import '../../models/hmi_screen.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/write_actions.dart';

/// Imagem de fundo da tela, nas Regras da tela (logo abaixo da grade).
///
/// Sem imagem: uma frase e **Escolher imagem** (foto, desenho ou PDF — do
/// PDF sai uma página, como no elemento imagem). Com imagem: a miniatura,
/// quanto ela pesa no projeto, **Trocar** e **Remover**, e dois ajustes curtos:
/// **Encaixar** (largura da tela · tela inteira, cortando · caber sem cortar)
/// e **Escurecer a imagem** (nada · 30 % · 60 %; no tema claro, "Clarear").
///
/// A imagem é reduzida como as do elemento imagem ([shrinkImage], mesmo
/// código) a [ScreenBackground.maxSide] px no maior lado, e guardada dentro
/// do arquivo do projeto: exportar e duplicar levam junto.
class ScreenBackgroundSection extends StatefulWidget {
  const ScreenBackgroundSection({super.key, required this.screenId, required this.viewRows});
  final String screenId;

  /// Linhas da grade à vista no editor agora — a altura do encaixe "tela
  /// inteira" e "caber sem cortar" (0 = não se sabe; usa a da imagem).
  final int Function() viewRows;

  /// Teto de páginas lidas de um PDF (o mesmo do elemento imagem).
  static const maxPdfPages = 40;

  /// Prepara os bytes de uma imagem para virar fundo: reduzida como as
  /// imagens por etapa do elemento imagem e com a proporção guardada.
  static Future<ScreenBackground> prepare(Uint8List bytes, {ScreenBackground? keep}) async {
    final img = await shrinkImage(bytes, maxSide: ScreenBackground.maxSide);
    return ScreenBackground(
      data: img.data,
      width: img.width,
      height: img.height,
      fit: keep?.fit ?? BackgroundFit.width,
      rows: keep?.rows,
      dim: keep?.dim ?? 0,
    );
  }

  /// PDF começa com "%PDF" — mais seguro que a extensão do nome.
  static bool isPdf(Uint8List b) => b.length > 4 && b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46;

  @override
  State<ScreenBackgroundSection> createState() => _ScreenBackgroundSectionState();
}

class _ScreenBackgroundSectionState extends State<ScreenBackgroundSection> {
  bool _busy = false;

  HmiScreen? get _screen => AppScope.of(context).controller.project.screen(widget.screenId);

  void _save(ScreenBackground? b) {
    final s = _screen;
    if (s != null) AppScope.of(context).controller.saveScreen(s.withBackground(b));
  }

  Future<void> _choose() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'pdf']);
      if (files.isEmpty || !mounted) return;
      setState(() => _busy = true);
      var bytes = await files.first.readAsBytes();
      if (ScreenBackgroundSection.isPdf(bytes)) {
        final page = await _pdfPage(bytes);
        if (page == null) return;
        bytes = page;
      }
      final next = await ScreenBackgroundSection.prepare(bytes, keep: _screen?.background);
      if (mounted) _save(next);
    } catch (_) {
      if (mounted) WriteActions.toast(context, 'Não consegui abrir o arquivo.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Uma página do PDF, desenhada pelo próprio Android (pacote printing,
  /// como no elemento imagem). Com mais de uma, a pessoa escolhe qual.
  Future<Uint8List?> _pdfPage(Uint8List pdf) async {
    final pages = <Uint8List>[];
    await for (final page in Printing.raster(pdf, dpi: 150)) {
      pages.add(await page.toPng());
      if (pages.length >= ScreenBackgroundSection.maxPdfPages) break;
    }
    if (pages.isEmpty) throw const FormatException('PDF sem páginas');
    if (pages.length == 1 || !mounted) return pages.first;
    final i = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _PdfPagePicker(pages: pages),
    );
    return i == null ? null : pages[i];
  }

  Future<void> _remove() async {
    if (!await confirmDelete(context, title: 'Remover a imagem de fundo?', body: 'Os elementos continuam onde estão.')) return;
    if (mounted) _save(null);
  }

  @override
  Widget build(BuildContext context) {
    AppScope.watch(context);
    final s = _screen;
    if (s == null) return const SizedBox.shrink();
    final b = s.background;
    final muted = TextStyle(color: Ind.textMuted, fontSize: 13);
    final children = <Widget>[
      const SectionHeader('Imagem de fundo', padding: EdgeInsets.zero),
      const SizedBox(height: 8),
    ];
    if (b == null) {
      children.addAll([
        Text('Planta da fábrica, foto da máquina ou diagrama, atrás dos elementos.', style: muted),
        const SizedBox(height: 10),
        if (_busy)
          const _Busy()
        else
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              key: const ValueKey('fundo-escolher'),
              onPressed: _choose,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Escolher imagem'),
            ),
          ),
      ]);
    } else {
      // Base64 → bytes (×0,75). Abaixo de 1 MB em KB: "0,0 MB" parecia vazio.
      final bytes = b.data.length * 0.75;
      final weight = bytes < 1048576 ? '${(bytes / 1024).ceil()} KB' : '${(bytes / 1048576).toStringAsFixed(1).replaceAll('.', ',')} MB';
      children.addAll([
        Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 56,
              height: 56,
              color: Ind.bg,
              child: Image.memory(decodeBase64Cached(b.data), fit: BoxFit.cover, gaplessPlayback: true,
                  errorBuilder: (_, _, _) => Icon(Icons.broken_image_outlined, color: Ind.textMuted)),
            ),
          ),
          const SizedBox(width: 12),
          // Peso em cima, ações embaixo: lado a lado, no celular de 320 dp
          // a linha passava da largura.
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$weight no projeto', key: const ValueKey('fundo-peso'), style: muted),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4)),
                )
              else
                Wrap(spacing: 4, children: [
                  TextButton(key: const ValueKey('fundo-trocar'), onPressed: _choose, child: const Text('Trocar')),
                  TextButton(
                    key: const ValueKey('fundo-remover'),
                    onPressed: _remove,
                    style: TextButton.styleFrom(foregroundColor: Ind.alarm),
                    child: const Text('Remover'),
                  ),
                ]),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Text('Encaixar', style: TextStyle(color: Ind.textDim, fontSize: 13)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (f, t) in const [
            (BackgroundFit.width, 'Largura da tela'),
            (BackgroundFit.cover, 'Tela inteira (cortar)'),
            (BackgroundFit.contain, 'Caber sem cortar'),
          ])
            ChoiceChip(
              key: ValueKey('encaixe-${f.name}'),
              label: Text(t),
              selected: b.fit == f,
              onSelected: (_) {
                if (f == BackgroundFit.width) {
                  _save(b.copyWith(fit: f, clearRows: true));
                } else {
                  // A tela que se vê agora vira a área da imagem, em linhas
                  // da grade: a mesma no editor, na operação e no tablet.
                  final view = widget.viewRows();
                  _save(b.copyWith(fit: f, rows: view > 0 ? view : b.areaRows(s.columns)));
                }
              },
            ),
        ]),
        const SizedBox(height: 12),
        // Camada da cor de fundo do tema: escurece no escuro, clareia no
        // claro — o nome diz o que a pessoa vai ver.
        Text(Ind.isDark ? 'Escurecer a imagem' : 'Clarear a imagem', style: TextStyle(color: Ind.textDim, fontSize: 13)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final d in ScreenBackground.dimChoices)
            ChoiceChip(
              key: ValueKey('escurecer-$d'),
              label: Text(d == 0 ? 'Nada' : '$d%'),
              selected: b.dim == d,
              onSelected: (_) => _save(b.copyWith(dim: d)),
            ),
        ]),
        const SizedBox(height: 6),
        Text('Lâmpadas, valores e estados podem ficar sem cartão, direto no desenho: Configurar → Mais opções.', style: muted),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children);
  }
}

class _Busy extends StatelessWidget {
  const _Busy();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4)),
          const SizedBox(width: 12),
          Text('Preparando a imagem…', style: TextStyle(color: Ind.textDim)),
        ]),
      );
}

/// Qual página do PDF vira o fundo: as páginas em miniatura, toque escolhe.
class _PdfPagePicker extends StatelessWidget {
  const _PdfPagePicker({required this.pages});
  final List<Uint8List> pages;

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.96,
        builder: (context, scroll) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: Ind.page),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Qual página?', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Expanded(
              child: GridView.builder(
                controller: scroll,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.8),
                itemCount: pages.length,
                itemBuilder: (context, i) => InkWell(
                  borderRadius: BorderRadius.circular(Ind.radiusSmall),
                  onTap: () => Navigator.pop(context, i),
                  child: Column(children: [
                    Expanded(child: Image.memory(pages[i], fit: BoxFit.contain)),
                    const SizedBox(height: 4),
                    Text('Página ${i + 1}', style: TextStyle(color: Ind.textDim)),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      );
}
