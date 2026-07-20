#!/usr/bin/env node
// claude-cc.cjs — Node-20-compatible cached launcher (PoC of the shippable win).
// Runs the extracted Claude Code bundle under V8, but persists the V8 bytecode cache to
// disk (vm.Script produceCachedData / cachedData) so every launch AFTER the first skips
// parse+compile of the 26 MB bundle. Unlike NODE_COMPILE_CACHE this works on Node 20.
//
// This is a benchmark artifact that also demonstrates feasibility — it really launches
// Claude (prints --version). It mirrors shim/claude.mjs, in CJS, with the cache wrapper.
//
//   BENCH_BUNDLE=/…/bundle.node20.cjs  BENCH_BASE=/…/node-baseline  node claude-cc.cjs --version
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const { createRequire } = require('module');

const BASE = process.env.BENCH_BASE || path.join(__dirname, '..', 'node-baseline');
const BUNDLE = process.env.BENCH_BUNDLE || path.join(__dirname, '..', 'build', 'bundle.node20.cjs');
const CACHE = process.env.BENCH_CACHE || path.join(__dirname, '.compile-cache', 'bundle.v8cache');

(async () => {
  process.env.DISABLE_AUTOUPDATER = process.env.DISABLE_AUTOUPDATER || '1';

  // Bun→Node shim (reuse the shipping one, ESM → dynamic import from CJS).
  const { installBunShim } = await import(path.join(BASE, 'bun-shim.mjs'));
  installBunShim();

  const src = fs.readFileSync(BUNDLE, 'utf8');
  // Wrap as a CJS factory so vm can hand us (module,exports,require,__filename,__dirname).
  const wrapped =
    '(function(module,exports,require,__filename,__dirname){' + src + '\n})';

  const cacheDisabled = process.env.BENCH_CACHE_DISABLE === '1'; // force cold path (measure baseline)
  let cachedData;
  if (!cacheDisabled) { try { cachedData = fs.readFileSync(CACHE); } catch { /* first run */ } }

  let script = new vm.Script(wrapped, { filename: 'cli.js', cachedData });
  const missedCache = !cachedData || script.cachedDataRejected;
  if (missedCache && !cacheDisabled) {
    // produce + persist the bytecode for next time
    const produced = new vm.Script(wrapped, { filename: 'cli.js', produceCachedData: true }).cachedData;
    fs.mkdirSync(path.dirname(CACHE), { recursive: true });
    fs.writeFileSync(CACHE, produced);
    script = new vm.Script(wrapped, { filename: 'cli.js', cachedData: produced });
  }
  if (process.env.BENCH_CACHE_STATUS) {
    process.stderr.write(`[claude-cc] cache ${missedCache ? 'MISS (built)' : 'HIT'}\n`);
  }

  const outerFactory = script.runInThisContext();

  // require base: resolve ws/undici/js-yaml + embedded assets like shim/claude.mjs does.
  const bundlePath = path.join(BASE, 'cli.js');
  const baseRequire = createRequire(bundlePath);
  const assetsDir = path.join(BASE, 'assets');
  function patchedRequire(id) {
    if (typeof id === 'string') {
      if (id.startsWith('bun:')) {
        const e = new Error(`Cannot find module '${id}' (Bun-only, Node shim)`);
        e.code = 'MODULE_NOT_FOUND'; throw e;
      }
      if (id.startsWith('/$bunfs/root/')) {
        const f = path.join(assetsDir, id.slice('/$bunfs/root/'.length));
        try { return baseRequire(f); } catch {
          const e = new Error(`Cannot find embedded module '${id}'`);
          e.code = 'MODULE_NOT_FOUND'; throw e;
        }
      }
    }
    return baseRequire(id);
  }
  patchedRequire.resolve = baseRequire.resolve.bind(baseRequire);
  patchedRequire.cache = baseRequire.cache;

  // run the outer cjs wrapper → module.exports.default = the Claude factory
  const outerModule = { exports: {} };
  outerFactory(outerModule, outerModule.exports, patchedRequire, bundlePath, path.dirname(bundlePath));
  const factory = outerModule.exports.default || outerModule.exports;

  const mod = { exports: {}, filename: bundlePath, id: '.', loaded: false };
  factory.call(mod.exports, mod.exports, patchedRequire, mod, bundlePath, path.dirname(bundlePath));
})().catch((e) => { console.error(e); process.exit(1); });
