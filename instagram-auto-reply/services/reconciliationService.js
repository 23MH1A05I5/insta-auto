const mongoose = require("mongoose");
const Automation = require("../models/Automation");
const BackfillJob = require("../models/BackfillJob");
const ActionLedger = require("../models/ActionLedger");
const ActionLedgerService = require("./actionLedgerService");

class ReconciliationService {
  /**
   * Reconcile legacy activity logs and backfill jobs into the authoritative ActionLedger
   * Safe, repeatable, and idempotent.
   * High performance bulk batching.
   */
  static async reconcile({ dryRun = true } = {}) {
    const report = {
      dryRun,
      startedAt: new Date(),
      automationsScanned: 0,
      activityEntriesScanned: 0,
      backfillJobsScanned: 0,
      backfillActionsScanned: 0,
      reconciledPublicReplies: 0,
      reconciledDms: 0,
      alreadyExistingInLedger: 0,
      ambiguousEntriesSkipped: 0,
      errors: [],
    };

    // 0. Pre-load all existing actionKeys into memory for instant O(1) deduplication
    const existingLedgerRecords = await ActionLedger.find({}, { actionKey: 1 }).lean();
    const existingKeys = new Set(existingLedgerRecords.map((r) => r.actionKey));
    const pendingInserts = [];

    // ── 1. Reconcile from Automation.activityLog ─────────────────────────────
    const automations = await Automation.find({}).lean();
    report.automationsScanned = automations.length;

    for (const auto of automations) {
      const igUserId = auto.igUserId || "default";
      const cleanMediaId = String(auto.mediaId || "").trim().split("_").pop();
      const logs = auto.activityLog || [];

      for (const entry of logs) {
        report.activityEntriesScanned++;
        const commentId = entry.commentId ? String(entry.commentId) : null;
        if (!commentId) {
          report.ambiguousEntriesSkipped++;
          continue;
        }

        const username = entry.username || "unknown";
        const recipientId = entry.from?.id ? String(entry.from.id) : null;
        const entryDate = entry.timestamp ? new Date(entry.timestamp) : new Date();

        // 1a. Reconcile Public Reply
        const pubSent = Boolean(entry.publicReply?.sent || entry.publicReply?.status === "sent");
        if (pubSent) {
          const actionKey = ActionLedgerService.buildActionKey({
            igUserId,
            mediaId: cleanMediaId,
            commentId,
            actionType: "public_reply",
          });

          if (existingKeys.has(actionKey)) {
            report.alreadyExistingInLedger++;
          } else {
            existingKeys.add(actionKey);
            report.reconciledPublicReplies++;
            pendingInserts.push({
              actionKey,
              igUserId: String(igUserId),
              mediaId: cleanMediaId,
              commentId,
              recipientId,
              username,
              actionType: "public_reply",
              status: "sent",
              messageId: entry.publicReply?.messageId || null,
              messageText: entry.publicReply?.message || "",
              automationId: auto._id,
              source: "reconciliation",
              processedAt: entry.publicReply?.lastSuccessAt || entryDate,
            });
          }
        }

        // 1b. Reconcile Private Reply (DM)
        const dmSent = Boolean(entry.privateReply?.sent || entry.privateReply?.status === "sent");
        if (dmSent) {
          const actionKey = ActionLedgerService.buildActionKey({
            igUserId,
            mediaId: cleanMediaId,
            commentId,
            actionType: "dm",
          });

          if (existingKeys.has(actionKey)) {
            report.alreadyExistingInLedger++;
          } else {
            existingKeys.add(actionKey);
            report.reconciledDms++;
            pendingInserts.push({
              actionKey,
              igUserId: String(igUserId),
              mediaId: cleanMediaId,
              commentId,
              recipientId,
              username,
              actionType: "dm",
              status: "sent",
              messageId: entry.privateReply?.messageId || null,
              messageText: entry.privateReply?.message || "",
              automationId: auto._id,
              source: "reconciliation",
              processedAt: entry.privateReply?.lastSuccessAt || entryDate,
            });
          }
        }
      }
    }

    // ── 2. Reconcile from BackfillJob.actions ─────────────────────────────────
    const jobs = await BackfillJob.find({}).lean();
    report.backfillJobsScanned = jobs.length;

    for (const job of jobs) {
      const cleanMediaId = String(job.mediaId || "").trim().split("_").pop();
      const igUserId = job.userId ? String(job.userId) : "default";

      for (const action of job.actions || []) {
        report.backfillActionsScanned++;
        const commentId = action.commentId ? String(action.commentId) : null;
        if (!commentId) {
          report.ambiguousEntriesSkipped++;
          continue;
        }

        const username = action.username || "unknown";
        const recipientId = action.recipientId ? String(action.recipientId) : null;
        const processedAt = action.processedAt ? new Date(action.processedAt) : new Date();

        // 2a. Backfill Public Reply
        if (action.publicReply?.status === "sent") {
          const actionKey = ActionLedgerService.buildActionKey({
            igUserId,
            mediaId: cleanMediaId,
            commentId,
            actionType: "public_reply",
          });

          if (existingKeys.has(actionKey)) {
            report.alreadyExistingInLedger++;
          } else {
            existingKeys.add(actionKey);
            report.reconciledPublicReplies++;
            pendingInserts.push({
              actionKey,
              igUserId: String(igUserId),
              mediaId: cleanMediaId,
              commentId,
              recipientId,
              username,
              actionType: "public_reply",
              status: "sent",
              messageId: action.publicReply?.messageId || null,
              messageText: action.publicReply?.message || "",
              automationId: job.automationId,
              jobId: job._id,
              source: "reconciliation",
              processedAt,
            });
          }
        }

        // 2b. Backfill Private Reply (DM)
        if (action.privateReply?.status === "sent") {
          const actionKey = ActionLedgerService.buildActionKey({
            igUserId,
            mediaId: cleanMediaId,
            commentId,
            actionType: "dm",
          });

          if (existingKeys.has(actionKey)) {
            report.alreadyExistingInLedger++;
          } else {
            existingKeys.add(actionKey);
            report.reconciledDms++;
            pendingInserts.push({
              actionKey,
              igUserId: String(igUserId),
              mediaId: cleanMediaId,
              commentId,
              recipientId,
              username,
              actionType: "dm",
              status: "sent",
              messageId: action.privateReply?.messageId || null,
              messageText: action.privateReply?.message || "",
              automationId: job.automationId,
              jobId: job._id,
              source: "reconciliation",
              processedAt,
            });
          }
        }
      }
    }

    // ── 3. Batch apply inserts if not dryRun ─────────────────────────────────
    if (!dryRun && pendingInserts.length > 0) {
      const ops = pendingInserts.map((doc) => ({
        updateOne: {
          filter: { actionKey: doc.actionKey },
          update: { $setOnInsert: doc },
          upsert: true,
        },
      }));

      try {
        await ActionLedger.bulkWrite(ops, { ordered: false });
      } catch (err) {
        report.errors.push(err.message);
      }
    }

    report.completedAt = new Date();
    report.durationMs = report.completedAt.getTime() - report.startedAt.getTime();
    return report;
  }
}

module.exports = ReconciliationService;
