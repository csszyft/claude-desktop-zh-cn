// Run only in Claude's app://localhost page, using its supported developer tools.
(async () => {
  if (location.protocol !== "app:" || location.hostname !== "localhost") {
    throw new Error("Select the app://localhost page first");
  }
  const ownedWorker = /^app:\/\/localhost\/claude-zh-overlay-(?:[a-f0-9]{32}|4-29-v1)\.js$/;
  const ownedCache = /^claude-zh-static-(?:[a-f0-9]{32}|4\.29-v1)$/;
  for (const registration of await navigator.serviceWorker.getRegistrations()) {
    if ([registration.active, registration.waiting, registration.installing].some(worker => worker && ownedWorker.test(worker.scriptURL))) {
      await registration.unregister();
    }
  }
  for (const name of await caches.keys()) {
    if (ownedCache.test(name)) await caches.delete(name);
  }
  console.log("Claude Chinese overlay removed. Reload this page to use original resources.");
})();
