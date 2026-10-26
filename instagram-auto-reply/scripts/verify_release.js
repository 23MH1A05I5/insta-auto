#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// Release verification CLI for in-app APK updates.
//
// 1) Hash a freshly built APK (prints SHA-256 + size):
//      node scripts/verify_release.js --apk ../frontend/build/app/outputs/flutter-apk/app-release.apk
//
// 2) Verify an uploaded APK BEFORE publishing metadata (downloads it from the
//    public URL, compares with the local file and validates the metadata):
//      node scripts/verify_release.js \
//        --apk ../frontend/build/app/outputs/flutter-apk/app-release.apk \
//        --url https://downloads.example.com/releases/instauto-1.0.1-2.apk \
//        --host downloads.example.com --version 1.0.1 --version-code 2
//
// 3) Verify what is currently configured in the environment (.env / Render shell):
//      node scripts/verify_release.js --env
//
// Exit code 0 = everything verified, 1 = a problem was found.
// This script never needs, reads, or prints storage credentials.
// ════════════════════════════════════════════════════════════════════════════
require("dotenv").config({ quiet: true });
const fs = require("fs");
const path = require("path");
const { loadReleaseConfig } = require("../config/appRelease");
const { verifyRemoteApk, sha256File, ZIP_MAGIC } = require("../services/releaseVerifier");

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) args[key] = true;
    else { args[key] = next; i++; }
  }
  return args;
}

function fail(msg) {
  console.error(`❌ ${msg}`);
  process.exitCode = 1;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  let localHash = null;
  let localSize = null;

  if (typeof args.apk === "string") {
    const apkPath = path.resolve(args.apk);
    if (!fs.existsSync(apkPath)) return fail(`APK not found: ${apkPath}`);
    const stat = fs.statSync(apkPath);
    if (stat.size === 0) return fail("APK file is empty");
    const fd = fs.openSync(apkPath, "r");
    const head = Buffer.alloc(4);
    fs.readSync(fd, head, 0, 4, 0);
    fs.closeSync(fd);
    if (!head.equals(ZIP_MAGIC)) return fail("File is not a ZIP/APK archive");
    localHash = await sha256File(apkPath);
    localSize = stat.size;
    console.log(`📦 Local APK : ${apkPath}`);
    console.log(`   Size      : ${localSize} bytes`);
    console.log(`   SHA-256   : ${localHash}`);
  }

  let env;
  if (args.env) {
    env = process.env;
  } else if (typeof args.url === "string") {
    env = {
      APP_VERSION: args.version,
      APP_VERSION_CODE: args["version-code"],
      APK_PUBLIC_URL: args.url,
      APK_SHA256: args.sha256 || localHash || "",
      APK_ALLOWED_HOST: args.host || (() => { try { return new URL(args.url).hostname; } catch (_) { return ""; } })(),
      APK_SIZE_BYTES: localSize ? String(localSize) : "",
    };
  } else {
    if (!localHash) {
      console.log("Usage: see header of scripts/verify_release.js");
      process.exitCode = 1;
    }
    return;
  }

  const cfg = loadReleaseConfig(env);
  if (!cfg.ok) {
    cfg.errors.forEach((e) => console.error(`   • ${e}`));
    return fail(`Release metadata is ${cfg.reason === "not_configured" ? "not configured" : "invalid"}`);
  }
  if (localHash && localHash !== cfg.release.sha256) {
    return fail("Local APK SHA-256 does not match the configured APK_SHA256");
  }

  console.log(`🌐 Downloading ${cfg.release.apkUrl} to verify…`);
  const report = await verifyRemoteApk(cfg.release, { hash: true });
  console.log(`   HTTP ${report.checks.status}, content-type "${report.checks.contentType}", ${report.checks.downloadedBytes ?? "?"} bytes`);
  console.log(`   Remote SHA-256: ${report.checks.sha256 ?? "n/a"}`);
  if (!report.ok) {
    report.problems.forEach((p) => console.error(`   • ${p}`));
    return fail("Remote APK verification FAILED — do NOT publish this metadata");
  }

  console.log("✅ Remote APK verified. Publish these Render environment variables:");
  console.log(`   APP_VERSION=${cfg.release.version}`);
  console.log(`   APP_VERSION_CODE=${cfg.release.versionCode}`);
  console.log(`   APK_PUBLIC_URL=${cfg.release.apkUrl}`);
  console.log(`   APK_SHA256=${cfg.release.sha256}`);
  console.log(`   APK_ALLOWED_HOST=${cfg.release.allowedHosts.join(",")}`);
  if (cfg.release.sizeBytes) console.log(`   APK_SIZE_BYTES=${cfg.release.sizeBytes}`);
}

main().catch((e) => fail(e.message));
