{{flutter_js}}
{{flutter_build_config}}

// Online rooms must load the current client rather than an old offline shell.
async function removeLegacyFlutterWorker() {
  if (!('serviceWorker' in navigator)) return;
  const expected = new URL('flutter_service_worker.js', document.baseURI);
  for (const registration of await navigator.serviceWorker.getRegistrations()) {
    const worker = registration.active || registration.waiting || registration.installing;
    if (worker && new URL(worker.scriptURL).pathname === expected.pathname &&
        new URL(worker.scriptURL).origin === expected.origin) {
      await registration.unregister();
    }
  }
}
removeLegacyFlutterWorker().catch(() => {}).finally(() => _flutter.loader.load());
