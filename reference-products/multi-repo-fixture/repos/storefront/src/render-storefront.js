export function renderSummary(catalogSummary) {
  return `Available packs: ${catalogSummary.available} of ${catalogSummary.total}`;
}

if (process.argv[1] && process.argv[1].endsWith("render-storefront.js")) {
  console.log(renderSummary({ total: 3, available: 2 }));
}
