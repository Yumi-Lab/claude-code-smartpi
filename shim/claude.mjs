#!/usr/bin/env node
// Launcher: runs the extracted Claude Code bundle (Bun standalone JS) under
// Node.js with a Bun API shim. The bundle is a CJS-style factory function
// exported as ESM default from bundle.mjs so import.meta.* stays legal.
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { installBunShim } from './bun-shim.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

process.env.DISABLE_AUTOUPDATER ??= '1';

installBunShim();

const bundlePath = path.join(__dirname, 'cli.js');
const baseRequire = createRequire(bundlePath);
const assetsDir = path.join(__dirname, 'assets');

function patchedRequire(id) {
  if (typeof id === 'string') {
    if (id.startsWith('bun:')) {
      const e = new Error(`Cannot find module '${id}' (Bun-only, Node shim)`);
      e.code = 'MODULE_NOT_FOUND';
      throw e;
    }
    if (id.startsWith('/$bunfs/root/')) {
      const f = path.join(assetsDir, id.slice('/$bunfs/root/'.length));
      try {
        return baseRequire(f);
      } catch {
        const e = new Error(`Cannot find embedded module '${id}' (asset not extracted)`);
        e.code = 'MODULE_NOT_FOUND';
        throw e;
      }
    }
  }
  return baseRequire(id);
}
patchedRequire.resolve = baseRequire.resolve.bind(baseRequire);
patchedRequire.cache = baseRequire.cache;
patchedRequire.main = undefined;

const mod = { exports: {}, filename: bundlePath, id: '.', loaded: false };

const { default: factory } = await import('./bundle.mjs');
factory.call(mod.exports, mod.exports, patchedRequire, mod, bundlePath, path.dirname(bundlePath));
