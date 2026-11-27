import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const out = join(dirname(fileURLToPath(import.meta.url)), "../assets/samples");
mkdirSync(out, { recursive: true });

const pageOne = [
  "Call me Ishmael.",
  "Some years ago, never mind how long precisely,",
  "having little or no money in my purse,",
  "and nothing particular to interest me on shore,",
  "I thought I would sail about a little",
  "and see the watery part of the world.",
];
const pageTwo = [
  "It is a way I have of driving off the spleen.",
  "Whenever I find myself growing grim about the mouth,",
  "whenever it is a damp, drizzly November in my soul,",
  "I account it high time to get to sea as soon as I can.",
];

function pdfEscape(text) {
  return text.replace(/\\/g, "\\\\").replace(/\(/g, "\\(").replace(/\)/g, "\\)");
}

function pageContent(lines) {
  const commands = ["BT", "/F1 16 Tf", "72 700 Td"];
  lines.forEach((line, index) => {
    if (index > 0) commands.push("0 -28 Td");
    commands.push(`(${pdfEscape(line)}) Tj`);
  });
  commands.push("ET");
  return commands.join("\n");
}

function buildPdf() {
  const parts = [Buffer.from("%PDF-1.4\n")];
  let cursor = parts[0].length;
  const offsets = [0];
  function add(number, body) {
    offsets[number] = cursor;
    const buf = Buffer.from(`${number} 0 obj\n${body}\nendobj\n`);
    parts.push(buf);
    cursor += buf.length;
  }
  function addStream(number, content) {
    const data = Buffer.from(content, "latin1");
    const header = Buffer.from(`${number} 0 obj\n<< /Length ${data.length} >>\nstream\n`);
    const footer = Buffer.from("\nendstream\nendobj\n");
    offsets[number] = cursor;
    parts.push(header, data, footer);
    cursor += header.length + data.length + footer.length;
  }
  add(1, "<< /Type /Catalog /Pages 2 0 R >>");
  add(2, "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>");
  add(
    3,
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
  );
  addStream(4, pageContent(pageOne));
  add(
    5,
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
  );
  addStream(6, pageContent(pageTwo));
  add(7, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
  let xref = "xref\n0 8\n0000000000 65535 f \n";
  for (let number = 1; number <= 7; number += 1) {
    xref += `${String(offsets[number]).padStart(10, "0")} 00000 n \n`;
  }
  const trailer =
    `trailer\n<< /Size 8 /Root 1 0 R /ID [<4B1E77C0><99AA>] >>\nstartxref\n${cursor}\n%%EOF\n`;
  parts.push(Buffer.from(xref + trailer));
  return Buffer.concat(parts);
}

function crc32(buf) {
  let crc = 0xffffffff;
  for (const byte of buf) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function zipStore(files) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const file of files) {
    const name = Buffer.from(file.name);
    const data = file.data;
    const method = 0;
    const crc = crc32(file.data);
    const local = Buffer.alloc(30 + name.length);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(method, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(file.data.length, 22);
    local.writeUInt16LE(name.length, 26);
    name.copy(local, 30);
    locals.push(local, data);
    const central = Buffer.alloc(46 + name.length);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(method, 10);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(file.data.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(offset, 42);
    name.copy(central, 46);
    centrals.push(central);
    offset += local.length + data.length;
  }
  const centralBuf = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(files.length, 8);
  end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(centralBuf.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, centralBuf, end]);
}

function xhtml(title, paragraphs) {
  const body = paragraphs.map((p) => `<p>${p}</p>`).join("\n");
  return `<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>${title}</title></head>
<body>
<h1>${title}</h1>
${body}
</body>
</html>
`;
}

const chapter1 = xhtml("Chapter 1. Loomings", [
  "Call me Ishmael.",
  "Some years ago, never mind how long precisely, having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world.",
]);
const chapter2 = xhtml("Chapter 1, continued", [
  "It is a way I have of driving off the spleen.",
  "Whenever I find myself growing grim about the mouth, whenever it is a damp, drizzly November in my soul, I account it high time to get to sea as soon as I can.",
]);
const opf = `<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:public-domain:moby-dick-opening</dc:identifier>
    <dc:title>Moby-Dick, opening</dc:title>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>
`;
const container = `<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
`;

const pdf = buildPdf();
const epub = zipStore([
  { name: "mimetype", data: Buffer.from("application/epub+zip") },
  { name: "META-INF/container.xml", data: Buffer.from(container) },
  { name: "OEBPS/content.opf", data: Buffer.from(opf) },
  { name: "OEBPS/chapter1.xhtml", data: Buffer.from(chapter1) },
  { name: "OEBPS/chapter2.xhtml", data: Buffer.from(chapter2) },
]);
writeFileSync(join(out, "ishmael.pdf"), pdf);
writeFileSync(join(out, "ishmael.epub"), epub);

function fingerprint(data) {
  return `sha256:${createHash("sha256").update(data).digest("hex")}`;
}

const catalog = {
  pdf: {
    title: "Moby-Dick, opening",
    file: "ishmael.pdf",
    format: "pdf",
    fingerprint: fingerprint(pdf),
    pdfId: "4b1e77c0",
  },
  epub: {
    title: "Moby-Dick, opening",
    file: "ishmael.epub",
    format: "epub",
    fingerprint: fingerprint(epub),
    epubId: "urn:public-domain:moby-dick-opening",
  },
};
writeFileSync(join(out, "catalog.json"), `${JSON.stringify(catalog, null, 2)}\n`);
console.log(catalog.pdf.fingerprint);
console.log(catalog.epub.fingerprint);
