"use strict";
const FILES = __FILES__;
const CACHE = __CACHE__;
const BUILD = __BUILD__;
const STAMP = __STAMP__;
const ENTRY_SCRIPTS = __SCRIPTS__;
// This HTTPS origin is only a CacheStorage key, never a fetch destination.
const cacheKey = path => "https://claude-zh-cache.invalid/" + BUILD + path;
let versionPromise;
const digest = async buffer => [...new Uint8Array(await crypto.subtle.digest("SHA-256", buffer))].map(x => x.toString(16).padStart(2, "0")).join("");
async function compatible(refresh = false) {
  if (refresh || !versionPromise) versionPromise = (async () => {
    try {
      const response = await fetch(new URL("/index.html", self.location.href), {cache:"no-store"});
      const html = await response.text();
      return response.ok && html.includes(STAMP) && ENTRY_SCRIPTS.every(path => html.includes('src="' + path + '"'));
    } catch { return false; }
  })();
  return versionPromise;
}
self.addEventListener("install", event => event.waitUntil((async () => {
  if (!await compatible()) throw new Error("Claude build differs from 4.29 overlay");
  await caches.delete(CACHE);
  const cache = await caches.open(CACHE);
  const paths = Object.keys(FILES);
  let next = 0;
  await Promise.all(Array.from({length:6}, async () => {
    while (next < paths.length) {
      const path = paths[next++];
      const response = await fetch(new URL(path, self.location.href), {cache:"no-store"});
      if (!response.ok) throw new Error("Overlay fetch failed: " + path);
      const bytes = await response.arrayBuffer();
      if (bytes.byteLength !== FILES[path].size || await digest(bytes) !== FILES[path].hash) throw new Error("Overlay hash mismatch: " + path);
      const type = path.endsWith(".js") ? "text/javascript; charset=utf-8" : "application/json; charset=utf-8";
      await cache.put(cacheKey(path), new Response(bytes, {headers:{"Content-Type":type,"Cache-Control":"no-cache"}}));
    }
  }));
  await self.skipWaiting();
})()));
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()));
self.addEventListener("fetch", event => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.protocol !== "app:" || url.hostname !== "localhost") return;
  if (event.request.mode === "navigate") { event.waitUntil(compatible(true)); return; }
  if (!Object.prototype.hasOwnProperty.call(FILES, url.pathname)) return;
  event.respondWith((async () => {
    if (await compatible()) {
      const cached = await (await caches.open(CACHE)).match(cacheKey(url.pathname));
      if (cached) return cached;
    }
    return fetch(event.request);
  })());
});
self.addEventListener("message", event => {
  if (event.data?.type !== "claude-zh-status" || !event.ports[0] || !event.source?.url?.startsWith("app://localhost/")) return;
  event.waitUntil((async () => {
    const count = (await (await caches.open(CACHE)).keys()).length;
    event.ports[0].postMessage({version:"4.29",build:BUILD,count,expected:Object.keys(FILES).length,compatible:await compatible()});
  })());
});
