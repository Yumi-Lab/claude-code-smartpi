#!/usr/bin/env node
// codecache.cjs — isolate the COMPILE phase of cold start and measure how much a V8
// bytecode cache eliminates. Keeps V8 (JIT) — this is the "same runtime, faster start"
// lever, portable to the pad's Node 20 (unlike NODE_COMPILE_CACHE, which is Node 22+).
//
// Compiles the ~26 MB node20 CJS bundle with vm.Script twice:
//   cold  = new vm.Script(src, {produceCachedData:true})   → parse + compile from source
//   warm  = new vm.Script(src, {cachedData})               → deserialize cached bytecode
// It does NOT execute the bundle (no Node host needed); it measures compile only, which
// is the dominant, deterministic part of the 6–10 s cold start on the H3.
//
// Emits one JSON line to stdout.
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const bundle = process.argv[2] || path.join(__dirname, '..', 'build', 'bundle.node20.cjs');
const src = fs.readFileSync(bundle, 'utf8');

function now() { const [s, n] = process.hrtime(); return s * 1000 + n / 1e6; }

// cold: compile from source, produce cache
let t = now();
const cold = new vm.Script(src, { filename: 'bundle.cjs', produceCachedData: true });
const coldMs = now() - t;
const cachedData = cold.cachedData; // Buffer of V8 bytecode

// warm: compile using the cache (fresh Script so V8 can't reuse in-process state)
t = now();
const warm = new vm.Script(src, { filename: 'bundle.cjs', cachedData });
const warmMs = now() - t;

const out = {
  variant: 'v8-codecache',
  bundle_bytes: Buffer.byteLength(src),
  cache_bytes: cachedData ? cachedData.length : 0,
  cold_compile_ms: Math.round(coldMs * 10) / 10,
  warm_compile_ms: Math.round(warmMs * 10) / 10,
  saved_ms: Math.round((coldMs - warmMs) * 10) / 10,
  saved_pct: Math.round((1 - warmMs / coldMs) * 1000) / 10,
  cached_data_rejected: !!warm.cachedDataRejected,
  node: process.versions.node,
  arch: process.arch,
};
process.stdout.write(JSON.stringify(out) + '\n');
