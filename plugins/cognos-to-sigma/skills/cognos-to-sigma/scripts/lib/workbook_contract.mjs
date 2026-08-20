// Cognos workbook-code release gate. Data-model specs intentionally do not use
// this contract: their pages[*].elements nesting remains unchanged.
import * as CodeRep from './code_rep.mjs';

const count = (text, needle) => text.split(needle).length - 1;

export function workbookContractErrors(spec, { requireWrapper = false } = {}) {
  const errors = [];
  if (requireWrapper && (!spec || typeof spec.document !== 'object' || Array.isArray(spec.document))) {
    errors.push('top-level `document` wrapper is required');
  }
  const rawDoc = spec && typeof spec.document === 'object' && !Array.isArray(spec.document)
    ? spec.document : spec;
  for (const page of (Array.isArray(rawDoc?.pages) ? rawDoc.pages : [])) {
    if (Array.isArray(page?.elements)) errors.push(`page ${page.id || '(missing id)'} is not metadata-only (remove page.elements)`);
  }
  const doc = CodeRep.document(spec);
  const pages = Array.isArray(doc.pages) ? doc.pages : [];
  const elements = CodeRep.workbookElements(doc);
  const layout = typeof doc.layout === 'string' ? doc.layout : '';

  if (!Array.isArray(doc.pages)) errors.push('document.pages must be an array');
  if (!Array.isArray(doc.elements)) errors.push('document.elements must be a flat array');
  pages.forEach((page) => { if (!page?.id) errors.push('every page needs an id'); });
  if (!layout.trim()) errors.push('document.layout is required and must be authoritative');

  const pageIds = pages.map((page) => page?.id).filter(Boolean);
  if (new Set(pageIds).size !== pageIds.length) errors.push('page ids must be unique');
  for (const pageId of pageIds) {
    if (!new RegExp(`<Page\\b[^>]*\\bid="${String(pageId).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`).test(layout)) {
      errors.push(`layout has no <Page> block for ${pageId}`);
    }
  }
  if (doc.panels !== undefined && !Array.isArray(doc.panels)) errors.push('document.panels must be an array');
  for (const panel of (Array.isArray(doc.panels) ? doc.panels : [])) {
    if (!panel?.id || !['header', 'sidebar'].includes(panel.type)) {
      errors.push('every document panel needs an id and type header|sidebar');
    }
    for (const pageId of (Array.isArray(panel?.pages) ? panel.pages : [])) {
      if (!pageIds.includes(pageId)) errors.push(`panel ${panel.id || '(missing id)'} references unknown page ${pageId}`);
    }
  }

  const elementIds = elements.map((element) => element?.id).filter(Boolean);
  if (new Set(elementIds).size !== elementIds.length) errors.push('flat document element ids must be unique');
  for (const elementId of elementIds) {
    const n = count(layout, `elementId="${elementId}"`);
    if (n !== 1) errors.push(`element ${elementId} must appear exactly once in layout (found ${n})`);
  }
  const known = new Set(elementIds);
  for (const match of layout.matchAll(/\belementId="([^"]+)"/g)) {
    if (!known.has(match[1])) errors.push(`layout references unknown element ${match[1]}`);
  }
  return errors;
}

export function assertWorkbookContract(spec, options = {}) {
  const errors = workbookContractErrors(spec, options);
  if (errors.length) throw new Error(`workbook code contract failed:\n- ${errors.join('\n- ')}`);
  return CodeRep.document(spec);
}
