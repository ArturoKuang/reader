import catalog from "../../assets/samples/catalog.json";
import { epubBook, pdfBook, sampleTitles } from "../reader/samples";
import { sha256OfFingerprint } from "../sync/controller";
import type { SampleBookSpec } from "./catalog";

/** Byte lengths of the bundled sample files. */
export const SAMPLE_PDF_SIZE = 1397;
export const SAMPLE_EPUB_SIZE = 2284;

export const sampleBooks: SampleBookSpec[] = [
  {
    title: sampleTitles.pdf,
    format: "pdf",
    fingerprint: pdfBook.fingerprint,
    sha256: sha256OfFingerprint(pdfBook.fingerprint),
    size: SAMPLE_PDF_SIZE,
    docId: pdfBook.pdfId,
    filename: catalog.pdf.file,
    testID: "library-pdf",
  },
  {
    title: sampleTitles.epub,
    format: "epub",
    fingerprint: epubBook.fingerprint,
    sha256: sha256OfFingerprint(epubBook.fingerprint),
    size: SAMPLE_EPUB_SIZE,
    docId: epubBook.epubId,
    filename: catalog.epub.file,
    testID: "library-epub",
  },
];
