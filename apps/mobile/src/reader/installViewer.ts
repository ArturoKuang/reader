import { Asset } from "expo-asset";
import { Directory, File, Paths } from "expo-file-system";
import { viewerAssets } from "./vendorManifest";
import { epubViewerHtml, pdfViewerHtml } from "./viewerHtml";

let installing: Promise<Directory> | null = null;

export function viewerRoot(): Promise<Directory> {
  if (!installing) installing = install();
  return installing;
}

async function install(): Promise<Directory> {
  const root = new Directory(Paths.cache, "reader-viewer");
  if (!root.exists) root.create({ intermediates: true });
  for (const [relativePath, moduleId] of Object.entries(viewerAssets)) {
    const asset = Asset.fromModule(moduleId);
    await asset.downloadAsync();
    if (!asset.localUri) throw new Error(`Missing bundled file ${relativePath}`);
    const parts = relativePath.split("/");
    let directory = root;
    for (const part of parts.slice(0, -1)) {
      directory = new Directory(directory, part);
      if (!directory.exists) directory.create({ intermediates: true });
    }
    const destination = new File(directory, parts[parts.length - 1] ?? relativePath);
    if (destination.exists) destination.delete();
    await new File(asset.localUri).copy(destination);
  }
  await write(new File(root, "pdf.html"), pdfViewerHtml());
  await write(new File(root, "epub.html"), epubViewerHtml());
  return root;
}

async function write(file: File, contents: string): Promise<void> {
  if (file.exists) file.delete();
  file.create();
  await file.write(contents);
}

export async function readAssetBase64(moduleId: number): Promise<string> {
  const asset = Asset.fromModule(moduleId);
  await asset.downloadAsync();
  if (!asset.localUri) throw new Error("The sample book is not on disk.");
  return new File(asset.localUri).base64();
}
