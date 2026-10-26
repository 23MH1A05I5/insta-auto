// ════════════════════════════════════════════════════════════════════════════
// GET /api/app-update            — public release metadata for in-app updates
// GET /api/app-update/health     — release configuration validation (admin)
//
// The endpoint is intentionally unauthenticated: logged-out users must also be
// able to update. It exposes ONLY public download metadata — never storage
// credentials.
// ════════════════════════════════════════════════════════════════════════════
const express = require("express");
const crypto = require("crypto");
const { loadReleaseConfig } = require("../config/appRelease");

const router = express.Router();

function setNoCache(res) {
  res.setHeader("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0");
  res.setHeader("Pragma", "no-cache");
  res.setHeader("Expires", "0");
  res.setHeader("Vary", "*");
}

function parseClientVersionCode(raw) {
  if (typeof raw !== "string" || !/^\d{1,10}$/.test(raw)) return null;
  const n = Number(raw);
  return Number.isSafeInteger(n) && n > 0 ? n : null;
}

/** Constant-time admin key comparison (avoids timing leaks). */
function isValidAdminKey(provided) {
  const configured = process.env.ADMIN_API_KEY;
  if (!configured || typeof provided !== "string") return false;
  const a = Buffer.from(provided);
  const b = Buffer.from(configured);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

router.get("/", (req, res) => {
  setNoCache(res);
  const result = loadReleaseConfig(process.env);

  if (!result.ok) {
    if (result.reason === "not_configured") {
      return res.status(503).json({
        ok: false,
        error: "update_not_configured",
        message: "No app release has been published yet.",
      });
    }
    // Do not echo detailed config problems to the public; log them server-side.
    console.error("[AppUpdate] Invalid release configuration:", result.errors.join("; "));
    return res.status(500).json({
      ok: false,
      error: "invalid_release_config",
      message: "Release metadata is misconfigured on the server.",
    });
  }

  const r = result.release;
  const currentVersionCode = parseClientVersionCode(req.query.currentVersionCode);
  const belowMinimum =
    currentVersionCode !== null &&
    r.minSupportedVersionCode !== null &&
    currentVersionCode < r.minSupportedVersionCode;

  const body = {
    ok: true,
    version: r.version,
    versionCode: r.versionCode,
    apkUrl: r.apkUrl,
    sha256: r.sha256,
    mandatory: r.mandatory || belowMinimum,
    releaseNotes: r.releaseNotes,
    allowedHosts: r.allowedHosts,
  };
  if (r.minSupportedVersionCode !== null) body.minSupportedVersionCode = r.minSupportedVersionCode;
  if (r.sizeBytes !== null) body.sizeBytes = r.sizeBytes;
  if (currentVersionCode !== null) body.updateAvailable = r.versionCode > currentVersionCode;

  return res.json(body);
});

/**
 * Release validation procedure. Requires the X-Admin-Key header (ADMIN_API_KEY).
 * With ?remote=1 it also performs a HEAD/GET probe of the APK URL to confirm it
 * serves an APK (not an HTML page) and, with ?hash=1, downloads it and compares
 * the SHA-256 with APK_SHA256.
 */
router.get("/health", async (req, res) => {
  setNoCache(res);
  if (!isValidAdminKey(req.headers["x-admin-key"])) {
    return res.status(403).json({ ok: false, error: "forbidden" });
  }

  const result = loadReleaseConfig(process.env);
  if (!result.ok) {
    return res.status(result.reason === "not_configured" ? 503 : 500).json({
      ok: false,
      configValid: false,
      reason: result.reason,
      errors: result.errors,
    });
  }

  const report = { ok: true, configValid: true, version: result.release.version, versionCode: result.release.versionCode };

  if (req.query.remote === "1") {
    try {
      const { verifyRemoteApk } = require("../services/releaseVerifier");
      report.remote = await verifyRemoteApk(result.release, { hash: req.query.hash === "1" });
      report.ok = report.remote.ok;
    } catch (e) {
      report.ok = false;
      report.remote = { ok: false, error: e.message };
    }
  }

  return res.status(report.ok ? 200 : 502).json(report);
});

module.exports = router;
