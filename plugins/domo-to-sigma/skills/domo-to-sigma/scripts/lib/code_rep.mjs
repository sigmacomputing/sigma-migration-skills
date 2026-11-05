// Shape adapter for the Sigma WORKBOOK code representation.
//
// ENDPOINTS (OpenAPI 2.0.0+20261030, live-verified 2026-11-03): the /spec
// workbook and report endpoints are DEPRECATED. Their replacements carry the
// same document under `contents` instead of `document` (byte-identical on a
// live readback): POST /v2/workbooks, GET /v2/workbooks/{id}?includeContents=true,
// PUT /v2/workbooks/{id}/contents; dry-run = POST /v2/workbooks with dryRun: true.
// Build paths and bodies with the endpoint helpers below rather than
// hand-writing them. On-disk artifacts keep the `document` wrapper that wrap()
// emits; createBody/updateBody re-key it at the API boundary.
//
// Verified live 2026-08-03/04: a nested wrapper key is required on write
// (including dry-run); flat bodies 400. The DATA-MODEL code-rep surface is
// NOT changing — do not use this on /v2/dataModels/.../spec payloads.

// Workbook elements are flat document collections; `overlays` and `panels` live
// beside them. `settings` (theme/navigation) and `agents` belong inside
// `document` too. Omitting any of these sweeps it onto the metadata envelope,
// where it is invalid and silently dropped on write.
export const DOC_KEYS = [
  'schemaVersion', 'pages', 'elements', 'overlays', 'panels',
  'kind', 'layout', 'settings', 'agents', 'automatedActions',
];

// Envelope keys of the workbook/report responses that are never writable.
// The /spec-era name (latestDocumentVersion) stays listed so old snapshots
// strip the same way as live readbacks. folderId is writable, so it is kept.
export const RESPONSE_ONLY_KEYS = [
  'workbookId', 'workbookUrlId', 'reportId', 'reportUrlId', 'url', 'path',
  'documentVersion', 'latestVersion', 'latestDocumentVersion', 'ownerId',
  'createdBy', 'updatedBy', 'createdAt', 'updatedAt', 'isArchived', 'tags',
  'taggedSourceUrlId', 'warnings', 'dryRun', 'valid', 'errors',
];
export const CREATE_METADATA_KEYS = ['name', 'folderId', 'description', 'ownerId'];

const WORKBOOKS_PATH = '/v2/workbooks';
const REPORTS_PATH = '/v2/reports';

// REMOVED from the API. The workbook theme is now settings.theme.name /
// settings.theme.overrides (published OpenAPI: createWorkbookSpec has zero
// occurrences of themeName/themeOverrides). The individual override keys are
// unchanged - only the container path moved. document() folds the legacy pair
// forward so specs and fixtures written before the move still produce a valid body.
export const LEGACY_THEME_KEYS = ['themeName', 'themeOverrides'];
export const LEGACY_HORIZONTAL_ALIGN = { start: 'left', middle: 'center', end: 'right' };
export const LEGACY_VERTICAL_ALIGN = { start: 'top', middle: 'center', end: 'bottom' };

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

export function document(response) {
  if (!isObj(response)) return {};
  const inner = isObj(response.contents) ? response.contents : response.document;
  const doc = isObj(inner)
    ? inner
    : Object.fromEntries(Object.entries(response).filter(([k]) => DOC_KEYS.includes(k)));
  return foldLegacyTheme(doc, response);
}

// themeName/themeOverrides -> settings.theme.{name,overrides}. Returns the input
// untouched when no legacy key is present (the common, already-correct path).
function foldLegacyTheme(doc, source) {
  const name = doc.themeName || source.themeName;
  const overrides = doc.themeOverrides || source.themeOverrides;
  const hasOv = isObj(overrides) && Object.keys(overrides).length > 0;
  const hasLegacyKey = LEGACY_THEME_KEYS.some((k) => k in doc);
  if (!name && !hasOv && !hasLegacyKey) return doc;

  const out = Object.fromEntries(
    Object.entries(doc).filter(([k]) => !LEGACY_THEME_KEYS.includes(k)),
  );
  const settings = { ...(out.settings || {}) };
  const theme = { ...(settings.theme || {}) };
  if (name && !theme.name) theme.name = name;
  if (hasOv) theme.overrides = { ...(theme.overrides || {}), ...overrides };
  if (Object.keys(theme).length === 0) return out;
  settings.theme = theme;
  out.settings = settings;
  return out;
}

// Emitter helper - set the workbook theme in the CURRENT shape. Builders should
// call this instead of assigning the removed themeName/themeOverrides pair.
export function setTheme(doc, { name = null, overrides = null } = {}) {
  const hasOv = isObj(overrides) && Object.keys(overrides).length > 0;
  if (!name && !hasOv) return doc;
  doc.settings = doc.settings || {};
  doc.settings.theme = doc.settings.theme || {};
  if (name) doc.settings.theme.name = name;
  if (hasOv) {
    doc.settings.theme.overrides = { ...(doc.settings.theme.overrides || {}), ...overrides };
  }
  return doc;
}

// Read the theme from either shape.
export function theme(spec) {
  const t = (document(spec).settings || {}).theme || {};
  return { name: t.name ?? null, overrides: t.overrides || {} };
}

export function metadata(response) {
  if (!isObj(response)) return {};
  return Object.fromEntries(
    Object.entries(response).filter(
      ([k]) => !['document', 'contents'].includes(k)
        && !DOC_KEYS.includes(k) && !LEGACY_THEME_KEYS.includes(k),
    ),
  );
}

// ---- Endpoint helpers -----------------------------------------------------
// `type` is 'workbook' or 'report'. Paths are relative to SIGMA_BASE_URL.

function collectionPath(type) {
  if (type === 'workbook') return WORKBOOKS_PATH;
  if (type === 'report') return REPORTS_PATH;
  throw new Error(`unknown code-rep type ${JSON.stringify(type)} (want 'workbook' or 'report')`);
}

// POST target for create and for dry-run validation.
export function createPath(type = 'workbook') {
  return collectionPath(type);
}

// GET that returns the envelope plus `contents` and `documentVersion`.
export function readPath(id, type = 'workbook', { documentVersion = null } = {}) {
  const path = `${collectionPath(type)}/${id}?includeContents=true`;
  if (documentVersion === null || documentVersion === undefined) return path;
  return `${path}&documentVersion=${Number.parseInt(documentVersion, 10)}`;
}

// PUT target that replaces an existing document.
export function updatePath(id, type = 'workbook') {
  return `${collectionPath(type)}/${id}/contents`;
}

function apiContents(spec, type) {
  collectionPath(type); // validates type
  return type === 'workbook'
    ? canonicalizeDocument(flattenElements(document(spec)))
    : document(spec);
}

// Create (or dry-run) body. `spec` may be a bare document, a `document`- or
// `contents`-wrapped artifact, or a flat legacy artifact; its name / folderId /
// description / ownerId are used unless overridden in `extra`. Workbook
// contents are flattened/canonicalized like wrap(); report contents are a
// different representation and pass through untouched.
export function createBody(spec, { extra = {}, dryRun = false, type = 'workbook' } = {}) {
  const meta = Object.fromEntries(
    Object.entries(metadata(spec)).filter(([k]) => CREATE_METADATA_KEYS.includes(k)),
  );
  const body = { ...meta, ...extra, contents: apiContents(spec, type) };
  if (dryRun) body.dryRun = true;
  return body;
}

// Update body. Pass the documentVersion you read to make the PUT fail with
// code stale_document_settings instead of overwriting newer edits.
export function updateBody(spec, { documentVersion = null, type = 'workbook' } = {}) {
  const body = { contents: apiContents(spec, type) };
  if (documentVersion !== null && documentVersion !== undefined) {
    body.documentVersion = documentVersion;
  }
  return body;
}

// Normalize a dry-run response to the /spec/verify-era shape callers check:
// { valid, errors: [{ summary }], warnings }. Success is HTTP 200 with no
// `valid` key; a schema failure is HTTP 400 with valid:false and errors;
// other 4xx carry only `message`.
export function dryRunResult(status, body) {
  const code = Number(status) || 0;
  const b = isObj(body) ? body : {};
  const warnings = Array.isArray(b.warnings) ? b.warnings : [];
  if (code >= 200 && code <= 299) return { valid: true, errors: [], warnings };
  let errors = Array.isArray(b.errors) ? b.errors : [];
  if (errors.length === 0) errors = [{ summary: b.message || `HTTP ${code}` }];
  return { valid: false, errors, warnings };
}

// Strip non-writable envelope keys (live and /spec-era) from a readback.
export function stripResponseOnly(spec) {
  if (!isObj(spec)) return spec;
  return Object.fromEntries(
    Object.entries(spec).filter(([k]) => !RESPONSE_ONLY_KEYS.includes(k)),
  );
}

export function workbookElements(spec) {
  const doc = document(spec);
  if (Array.isArray(doc.elements)) return doc.elements.filter(isObj);
  return (Array.isArray(doc.pages) ? doc.pages : [])
    .filter(isObj)
    .flatMap((page) => (Array.isArray(page.elements) ? page.elements.filter(isObj) : []));
}

export function workbookPageElementIds(spec) {
  const result = {};
  const layout = String(document(spec).layout || '');
  const regionPattern = /<(Page|Panel|Overlay)\b[^>]*\bid="([^"]*)"[^>]*>(.*?)<\/\1>/gs;
  for (const match of layout.matchAll(regionPattern)) {
    result[match[2]] = [...new Set(
      [...match[3].matchAll(
        /<(?:Element|Container|TabbedContainer|LayoutElement|GridContainer)\b[^>]*\belementId="([^"]*)"/g,
      )].map((element) => element[1]),
    )];
  }
  return result;
}

export function workbookPageByElement(spec) {
  const doc = document(spec);
  const pages = Array.isArray(doc.pages) ? doc.pages.filter(isObj) : [];
  const pagesById = Object.fromEntries(pages.filter((page) => page.id).map((page) => [page.id, page]));
  const result = {};
  for (const [pageId, elementIds] of Object.entries(workbookPageElementIds(doc))) {
    const page = pagesById[pageId] || { id: pageId, name: pageId };
    for (const elementId of elementIds) result[elementId] ||= page;
  }
  return result;
}

export function workbookElementsWithPages(spec) {
  const pageByElement = workbookPageByElement(spec);
  return workbookElements(spec).map((element) => [
    element,
    pageByElement[element.id || element.elementId],
  ]);
}

function flattenElements(doc) {
  if (!isObj(doc) || !Array.isArray(doc.pages)) return doc;
  const nested = [];
  const pages = doc.pages.map((page) => {
    const copy = { ...page };
    if (Array.isArray(copy.elements)) nested.push(...copy.elements);
    delete copy.elements;
    return copy;
  });
  const elements = [];
  const seen = new Set();
  for (const element of [...(Array.isArray(doc.elements) ? doc.elements : []), ...nested]) {
    const id = isObj(element) ? element.id : null;
    if (id && seen.has(id)) continue;
    if (id) seen.add(id);
    elements.push(element);
  }
  return { ...doc, pages, elements };
}

export function canonicalizeLayout(layoutXml) {
  return String(layoutXml || '')
    .replace(/<([/]?)LayoutElement\b/g, '<$1Element')
    .replace(/<([/]?)GridContainer\b/g, '<$1Container');
}

function canonicalizeElement(element) {
  if (!isObj(element)) return element;
  // Workbook code representation rejects this data-model-only field. Keep it
  // in local specs for parity/census readers, but never emit it through wrap().
  const { visibleAsSource: _removedVisibleAsSource, ...workbookElement } = element;
  element = workbookElement;
  if (element.kind === 'text' && element.verticalAlign in LEGACY_VERTICAL_ALIGN) {
    return { ...element, verticalAlign: LEGACY_VERTICAL_ALIGN[element.verticalAlign] };
  }
  if (element.kind === 'kpi-chart' && isObj(element.layout)) {
    const layout = { ...element.layout };
    if (layout.anchor in LEGACY_HORIZONTAL_ALIGN) {
      layout.anchor = LEGACY_HORIZONTAL_ALIGN[layout.anchor];
    }
    if (layout.verticalAnchor in LEGACY_VERTICAL_ALIGN) {
      layout.verticalAnchor = LEGACY_VERTICAL_ALIGN[layout.verticalAnchor];
    }
    return { ...element, layout };
  }
  if (element.kind === 'tabbed-container' && isObj(element.tabBar)
      && element.tabBar.alignment in LEGACY_HORIZONTAL_ALIGN) {
    return {
      ...element,
      tabBar: {
        ...element.tabBar,
        alignment: LEGACY_HORIZONTAL_ALIGN[element.tabBar.alignment],
      },
    };
  }
  if (element.kind === 'divider' && element.align in LEGACY_VERTICAL_ALIGN) {
    const mapping = element.direction === 'vertical'
      ? LEGACY_HORIZONTAL_ALIGN
      : LEGACY_VERTICAL_ALIGN;
    return { ...element, align: mapping[element.align] };
  }
  return element;
}

function canonicalizeOverlay(overlay) {
  if (!isObj(overlay) || !isObj(overlay.drawer) || !('position' in overlay.drawer)) {
    return overlay;
  }
  const { position: _removed, ...drawer } = overlay.drawer;
  return { ...overlay, drawer };
}

function canonicalizeDocument(flattened) {
  if (!isObj(flattened)) return flattened;
  const canonical = { ...flattened };
  if (Array.isArray(flattened.elements)) {
    canonical.elements = flattened.elements.map(canonicalizeElement);
  }
  if (Array.isArray(flattened.overlays)) {
    canonical.overlays = flattened.overlays.map(canonicalizeOverlay);
  }
  if ('layout' in flattened) canonical.layout = canonicalizeLayout(flattened.layout);
  return canonical;
}

export function wrap(doc, extra = {}) {
  return { ...extra, document: canonicalizeDocument(flattenElements(doc)) };
}
