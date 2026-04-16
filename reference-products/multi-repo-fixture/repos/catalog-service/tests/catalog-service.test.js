import assert from "node:assert/strict";
import { catalog, summarizeCatalog } from "../src/catalog-service.js";

const summary = summarizeCatalog(catalog);

assert.equal(summary.total, 3);
assert.equal(summary.available, 2);
