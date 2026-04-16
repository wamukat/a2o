import assert from "node:assert/strict";
import { renderSummary } from "../src/render-storefront.js";

assert.equal(renderSummary({ total: 3, available: 2 }), "Available packs: 2 of 3");
