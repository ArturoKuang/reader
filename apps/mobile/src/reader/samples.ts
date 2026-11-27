/* eslint-disable @typescript-eslint/no-require-imports */
import type { BookIdentity } from "../contract/types";
import catalog from "../../assets/samples/catalog.json";

export const pdfModule = require("../../assets/samples/ishmael.pdf") as number;
export const epubModule = require("../../assets/samples/ishmael.epub") as number;

export const pdfBook: BookIdentity = {
  fingerprint: catalog.pdf.fingerprint,
  pdfId: catalog.pdf.pdfId,
};

export const epubBook: BookIdentity = {
  fingerprint: catalog.epub.fingerprint,
  epubId: catalog.epub.epubId,
};

export const sampleTitles = {
  pdf: catalog.pdf.title,
  epub: catalog.epub.title,
};
