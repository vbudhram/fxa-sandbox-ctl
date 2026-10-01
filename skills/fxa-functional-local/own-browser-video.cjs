// Preloaded by run.sh. Playwright records only the contexts its own fixtures
// make; the Sync fixtures launch their own Firefox, whose video was a blank page.
// In a test worker (forked with an IPC channel; TEST_WORKER_INDEX is set only
// later), a context with no recordVideo records into that test's folder.
if (typeof process.send === 'function') {
  try {
    const pw = require(require.resolve('@playwright/test', { paths: [process.cwd()] }));
    for (const type of [pw.firefox, pw.chromium, pw.webkit]) {
      const launch = type.launch.bind(type);
      type.launch = async (...args) => {
        const browser = await launch(...args);
        const newContext = browser.newContext.bind(browser);
        browser.newContext = (opts = {}) => {
          if (opts.recordVideo) return newContext(opts);
          let dir;
          try { dir = pw.test.info().outputPath('own-browser-video'); } catch { return newContext(opts); } // outside a test
          return newContext({ ...opts, recordVideo: { dir } });
        };
        return browser;
      };
    }
  } catch (e) {
    console.error(`own-browser-video: not recording own browsers (${e.message})`);
  }
}
