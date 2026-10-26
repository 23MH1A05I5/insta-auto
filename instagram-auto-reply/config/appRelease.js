// ════════════════════════════════════════════════════════════════════════════
// In-app APK update — release metadata loader & validator
//
// Release metadata is read from environment variables at request time so that
// publishing a new version only requires updating the Render environment
// (which also restarts the service). Nothing here is a secret: these values are
// public download metadata. Storage WRITE credentials (R2 access keys) must
// never be placed in these variables or sent to the app.
//
// Required:
//   APP_VERSION        Human readable version name, e.g. "1.0.1"
//   APP_VERSION_CODE   Android versionCode (positive integer, strictly increasing)
//   APK_PUBLIC_URL     HTTPS URL of the signed release APK (immutable object key recommended)
//   APK_SHA256         SHA-256 (hex, 64 chars) of the EXACT uploaded APK bytes
//   APK_ALLOWED_HOST   Trusted download hostname(s), comma separated (e.g. "downloads.example.com")
//
// Optional:
//   APP_UPDATE_MANDATORY            "true" | "false" (default "false")
//   APP_MIN_SUPPORTED_VERSION_CODE  Installed versionCodes below this are forced to update
//   APP_RELEASE_NOTES               Plain text release notes ("\n" sequences become newlines)
//   APK_SIZE_BYTES                  Exact APK size in bytes (lets clients pre-check storage)
// ════════════════════════════════════════════════════════════════════════════

const ANDROID_MAX_VERSION_CODE = 2100000000; // Google/Android documented upper bound
const MAX_RELEASE_NOTES_LENGTH = 4000;
const MAX_APK_SIZE_BYTES = 512 * 1024 * 1024;

const REQUIRED_VARS = [
  "APP_VERSION",
  "APP_VERSION_CODE",
  "APK_PUBLIC_URL",
  "APK_SHA256",
  "APK_ALLOWED_HOST",
];

const VERSION_NAME_RE = /^\d{1,4}\.\d{1,4}\.\d{1,4}(?:[-+][0-9A-Za-z.-]{1,32})?$/;
const SHA256_RE = /^[a-f0-9]{64}$/;
const HOSTNAME_RE = /^(?=.{1,253}$)(?!-)[a-z0-9-]{1,63}(?<!-)(?:\.(?!-)[a-z0-9-]{1,63}(?<!-))+$/;

function clean(value) {
  return typeof value === "string" ? value.trim() : "";
}

/** Parses the comma-separated APK_ALLOWED_HOST list into normalized hostnames. */
function parseAllowedHosts(raw) {
  return clean(raw)
    .split(",")
    .map((h) => h.trim().toLowerCase())
    .filter(Boolean);
}

/** Rejects obvious placeholders such as "000…0" or "aaaa…a". */
function isPlaceholderHash(hash) {
  return /^(.)\1+$/.test(hash);
}

/**
 * Validates an APK download URL against the trusted host list.
 * Returns null when valid or an error string.
 */
function validateApkUrl(rawUrl, allowedHosts) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch (_) {
    return "APK_PUBLIC_URL is not a valid absolute URL";
  }
  if (url.protocol !== "https:") return "APK_PUBLIC_URL must use https://";
  if (url.username || url.password) return "APK_PUBLIC_URL must not contain credentials";
  if (url.port && url.port !== "443") return "APK_PUBLIC_URL must use the default HTTPS port";
  if (url.hash) return "APK_PUBLIC_URL must not contain a fragment";
  const host = url.hostname.toLowerCase();
  if (!allowedHosts.includes(host)) {
    return `APK_PUBLIC_URL host "${host}" is not listed in APK_ALLOWED_HOST`;
  }
  if (!/\.apk$/i.test(url.pathname)) return "APK_PUBLIC_URL path must end with .apk";
  // Presigned URLs expire and would leak signing material into clients.
  const sp = url.searchParams;
  if (sp.has("X-Amz-Signature") || sp.has("X-Amz-Credential") || sp.has("Signature")) {
    return "APK_PUBLIC_URL must be a public URL, not a presigned URL";
  }
  return null;
}

/**
 * Loads and validates release metadata from the given environment object.
 *
 * @returns {{ ok: true, release: object } |
 *           { ok: false, reason: "not_configured" | "invalid", errors: string[] }}
 */
function loadReleaseConfig(env = process.env) {
  const missing = REQUIRED_VARS.filter((key) => !clean(env[key]));
  if (missing.length === REQUIRED_VARS.length) {
    return { ok: false, reason: "not_configured", errors: ["No release has been published"] };
  }
  if (missing.length > 0) {
    return {
      ok: false,
      reason: "invalid",
      errors: missing.map((key) => `${key} is not set`),
    };
  }

  const errors = [];

  const version = clean(env.APP_VERSION);
  if (!VERSION_NAME_RE.test(version)) {
    errors.push("APP_VERSION must look like MAJOR.MINOR.PATCH (e.g. 1.0.1)");
  }

  const versionCodeRaw = clean(env.APP_VERSION_CODE);
  const versionCode = /^\d+$/.test(versionCodeRaw) ? Number(versionCodeRaw) : NaN;
  if (!Number.isSafeInteger(versionCode) || versionCode < 1 || versionCode > ANDROID_MAX_VERSION_CODE) {
    errors.push(`APP_VERSION_CODE must be an integer between 1 and ${ANDROID_MAX_VERSION_CODE}`);
  }

  const allowedHosts = parseAllowedHosts(env.APK_ALLOWED_HOST);
  const badHosts = allowedHosts.filter((h) => !HOSTNAME_RE.test(h));
  if (allowedHosts.length === 0 || badHosts.length > 0) {
    errors.push("APK_ALLOWED_HOST must be one or more bare hostnames (no scheme, path or port)");
  }

  const apkUrl = clean(env.APK_PUBLIC_URL);
  const urlError = validateApkUrl(apkUrl, allowedHosts);
  if (urlError) errors.push(urlError);

  const sha256 = clean(env.APK_SHA256).toLowerCase();
  if (!SHA256_RE.test(sha256)) {
    errors.push("APK_SHA256 must be a 64-character hexadecimal SHA-256 digest");
  } else if (isPlaceholderHash(sha256)) {
    errors.push("APK_SHA256 looks like a placeholder, not a real digest");
  }

  const mandatoryRaw = clean(env.APP_UPDATE_MANDATORY).toLowerCase();
  if (mandatoryRaw && mandatoryRaw !== "true" && mandatoryRaw !== "false") {
    errors.push('APP_UPDATE_MANDATORY must be "true" or "false"');
  }
  const mandatory = mandatoryRaw === "true";

  let minSupportedVersionCode = null;
  const minRaw = clean(env.APP_MIN_SUPPORTED_VERSION_CODE);
  if (minRaw) {
    const min = /^\d+$/.test(minRaw) ? Number(minRaw) : NaN;
    if (!Number.isSafeInteger(min) || min < 1 || (Number.isSafeInteger(versionCode) && min > versionCode)) {
      errors.push("APP_MIN_SUPPORTED_VERSION_CODE must be an integer between 1 and APP_VERSION_CODE");
    } else {
      minSupportedVersionCode = min;
    }
  }

  let sizeBytes = null;
  const sizeRaw = clean(env.APK_SIZE_BYTES);
  if (sizeRaw) {
    const size = /^\d+$/.test(sizeRaw) ? Number(sizeRaw) : NaN;
    if (!Number.isSafeInteger(size) || size < 1 || size > MAX_APK_SIZE_BYTES) {
      errors.push(`APK_SIZE_BYTES must be an integer between 1 and ${MAX_APK_SIZE_BYTES}`);
    } else {
      sizeBytes = size;
    }
  }

  const releaseNotes = clean(env.APP_RELEASE_NOTES)
    .replace(/\\n/g, "\n")
    .slice(0, MAX_RELEASE_NOTES_LENGTH);

  if (errors.length > 0) {
    return { ok: false, reason: "invalid", errors };
  }

  return {
    ok: true,
    release: {
      version,
      versionCode,
      apkUrl,
      sha256,
      mandatory,
      minSupportedVersionCode,
      releaseNotes: releaseNotes || "Bug fixes and performance improvements",
      sizeBytes,
      allowedHosts,
    },
  };
}

module.exports = {
  loadReleaseConfig,
  validateApkUrl,
  parseAllowedHosts,
  REQUIRED_VARS,
  ANDROID_MAX_VERSION_CODE,
  MAX_APK_SIZE_BYTES,
};
