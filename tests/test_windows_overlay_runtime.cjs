const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {webcrypto} = require('node:crypto');
const path = require('node:path');
const root = process.argv[2];
assert(root, 'Pass a generated overlay directory');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'overlay-manifest.json')));
const source = fs.readFileSync(path.join(root, 'frontend-source/' + manifest.worker), 'utf8');
const handlers = {};
const storage = new Map();
let corrupt = false;
let currentVersion = true;
let fetches = [];
const fakeFetch = async request => {
  const url = new URL(typeof request === 'string' ? request : request.url || request.href);
  assert.equal(url.protocol, 'app:', 'Synthetic cache origin must never be fetched');
  assert.equal(url.hostname, 'localhost');
  fetches.push(url.pathname);
  if (url.pathname === '/index.html') return new Response(currentVersion ? fs.readFileSync(path.join(root, 'frontend-source/index.html')) : '<html>updated build</html>');
  if (corrupt) return new Response('corrupted payload');
  return new Response(fs.readFileSync(path.join(root, 'frontend-source', url.pathname.slice(1))));
};
vm.runInNewContext(source, {
  self: {location:{href:'app://localhost/claude-zh-overlay-4-29-v1.js'},addEventListener:(event,fn)=>handlers[event]=fn,skipWaiting:async()=>{},clients:{claim:async()=>{}}},
  fetch:fakeFetch, crypto:webcrypto, Uint8Array, URL, Response,
  caches:{open:async()=>({put:async(key,value)=>storage.set(key,value),match:async key=>storage.get(key)?.clone(),keys:async()=>[...storage.keys()]}),delete:async()=>storage.clear()}
});
(async()=>{
  let work;
  handlers.install({waitUntil:promise=>work=promise}); await work;
  assert.equal(storage.size,Object.keys(manifest.assets).length);
  const verifiedFiles = storage.size;
  const file = Object.keys(manifest.assets)[0];
  let response;
  const request={url:'app://localhost'+file,method:'GET',mode:'cors'};
  fetches=[];
  handlers.fetch({request,respondWith:p=>response=p});
  assert(response); assert((await response).ok); assert.equal(fetches.length,0);
  for(const url of ['app://localhost/api/bootstrap','app://localhost/api/messages','https://example.com'+file]) {
    let intercepted=false;
    handlers.fetch({request:{url,method:'GET',mode:'cors'},respondWith:()=>intercepted=true});
    assert.equal(intercepted,false,'Must not intercept API or remote requests');
  }
  let intercepted=false;
  handlers.fetch({request:{...request,method:'POST'},respondWith:()=>intercepted=true});
  assert.equal(intercepted,false);
  currentVersion=false;
  handlers.fetch({request:{url:'app://localhost/new',method:'GET',mode:'navigate'},waitUntil:p=>work=p}); await work;
  fetches=[];
  handlers.fetch({request,respondWith:p=>response=p}); await response;
  assert.deepEqual(fetches,[file],'New versions must use original resources');
  currentVersion=true; corrupt=true;
  handlers.fetch({request:{url:'app://localhost/new',method:'GET',mode:'navigate'},waitUntil:p=>work=p}); await work;
  handlers.install({waitUntil:p=>work=p});
  await assert.rejects(work, /hash mismatch/);
  console.log(`PASS: ${verifiedFiles} hash-checked static files; API isolation, version mismatch fallback, and corrupt-payload rejection.`);
})().catch(error=>{console.error(error);process.exitCode=1;});
