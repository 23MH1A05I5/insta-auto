const dns = require("dns");
dns.setServers(["8.8.8.8", "1.1.1.1"]);
require("dotenv").config();
const mongoose = require("mongoose");
const ReconciliationService = require("../services/reconciliationService");

async function run() {
  const isDryRun = process.argv.includes("--dry-run") || !process.argv.includes("--execute");

  const mongoUri = process.env.MONGO_URI || "mongodb://127.0.0.1:27017/instauto";
  console.log(`Connecting to MongoDB...`);
  await mongoose.connect(mongoUri);
  console.log(`Connected. Running Action Ledger Reconciliation [dryRun: ${isDryRun}]...\n`);

  const report = await ReconciliationService.reconcile({ dryRun: isDryRun });

  console.log("════════════════════════════════════════════════════════════════");
  console.log(`  Action Ledger Reconciliation Report ${isDryRun ? "(DRY RUN)" : "(APPLIED)"}`);
  console.log("════════════════════════════════════════════════════════════════");
  console.log(`  Automations Scanned:       ${report.automationsScanned}`);
  console.log(`  Activity Entries Scanned:  ${report.activityEntriesScanned}`);
  console.log(`  Backfill Jobs Scanned:     ${report.backfillJobsScanned}`);
  console.log(`  Backfill Actions Scanned:  ${report.backfillActionsScanned}`);
  console.log(`  Public Replies Reconciled: ${report.reconciledPublicReplies}`);
  console.log(`  DMs Reconciled:            ${report.reconciledDms}`);
  console.log(`  Already Existing In Ledger:${report.alreadyExistingInLedger}`);
  console.log(`  Ambiguous Entries Skipped: ${report.ambiguousEntriesSkipped}`);
  console.log(`  Duration:                  ${report.durationMs}ms`);
  console.log("════════════════════════════════════════════════════════════════\n");

  if (isDryRun) {
    console.log("ℹ️  Run with `node scripts/reconcile_action_ledger.js --execute` to apply to database.");
  } else {
    console.log("✅ Reconciliation successfully applied to MongoDB ActionLedger collection.");
  }

  await mongoose.disconnect();
}

run().catch((err) => {
  console.error("❌ Reconciliation error:", err);
  process.exit(1);
});
