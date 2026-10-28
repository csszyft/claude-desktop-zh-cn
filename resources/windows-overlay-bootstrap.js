(async () => {
  const prefix = "[claude-zh-overlay] ";
  const BUILD = __BUILD__;
  const COUNT = __COUNT__;
  const badge = text => {
    let element = document.getElementById("claude-zh-overlay-install-status");
    if (!element) { element = document.createElement("div"); element.id = "claude-zh-overlay-install-status"; element.style.cssText = "position:fixed;bottom:8px;right:8px;z-index:2147483647;padding:10px;background:#163b28;color:white;font:14px monospace;max-width:700px"; document.body.appendChild(element); }
    element.textContent = text;
  };
  try {
    console.warn(prefix + "START; serviceWorker=" + ("serviceWorker" in navigator));
    const registrations = await navigator.serviceWorker.getRegistrations();
    const conflict = registrations.find(r => r.scope === new URL("/",location.href).href && ![r.active,r.waiting,r.installing].some(w => w?.scriptURL.endsWith("/__WORKER__")));
    if (conflict) throw new Error("An existing root service worker must not be replaced");
    badge("Preparing signature-safe Chinese overlay...");
    const registration = await navigator.serviceWorker.register("/__WORKER__", {scope:"/",updateViaCache:"none"});
    await Promise.race([navigator.serviceWorker.ready,new Promise((_,reject) => setTimeout(() => reject(Error("Install timeout")),90000))]);
    const channel = new MessageChannel();
    const status = new Promise((resolve,reject) => { channel.port1.onmessage = e => resolve(e.data); setTimeout(() => reject(Error("Status timeout")),10000); });
    registration.active.postMessage({type:"claude-zh-status"},[channel.port2]);
    const result = await status;
    if (result.count !== COUNT || result.expected !== COUNT || result.build !== BUILD || !result.compatible) throw Error("Overlay incomplete: " + JSON.stringify(result));
    console.warn(prefix + "READY " + JSON.stringify(result));
    console.warn("CLAUDE_ZH_READY:" + BUILD + ":" + COUNT);
    badge("Chinese overlay READY: " + result.count + " verified files. Official binaries can now be restored.");
  } catch (error) { console.error(prefix + "FAILED " + String(error)); badge("Chinese overlay FAILED: " + String(error)); }
})();
