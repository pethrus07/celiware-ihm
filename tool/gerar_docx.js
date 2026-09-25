/**
 * Gera docs/Documentacao_Tecnica_Celiware_IHM.docx a partir de docs/ARQUITETURA.md.
 *
 * O Markdown é a FONTE; o Word é derivado. Assim os dois nunca divergem:
 * mudou a documentação, edita o .md e roda `node tool/gerar_docx.js`.
 *
 * Subconjunto de Markdown entendido (o que ARQUITETURA.md usa):
 *   # Título (capa)   ## Seção   ### Subseção   parágrafo   **negrito**   `código`
 *   - lista   1. lista numerada   > nota   ```bloco de código```
 *   | tabela |   ![legenda](imagens/x.png)  (imagens seguidas saem lado a lado)
 *
 * Uso: cd tool && npm install && node gerar_docx.js
 */
const fs = require('fs');
const path = require('path');
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, Table, TableRow, TableCell,
  WidthType, ShadingType, BorderStyle, AlignmentType, ImageRun, Footer, PageNumber,
  TableOfContents, LevelFormat, PageBreak, TableLayoutType, VerticalAlign,
} = require('docx');

const ROOT = path.resolve(__dirname, '..');
const SRC = path.join(ROOT, 'docs', 'ARQUITETURA.md');
const OUT = path.join(ROOT, 'docs', 'Documentacao_Tecnica_Celiware_IHM.docx');
const VERSION = '1.0';

// Identidade (lib/core/theme/app_theme.dart) — versão para papel.
const C = {
  ink: '1A1D22', grafite: '2B3038', dim: '5F6B78', line: 'C9CED4', zebra: 'F3F4F6',
  amber: 'E09A00', amberSoft: 'FFF4DC', code: 'F1F2F4',
};
// Fontes presentes em qualquer Office (a Plex do app não vem instalada no
// Windows de quem abre o documento — o Word trocaria por outra).
const FONT = 'Calibri';
const MONO = 'Consolas';
const PAGE_W = 11906, MARGIN = 1134; // A4, margens de 2 cm
const CONTENT_W = PAGE_W - 2 * MARGIN;

// ── Texto com **negrito** e `código` ─────────────────────────────────────────
function runs(text, base = {}) {
  const out = [];
  const re = /(\*\*[^*]+\*\*|`[^`]+`)/g;
  let last = 0, m;
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(new TextRun({ text: text.slice(last, m.index), ...base }));
    const t = m[0];
    if (t.startsWith('**')) out.push(new TextRun({ text: t.slice(2, -2), bold: true, ...base }));
    else out.push(new TextRun({ text: t.slice(1, -1), font: MONO, size: (base.size || 21) - 2, color: C.grafite, shading: { type: ShadingType.CLEAR, fill: C.code, color: 'auto' } }));
    last = m.index + t.length;
  }
  if (last < text.length) out.push(new TextRun({ text: text.slice(last), ...base }));
  return out;
}

const border = { style: BorderStyle.SINGLE, size: 4, color: C.line };
const cellBorders = { top: border, bottom: border, left: border, right: border };

function table(rows) {
  const header = rows[0];
  const body = rows.slice(1);
  const n = header.length;
  // Largura proporcional ao texto mais longo de cada coluna (com piso).
  const weights = header.map((_, i) => Math.max(8, ...rows.map((r) => (r[i] || '').length)));
  const total = weights.reduce((a, b) => a + b, 0);
  let widths = weights.map((w) => Math.round((w / total) * CONTENT_W));
  const min = Math.round(CONTENT_W * 0.2);
  widths = widths.map((w) => Math.max(w, n > 1 ? min : w));
  const scale = CONTENT_W / widths.reduce((a, b) => a + b, 0);
  widths = widths.map((w) => Math.floor(w * scale));
  widths[n - 1] += CONTENT_W - widths.reduce((a, b) => a + b, 0);

  const cell = (text, i, isHead, zebra) => new TableCell({
    width: { size: widths[i], type: WidthType.DXA },
    borders: cellBorders,
    verticalAlign: VerticalAlign.CENTER,
    shading: { type: ShadingType.CLEAR, color: 'auto', fill: isHead ? C.grafite : (zebra ? C.zebra : 'FFFFFF') },
    margins: { top: 60, bottom: 60, left: 100, right: 100 },
    children: [new Paragraph({
      spacing: { before: 0, after: 0 },
      children: runs(text, isHead ? { bold: true, color: 'FFFFFF', size: 19 } : { size: 19, color: C.ink }),
    })],
  });

  return new Table({
    width: { size: CONTENT_W, type: WidthType.DXA },
    columnWidths: widths,
    layout: TableLayoutType.FIXED,
    rows: [
      new TableRow({ tableHeader: true, children: header.map((h, i) => cell(h, i, true, false)) }),
      ...body.map((r, ri) => new TableRow({ children: header.map((_, i) => cell(r[i] || '', i, false, ri % 2 === 1)) })),
    ],
  });
}

function codeBlock(lines) {
  return lines.map((l, i) => new Paragraph({
    spacing: { before: i === 0 ? 120 : 0, after: i === lines.length - 1 ? 160 : 0, line: 260 },
    shading: { type: ShadingType.CLEAR, color: 'auto', fill: C.code },
    indent: { left: 120, right: 120 },
    children: [new TextRun({ text: l.length ? l : ' ', font: MONO, size: 16, color: C.grafite })],
  }));
}

function images(list) {
  // Até 3 capturas por linha, lado a lado, com legenda embaixo.
  const perRow = Math.min(3, list.length);
  const colW = Math.floor(CONTENT_W / perRow);
  const out = [];
  for (let i = 0; i < list.length; i += perRow) {
    const chunk = list.slice(i, i + perRow);
    const cells = chunk.map(({ alt, file }) => {
      const data = fs.readFileSync(path.join(ROOT, 'docs', file));
      const w = data.readUInt32BE(16), h = data.readUInt32BE(20); // PNG IHDR
      const pxW = 190, pxH = Math.round((h / w) * pxW);
      return new TableCell({
        width: { size: colW, type: WidthType.DXA },
        borders: { top: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' }, bottom: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' }, left: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' }, right: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' } },
        children: [
          new Paragraph({ alignment: AlignmentType.CENTER, spacing: { before: 60, after: 40 }, children: [new ImageRun({ type: 'png', data, transformation: { width: pxW, height: pxH } })] }),
          new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 120 }, children: [new TextRun({ text: alt, italics: true, size: 16, color: C.dim })] }),
        ],
      });
    });
    while (cells.length < perRow) cells.push(new TableCell({ width: { size: colW, type: WidthType.DXA }, children: [new Paragraph('')] }));
    out.push(new Table({ width: { size: colW * perRow, type: WidthType.DXA }, columnWidths: Array(perRow).fill(colW), layout: TableLayoutType.FIXED, alignment: AlignmentType.CENTER, rows: [new TableRow({ cantSplit: true, children: cells })] }));
  }
  return out;
}

// ── Markdown → blocos ────────────────────────────────────────────────────────
function parse(md) {
  const lines = md.replace(/\r\n/g, '\n').split('\n');
  const blocks = [];
  let title = '', subtitle = '';
  let i = 0;
  while (i < lines.length) {
    const l = lines[i];
    if (l.startsWith('# ')) { title = l.slice(2).trim(); i++; continue; }
    if (!title) { i++; continue; }
    if (!subtitle && l.trim() && !l.startsWith('#')) { subtitle = l.trim(); i++; continue; }
    if (l.startsWith('```')) {
      const code = []; i++;
      while (i < lines.length && !lines[i].startsWith('```')) code.push(lines[i++]);
      i++; blocks.push(...codeBlock(code)); continue;
    }
    if (l.startsWith('## ')) {
      blocks.push(new Paragraph({ heading: HeadingLevel.HEADING_1, keepNext: true, children: [new TextRun(l.slice(3).trim().replace(/`/g, ''))] }));
      i++; continue;
    }
    if (l.startsWith('### ')) { blocks.push(new Paragraph({ heading: HeadingLevel.HEADING_2, keepNext: true, children: [new TextRun(l.slice(4).trim().replace(/`/g, ''))] })); i++; continue; }
    if (l.startsWith('|')) {
      const rows = [];
      while (i < lines.length && lines[i].startsWith('|')) {
        const cells = lines[i].trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
        if (!cells.every((c) => /^:?-+:?$/.test(c))) rows.push(cells);
        i++;
      }
      blocks.push(table(rows), new Paragraph({ spacing: { after: 80 }, children: [] }));
      continue;
    }
    if (l.startsWith('![')) {
      const imgs = [];
      while (i < lines.length && lines[i].startsWith('![')) {
        const m = /^!\[([^\]]*)\]\(([^)]+)\)/.exec(lines[i]);
        if (m) imgs.push({ alt: m[1], file: m[2] });
        i++;
      }
      blocks.push(...images(imgs));
      continue;
    }
    if (/^- /.test(l)) {
      blocks.push(new Paragraph({ numbering: { reference: 'bullets', level: 0 }, spacing: { after: 60 }, children: runs(l.slice(2)) }));
      i++; continue;
    }
    if (/^\d+\. /.test(l)) {
      blocks.push(new Paragraph({ numbering: { reference: 'steps', level: 0 }, spacing: { after: 60 }, children: runs(l.replace(/^\d+\. /, '')) }));
      i++; continue;
    }
    if (l.startsWith('> ')) {
      blocks.push(new Paragraph({
        spacing: { before: 120, after: 120 },
        shading: { type: ShadingType.CLEAR, color: 'auto', fill: C.amberSoft },
        border: { left: { style: BorderStyle.SINGLE, size: 18, color: C.amber, space: 8 } },
        indent: { left: 200 },
        children: runs(l.slice(2)),
      }));
      i++; continue;
    }
    if (l.trim()) {
      // Parágrafo: junta linhas seguidas até linha em branco.
      const para = [l.trim()]; i++;
      while (i < lines.length && lines[i].trim() && !/^(#|\||```|- |\d+\. |> |!\[)/.test(lines[i])) para.push(lines[i++].trim());
      blocks.push(new Paragraph({ spacing: { after: 140, line: 300 }, children: runs(para.join(' ')) }));
      continue;
    }
    i++;
  }
  return { title, subtitle, blocks };
}

// ── Documento ────────────────────────────────────────────────────────────────
const { title, subtitle, blocks } = parse(fs.readFileSync(SRC, 'utf8'));
const productName = title.split('—')[0].trim().toUpperCase();

const cover = [
  new Paragraph({ spacing: { before: 3000 }, children: [] }),
  new Paragraph({ children: [new TextRun({ text: productName, font: 'Calibri', bold: true, size: 72, color: C.ink })] }),
  new Paragraph({ spacing: { after: 240 }, border: { bottom: { style: BorderStyle.SINGLE, size: 24, color: C.amber, space: 10 } }, children: [new TextRun({ text: 'IHM portátil no celular · Modbus TCP', size: 30, color: C.dim })] }),
  new Paragraph({ spacing: { before: 480 }, children: [new TextRun({ text: 'Documentação Técnica', bold: true, size: 40, color: C.grafite })] }),
  new Paragraph({ children: [new TextRun({ text: 'Arquitetura • Comunicação • Telas • Manutenção', size: 24, color: C.dim })] }),
  new Paragraph({ spacing: { before: 2400 }, children: [new TextRun({ text: subtitle, size: 22, color: C.dim })] }),
  new Paragraph({ children: [new TextRun({ text: 'Celiware', bold: true, size: 22, color: C.amber })] }),
  new Paragraph({ children: [new PageBreak()] }),
  new Paragraph({ children: [new TextRun({ text: 'Sumário', font: 'Calibri', bold: true, size: 36, color: C.ink })], spacing: { after: 200 } }),
  new TableOfContents('Sumário', { hyperlink: true, headingStyleRange: '1-2' }),
  new Paragraph({ children: [new PageBreak()] }),
];

const doc = new Document({
  creator: 'Celiware',
  title: `${title} — Documentação Técnica`,
  description: 'Gerado de docs/ARQUITETURA.md por tool/gerar_docx.js',
  features: { updateFields: true },
  styles: {
    default: { document: { run: { font: FONT, size: 21, color: C.ink } } },
    paragraphStyles: [
      { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { font: 'Calibri', size: 34, bold: true, color: C.ink },
        paragraph: { spacing: { before: 480, after: 160 }, outlineLevel: 0, border: { bottom: { style: BorderStyle.SINGLE, size: 12, color: C.amber, space: 6 } } } },
      { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { font: 'Calibri', size: 26, bold: true, color: C.grafite },
        paragraph: { spacing: { before: 300, after: 100 }, outlineLevel: 1 } },
    ],
  },
  numbering: {
    config: [
      { reference: 'bullets', levels: [{ level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 440, hanging: 260 } } } }] },
      { reference: 'steps', levels: [{ level: 0, format: LevelFormat.DECIMAL, text: '%1.', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 440, hanging: 300 } } } }] },
    ],
  },
  sections: [{
    properties: { page: { size: { width: PAGE_W, height: 16838 }, margin: { top: MARGIN, bottom: MARGIN, left: MARGIN, right: MARGIN } } },
    footers: {
      default: new Footer({
        children: [new Paragraph({
          alignment: AlignmentType.RIGHT,
          children: [
            new TextRun({ text: `Celiware IHM · Documentação Técnica · Versão ${VERSION}    `, size: 16, color: C.dim }),
            new TextRun({ children: [PageNumber.CURRENT], size: 16, color: C.dim }),
          ],
        })],
      }),
    },
    children: [...cover, ...blocks],
  }],
});

Packer.toBuffer(doc).then((buf) => {
  fs.writeFileSync(OUT, buf);
  console.log(`Gerado: ${path.relative(ROOT, OUT)} (${Math.round(buf.length / 1024)} KB)`);
});
