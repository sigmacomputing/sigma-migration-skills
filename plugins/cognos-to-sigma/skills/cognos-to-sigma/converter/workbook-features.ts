/**
 * Grounded Cognos → Sigma workbook feature catalog.
 *
 * Keep enumerable source mappings here instead of scattering optimistic string
 * matches through the converter. `refs/cognos-coverage.md` documents the source
 * evidence and release/gating status for each target.
 */
export const VIZ_KIND: Record<string, string> = {
  'com.ibm.vis.clusteredbar': 'bar-chart',
  'com.ibm.vis.stackedbar': 'bar-chart',
  'com.ibm.vis.clusteredcolumn': 'bar-chart',
  'com.ibm.vis.stackedcolumn': 'bar-chart',
  'com.ibm.vis.line': 'line-chart',
  'com.ibm.vis.spline': 'line-chart',
  'com.ibm.vis.area': 'area-chart',
  'com.ibm.vis.stackedarea': 'area-chart',
  'com.ibm.vis.pie': 'pie-chart',
  'com.ibm.vis.donut': 'donut-chart',
  'com.ibm.vis.clusteredcombination': 'combo-chart',
  'com.ibm.vis.stackedcombination': 'combo-chart',
  'com.ibm.vis.bubble': 'scatter-chart',
  'com.ibm.vis.scatter': 'scatter-chart',
  // Released in workbook code: required shape is source + columns + yAxis.
  'com.ibm.vis.waterfall': 'waterfall-chart',
  'com.ibm.vis.waterfallchart': 'waterfall-chart',
};

export const VIZ_NO_ANALOG: Record<string, string> = {
  'com.ibm.vis.network': 'network diagram',
  'com.ibm.vis.wordcloud': 'word cloud',
  'com.ibm.vis.packedbubble': 'packed bubble',
  'com.ibm.vis.treemap': 'treemap',
};

// Sigma exposes box-chart in the workbook schema only where the workspace
// feature is enabled. A converter cannot know entitlement before POST, so box
// plots remain a loud, table-preserving fallback instead of a masked failure.
export const VIZ_GATED: Record<string, string> = {
  'com.ibm.vis.box': 'box plot',
  'com.ibm.vis.boxplot': 'box plot',
  'com.ibm.vis.boxandwhisker': 'box-and-whisker plot',
};

export const RELEASED_WORKBOOK_FEATURES = {
  wrapper: { source: 'report', target: 'document', status: 'released' },
  flatElements: { source: 'page contents', target: 'document.elements', status: 'released' },
  layout: { source: 'report page membership', target: 'document.layout', status: 'required' },
  waterfall: { source: 'com.ibm.vis.waterfall*', target: 'waterfall-chart', status: 'released' },
  legend: { source: 'vizProperty*Value(name=*legend*)', target: 'legend', status: 'released' },
  drill: { source: 'drillBehavior', target: 'control/controlType=drill', status: 'released' },
  navigation: { source: 'viewPagesAsTabs', target: 'navigation/mode=auto', status: 'released' },
  tabs: { source: 'reportPages/page', target: 'pages + navigation', status: 'released' },
  pageBreak: { source: 'pageBreak', target: 'page-break', status: 'released' },
  progress: { source: 'com.ibm.vis.progress*', target: 'progress', status: 'released' },
  panels: { source: 'pageHeader', target: 'document.panels[type=header]', status: 'released' },
  styles: { source: 'style/CSS', target: 'panel.config or container.style', status: 'released' },
  repeaters: { source: 'repeater/repeaterTable', target: 'repeated-container', status: 'released' },
  box: { source: 'com.ibm.vis.box*', target: 'box-chart', status: 'workspace-gated' },
} as const;

export function workbookGap(feature: string, detail: string): string {
  return `⛔ WORKBOOK FEATURE GAP [${feature}]: ${detail}`;
}
