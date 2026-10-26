// ════════════════════════════════════════════════════════════════════════════
// Release verifier — confirms that the published APK URL actually serves the
// APK described by the release metadata. Used by:
//   • GET /api/app-update/health?remote=1[&hash=1]   (admin only)
//   • scripts/verify_release.js                       (release CLI)
// ════════════════════════════════════════════════════════════════════════════
const crypto = require("crypto");
const fs = require("fs");

const MAX_REDIRECTS = 3;
const ZIP_MAGIC = Buffer.from([0x50, 0x4b, 0x03, 0x04]); // APKs are ZIP archives

/** SHA-256 of a local file, streamed (never loads the whole APK in memory). */
function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash("sha256");
    fs.createReadStream(filePath)
      .on("error", reject)
      .on("data", (chunk) => hash.update(chunk))
      .on("end", () => resolve(hash.digest("hex")));
  });
}

/**
 * Fetches a URL following at most MAX_REDIRECTS redirects, each of which must
 * stay on HTTPS and on an allowed host.
 */
async function fetchTrusted(url, allowedHosts, init = {}, fetchImpl = fetch) {
  let current = url;
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    const parsed = new URL(current);
    if (parsed.protocol !== "https:") throw new Error(`Refusing non-HTTPS URL: ${parsed.origin}`);
    if (!allowedHosts.includes(parsed.hostname.toLowerCase())) {
      throw new Error(`Refusing untrusted host: ${parsed.hostname}`);
    }
    const res = await fetchImpl(current, { ...init, redirect: "manual" });
    if (res.status >= 300 && res.status < 400 && res.headers.get("location")) {
      current = new URL(res.headers.get("location"), current).toString();
      continue;
    }
    return res;
  }
  throw new Error("Too many redirects");
}

/**
 * @param {object} release  validated release from loadReleaseConfig()
 * @param {{hash?: boolean, fetchImpl?: Function}} opts
 */
async function verifyRemoteApk(release, opts = {}) {
  const fetchImpl = opts.fetchImpl || fetch;
  const report = { ok: false, url: release.apkUrl, checks: {} };

  const res = await fetchTrusted(
    release.apkUrl,
    release.allowedHosts,
    { method: opts.hash ? "GET" : "HEAD", headers: { "Cache-Control": "no-cache" } },
    fetchImpl
  );

  report.checks.status = res.status;
  const contentType = (res.headers.get("content-type") || "").toLowerCase();
  report.checks.contentType = contentType;
  const contentLength = Number(res.headers.get("content-length") || 0) || null;
  report.checks.contentLength = contentLength;

  const problems = [];
  if (res.status !== 200) problems.push(`Expected HTTP 200, got ${res.status}`);
  if (contentType.includes("text/html")) problems.push("URL serves an HTML page, not an APK");
  if (release.sizeBytes && contentLength && contentLength !== release.sizeBytes) {
    problems.push(`Content-Length ${contentLength} != APK_SIZE_BYTES ${release.sizeBytes}`);
  }

  if (opts.hash && res.status === 200 && res.body) {
    const hash = crypto.createHash("sha256");
    let size = 0;
    let head = Buffer.alloc(0);
    for await (const chunk of res.body) {
      const buf = Buffer.from(chunk);
      if (head.length < 4) head = Buffer.concat([head, buf.subarray(0, 4 - head.length)]);
      hash.update(buf);
      size += buf.length;
    }
    const digest = hash.digest("hex");
    report.checks.downloadedBytes = size;
    report.checks.sha256 = digest;
    report.checks.sha256Matches = digest === release.sha256;
    report.checks.zipMagic = head.equals(ZIP_MAGIC);
    if (!report.checks.zipMagic) problems.push("Downloaded file is not a ZIP/APK archive");
    if (!report.checks.sha256Matches) problems.push("Downloaded SHA-256 does not match APK_SHA256");
    if (release.sizeBytes && size !== release.sizeBytes) problems.push("Downloaded size != APK_SIZE_BYTES");
  } else if (res.body && typeof res.body.cancel === "function") {
    try { await res.body.cancel(); } catch (_) {}
  }

  report.problems = problems;
  report.ok = problems.length === 0;
  return report;
}

module.exports = { verifyRemoteApk, fetchTrusted, sha256File, ZIP_MAGIC };
