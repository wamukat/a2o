export const catalog = [
  { sku: "pack-001", name: "Launch Pack", price: 1200, available: true },
  { sku: "pack-002", name: "Support Pack", price: 800, available: true },
  { sku: "legacy-010", name: "Legacy Adapter", price: 300, available: false }
];

export function summarizeCatalog(items) {
  return {
    total: items.length,
    available: items.filter((item) => item.available).length
  };
}

if (process.argv.includes("--summary")) {
  console.log(JSON.stringify(summarizeCatalog(catalog)));
}
