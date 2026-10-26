// Tests for the in-app APK update endpoint, release config validation and
// remote release verification. No database or network access is required.
const { describe, it, beforeEach, afterEach } = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("crypto");
const express = require("express");
const http = require("http");

const { loadReleaseConfig, validateApkUrl } = require("../config/appRelease");
const { verifyRemoteApk, fetchTrusted } = require("../services/releaseVerifier");
const appUpdateRouter = require("../routes/appUpdate");

// A real digest of real bytes — not a placeholder.
const FAKE_APK_BYTES = Buffer.concat([Buffer.from([0x50, 0x4b, 0x03, 0x04]), Buffer.from("instauto-test-apk-payload")]);
const FAKE_APK_SHA = crypto.createHash("sha256").update(FAKE_APK_BYTES).digest("hex");

const RELEASE_KEYS = [
  "APP_VERSION", "APP_VERSION_CODE", "APK_PUBLIC_URL", "APK_SHA256", "APK_ALLOWED_HOST",
  "APP_UPDATE_MANDATORY", "APP_MIN_SUPPORTED_VERSION_CODE", "APP_RELEASE_NOTES", "APK_SIZE_BYTES", "ADMIN_API_KEY",
];

function validEnv(overrides = {}) {
  return {
    APP_VERSION: "1.0.1",
    APP_VERSION_CODE: "2",
    APK_PUBLIC_URL: "https://downloads.example.com/releases/instauto-1.0.1-2.apk",
    APK_SHA256: FAKE_APK_SHA,
    APK_ALLOWED_HOST: "downloads.example.com",
    APP_RELEASE_NOTES: "Fixes\\nImprovements",
    ...overrides,
  };
}

function request(app, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const server = http.createServer(app);
    server.listen(0, () => {
      const req = http.request(
        { host: "127.0.0.1", port: server.address().port, method: "GET", path, headers },
        (res) => {
          let data = "";
          res.on("data", (c) => (data += c));
          res.on("end", () => {
            server.close();
            let body = data;
            try { body = JSON.parse(data); } catch (_) {}
            resolve({ status: res.statusCode, headers: res.headers, body });
          });
        }
      );
      req.on("error", (e) => { server.close(); reject(e); });
      req.end();
    });
  });
}

describe("In-app APK update — release config validation", () => {
  it("accepts a complete, valid configuration", () => {
    const r = loadReleaseConfig(validEnv());
    assert.equal(r.ok, true);
    assert.equal(r.release.versionCode, 2);
    assert.equal(r.release.sha256, FAKE_APK_SHA);
    assert.equal(r.release.mandatory, false);
    assert.equal(r.release.releaseNotes, "Fixes\nImprovements");
  });

  it("reports not_configured when no release variables exist", () => {
    const r = loadReleaseConfig({});
    assert.equal(r.ok, false);
    assert.equal(r.reason, "not_configured");
  });

  it("reports missing individual variables as invalid", () => {
    const env = validEnv();
    delete env.APK_SHA256;
    const r = loadReleaseConfig(env);
    assert.equal(r.reason, "invalid");
    assert.ok(r.errors.some((e) => e.includes("APK_SHA256")));
  });

  for (const [label, overrides, needle] of [
    ["non-integer version code", { APP_VERSION_CODE: "2.5" }, "APP_VERSION_CODE"],
    ["zero version code", { APP_VERSION_CODE: "0" }, "APP_VERSION_CODE"],
    ["version code above Android max", { APP_VERSION_CODE: "2100000001" }, "APP_VERSION_CODE"],
    ["malformed version name", { APP_VERSION: "v1" }, "APP_VERSION"],
    ["short checksum", { APK_SHA256: "abc123" }, "APK_SHA256"],
    ["placeholder checksum", { APK_SHA256: "0".repeat(64) }, "placeholder"],
    ["non-hex checksum", { APK_SHA256: "z".repeat(64) }, "APK_SHA256"],
    ["http URL", { APK_PUBLIC_URL: "http://downloads.example.com/a.apk" }, "https"],
    ["untrusted host", { APK_PUBLIC_URL: "https://evil.example.net/a.apk" }, "not listed"],
    ["look-alike host", { APK_PUBLIC_URL: "https://downloads.example.com.evil.net/a.apk" }, "not listed"],
    ["credentials in URL", { APK_PUBLIC_URL: "https://u:p@downloads.example.com/a.apk" }, "credentials"],
    ["non-APK path", { APK_PUBLIC_URL: "https://downloads.example.com/index.html" }, ".apk"],
    ["presigned URL", { APK_PUBLIC_URL: "https://downloads.example.com/a.apk?X-Amz-Signature=abc" }, "presigned"],
    ["allowed host with scheme", { APK_ALLOWED_HOST: "https://downloads.example.com" }, "APK_ALLOWED_HOST"],
    ["bad mandatory flag", { APP_UPDATE_MANDATORY: "yes" }, "APP_UPDATE_MANDATORY"],
    ["min supported above latest", { APP_MIN_SUPPORTED_VERSION_CODE: "5" }, "APP_MIN_SUPPORTED_VERSION_CODE"],
  ]) {
    it(`rejects ${label}`, () => {
      const r = loadReleaseConfig(validEnv(overrides));
      assert.equal(r.ok, false, `expected ${label} to be rejected`);
      assert.ok(r.errors.some((e) => e.includes(needle)), `errors: ${r.errors.join(" | ")}`);
    });
  }

  it("normalizes upper-case checksums to lower-case", () => {
    const r = loadReleaseConfig(validEnv({ APK_SHA256: FAKE_APK_SHA.toUpperCase() }));
    assert.equal(r.ok, true);
    assert.equal(r.release.sha256, FAKE_APK_SHA);
  });

  it("validateApkUrl rejects garbage", () => {
    assert.ok(validateApkUrl("not a url", ["a.com"]));
  });
});

describe("In-app APK update — GET /api/app-update", () => {
  let saved;
  let app;

  beforeEach(() => {
    saved = {};
    for (const k of RELEASE_KEYS) { saved[k] = process.env[k]; delete process.env[k]; }
    app = express();
    app.use("/api/app-update", appUpdateRouter);
  });

  afterEach(() => {
    for (const k of RELEASE_KEYS) {
      if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k];
    }
  });

  it("returns 503 update_not_configured when no release exists", async () => {
    const res = await request(app, "/api/app-update");
    assert.equal(res.status, 503);
    assert.equal(res.body.error, "update_not_configured");
    assert.match(res.headers["cache-control"], /no-store/);
  });

  it("returns 500 without leaking details when configuration is invalid", async () => {
    Object.assign(process.env, validEnv({ APK_PUBLIC_URL: "http://evil.example.net/x.apk" }));
    const origError = console.error;
    console.error = () => {};
    try {
      const res = await request(app, "/api/app-update");
      assert.equal(res.status, 500);
      assert.equal(res.body.error, "invalid_release_config");
      assert.ok(!JSON.stringify(res.body).includes("evil.example.net"));
    } finally {
      console.error = origError;
    }
  });

  it("returns validated metadata with no-cache headers", async () => {
    Object.assign(process.env, validEnv());
    const res = await request(app, "/api/app-update");
    assert.equal(res.status, 200);
    assert.equal(res.body.version, "1.0.1");
    assert.equal(res.body.versionCode, 2);
    assert.equal(res.body.sha256, FAKE_APK_SHA);
    assert.equal(res.body.mandatory, false);
    assert.deepEqual(res.body.allowedHosts, ["downloads.example.com"]);
    assert.match(res.headers["cache-control"], /no-store/);
    assert.equal(res.headers["pragma"], "no-cache");
  });

  it("reports updateAvailable relative to the client version code", async () => {
    Object.assign(process.env, validEnv());
    assert.equal((await request(app, "/api/app-update?currentVersionCode=1")).body.updateAvailable, true);
    assert.equal((await request(app, "/api/app-update?currentVersionCode=2")).body.updateAvailable, false);
    assert.equal((await request(app, "/api/app-update?currentVersionCode=abc")).body.updateAvailable, undefined);
  });

  it("forces mandatory for clients below the minimum supported version", async () => {
    Object.assign(process.env, validEnv({ APP_VERSION_CODE: "5", APP_MIN_SUPPORTED_VERSION_CODE: "3" }));
    assert.equal((await request(app, "/api/app-update?currentVersionCode=2")).body.mandatory, true);
    assert.equal((await request(app, "/api/app-update?currentVersionCode=4")).body.mandatory, false);
  });

  it("never exposes storage credentials even if present in the environment", async () => {
    Object.assign(process.env, validEnv());
    process.env.R2_SECRET_ACCESS_KEY = "super-secret-value";
    try {
      const res = await request(app, "/api/app-update");
      assert.ok(!JSON.stringify(res.body).includes("super-secret-value"));
    } finally {
      delete process.env.R2_SECRET_ACCESS_KEY;
    }
  });

  it("protects /health with ADMIN_API_KEY", async () => {
    Object.assign(process.env, validEnv());
    assert.equal((await request(app, "/api/app-update/health")).status, 403);
    process.env.ADMIN_API_KEY = "admin-key-123";
    assert.equal((await request(app, "/api/app-update/health", { "x-admin-key": "wrong" })).status, 403);
    const ok = await request(app, "/api/app-update/health", { "x-admin-key": "admin-key-123" });
    assert.equal(ok.status, 200);
    assert.equal(ok.body.configValid, true);
  });

  it("/health reports configuration errors to admins", async () => {
    Object.assign(process.env, validEnv({ APK_SHA256: "bad" }));
    process.env.ADMIN_API_KEY = "admin-key-123";
    const res = await request(app, "/api/app-update/health", { "x-admin-key": "admin-key-123" });
    assert.equal(res.status, 500);
    assert.ok(res.body.errors.some((e) => e.includes("APK_SHA256")));
  });
});

describe("In-app APK update — remote release verification", () => {
  const release = loadReleaseConfig(validEnv()).release;

  function mockFetch(routes) {
    return async (url) => {
      const handler = routes[url];
      if (!handler) throw new Error(`unexpected fetch ${url}`);
      return handler();
    };
  }

  it("passes when the URL serves the exact APK bytes", async () => {
    const report = await verifyRemoteApk(release, {
      hash: true,
      fetchImpl: mockFetch({
        [release.apkUrl]: () => new Response(FAKE_APK_BYTES, {
          status: 200,
          headers: { "content-type": "application/vnd.android.package-archive", "content-length": String(FAKE_APK_BYTES.length) },
        }),
      }),
    });
    assert.equal(report.ok, true, report.problems.join("; "));
    assert.equal(report.checks.sha256Matches, true);
  });

  it("fails when the URL serves an HTML landing page", async () => {
    const report = await verifyRemoteApk(release, {
      hash: true,
      fetchImpl: mockFetch({
        [release.apkUrl]: () => new Response("<html>Download</html>", { status: 200, headers: { "content-type": "text/html" } }),
      }),
    });
    assert.equal(report.ok, false);
    assert.ok(report.problems.some((p) => p.includes("HTML")));
    assert.equal(report.checks.sha256Matches, false);
  });

  it("fails on checksum mismatch", async () => {
    const corrupt = Buffer.concat([FAKE_APK_BYTES, Buffer.from("x")]);
    const report = await verifyRemoteApk(release, {
      hash: true,
      fetchImpl: mockFetch({ [release.apkUrl]: () => new Response(corrupt, { status: 200 }) }),
    });
    assert.equal(report.ok, false);
    assert.ok(report.problems.some((p) => p.includes("SHA-256")));
  });

  it("refuses redirects to untrusted hosts", async () => {
    const fetchImpl = mockFetch({
      [release.apkUrl]: () => new Response(null, { status: 302, headers: { location: "https://evil.example.net/x.apk" } }),
    });
    await assert.rejects(() => fetchTrusted(release.apkUrl, release.allowedHosts, {}, fetchImpl), /untrusted host/);
  });

  it("refuses redirects that downgrade to HTTP", async () => {
    const fetchImpl = mockFetch({
      [release.apkUrl]: () => new Response(null, { status: 302, headers: { location: "http://downloads.example.com/x.apk" } }),
    });
    await assert.rejects(() => fetchTrusted(release.apkUrl, release.allowedHosts, {}, fetchImpl), /non-HTTPS/);
  });
});
