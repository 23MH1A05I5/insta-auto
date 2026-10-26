const router = require("express").Router();
const mongoose = require("mongoose");
const Automation = require("../models/Automation");
const User = require("../models/User");
const ActionLedger = require("../models/ActionLedger");
const InstagramService = require("../services/instagramService");
const ActionLedgerService = require("../services/actionLedgerService");
const { authenticate } = require("../middleware/auth");
const { MESSAGING_RULES, RETRY_RULES } = require("../config/instagramRules");

const MAX_DM_RETRIES = RETRY_RULES?.MAX_DM_RETRIES || 3;
const RETRY_LOCK_TIMEOUT_MS = RETRY_RULES?.RETRY_LOCK_TIMEOUT_MS || 60 * 1000;

// Helper to format an activity entry for JSON response
function formatActivityEntry(auto, entry) {
  const obj = entry.toObject ? entry.toObject() : { ...entry };
  const entryId = (entry._id || entry.id || entry.commentId)?.toString();

  // Normalize status for backward compatibility
  const pubStatus = obj.publicReply?.status || (obj.publicReply?.sent ? "sent" : "disabled");
  const dmStatus = obj.privateReply?.status || (obj.privateReply?.sent ? "sent" : "disabled");

  // Derive canonical top-level action status
  let canonicalStatus = "pending";
  if (pubStatus === "failed" || dmStatus === "failed" || obj.error) {
    canonicalStatus = "failed";
  } else if (pubStatus === "unknown" || dmStatus === "unknown") {
    canonicalStatus = "unknown";
  } else if (pubStatus === "reconciliation_required" || dmStatus === "reconciliation_required") {
    canonicalStatus = "reconciliation_required";
  } else if (pubStatus === "sent" || obj.publicReply?.sent || dmStatus === "sent" || obj.privateReply?.sent) {
    canonicalStatus = "sent";
  } else if (pubStatus === "skipped" && dmStatus === "skipped") {
    canonicalStatus = "skipped";
  }

  const messageId = obj.privateReply?.messageId || obj.publicReply?.messageId || null;
  const sentAt = obj.privateReply?.lastSuccessAt || obj.publicReply?.lastSuccessAt || (obj.privateReply?.sent || obj.publicReply?.sent ? obj.timestamp : null);

  return {
    _id: entryId,
    id: entryId,
    actionId: entryId,
    commentId: obj.commentId || null,
    mediaId: auto.mediaId || null,
    actionType: "dm",
    status: canonicalStatus,
    reason: obj.privateReply?.retryReason || obj.privateReply?.skipReason || obj.publicReply?.retryReason || null,
    retryable: Boolean(obj.privateReply?.retryEligible),
    messageId,
    sentAt,
    reconciliationRequired: dmStatus === "unknown" || dmStatus === "reconciliation_required" || pubStatus === "unknown",
    updatedAt: obj.timestamp || null,

    automationId: auto._id,
    automationName: auto.name,
    mediaThumbnail: auto.mediaThumbnail,
    ...obj,
    _id: entryId,
    id: entryId,
    actionId: entryId,
    publicReplySent: Boolean(obj.publicReply?.sent),
    publicReplyStatus: pubStatus,
    publicReplyMessage: obj.publicReply?.message || "",
    privateReplySent: Boolean(obj.privateReply?.sent),
    privateReplyStatus: dmStatus,
    privateReplyMessage: obj.privateReply?.message || "",
    retryEligible: Boolean(obj.privateReply?.retryEligible),
    retryReason: obj.privateReply?.retryReason || null,
    attempts: obj.privateReply?.attempts || 0,
  };
}

// ── GET /api/activity & /api/activity/:automationId ──────────────────────────
router.get(["/", "/:automationId"], authenticate, async (req, res, next) => {
  if (req.params.automationId === "summary" || req.params.automationId === "retry-all-failed") {
    return next();
  }
  try {
    const limit = Math.min(parseInt(req.query.limit || "50", 10), 200);
    const page = Math.max(parseInt(req.query.page || "1", 10), 1);
    const skip = (page - 1) * limit;

    const query = { userId: req.user._id };
    if (req.params.automationId) {
      if (mongoose.Types.ObjectId.isValid(req.params.automationId)) {
        query._id = req.params.automationId;
      } else {
        query.mediaId = req.params.automationId;
      }
    }

    // Pull activityLog entries from user automations, flatten and sort
    const automations = await Automation.find(query)
      .select("mediaId mediaThumbnail activityLog name");

    const entries = [];
    for (const auto of automations) {
      for (const entry of auto.activityLog || []) {
        entries.push(formatActivityEntry(auto, entry));
      }
    }

    // Sort by timestamp DESC
    entries.sort((a, b) => new Date(b.timestamp || 0) - new Date(a.timestamp || 0));
    const total = entries.length;
    const paged = entries.slice(skip, skip + limit);
    return res.json({ ok: true, total, page, limit, activity: paged });
  } catch (err) {
    console.error("❌ [Activity GET Error]:", err.message);
    return res.status(500).json({ ok: false, error: err.message });
  }
});

// ── GET /api/activity/summary & /api/analytics/summary ───────────────────────
router.get("/summary", authenticate, async (req, res) => {
  try {
    const automations = await Automation.find({ userId: req.user._id });

    let totalComments = 0;
    let repliesSent = 0;
    let dmsSent = 0;
    let unresolvedFailuresTotal = 0;
    let totalFailedAttempts = 0;

    for (const a of automations) {
      const logComments = (a.activityLog || []).filter((l) => !l.isDuplicate).length;
      const logReplies = (a.activityLog || []).filter((l) => l.publicReply?.sent || l.publicReply?.status === "sent").length;
      const logDms = (a.activityLog || []).filter((l) => l.privateReply?.sent || l.privateReply?.status === "sent").length;

      totalComments += Math.max(a.stats?.commentsReceived || 0, logComments);
      repliesSent += Math.max(a.stats?.repliesSent || 0, logReplies);
      dmsSent += Math.max(a.stats?.dmsSent || 0, logDms);

      // Authoritative count of currently unresolved failed actions from activityLog
      let autoUnresolvedFailures = 0;
      for (const log of a.activityLog || []) {
        if (log.isDuplicate) continue;

        // Check public reply failure: enabled, not sent, status is 'failed' or 'api_error'
        const pubStatus = log.publicReply?.status;
        const pubFailed = Boolean(a.publicReply?.enabled) &&
          !log.publicReply?.sent &&
          (pubStatus === "failed" || pubStatus === "api_error" || pubStatus === "error");
        if (pubFailed) autoUnresolvedFailures += 1;

        // Check private DM failure: enabled, not sent, status is 'failed' or 'api_error'
        const dmStatus = log.privateReply?.status;
        const dmFailed = Boolean(a.openingDm?.enabled) &&
          !log.privateReply?.sent &&
          (dmStatus === "failed" || dmStatus === "api_error" || dmStatus === "error");
        if (dmFailed) autoUnresolvedFailures += 1;

        // Legacy record fallback: if no explicit status fields, count if top-level error exists
        if (!log.publicReply?.status && !log.privateReply?.status && log.error) {
          autoUnresolvedFailures += 1;
        }
      }

      let autoSkipped = 0;
      let autoPending = 0;
      let autoUnknown = 0;
      for (const log of a.activityLog || []) {
        if (log.isDuplicate) {
          autoSkipped += 1;
          continue;
        }

        const pubStatus = log.publicReply?.status;
        const dmStatus = log.privateReply?.status;

        if (pubStatus === "skipped" || dmStatus === "skipped") {
          autoSkipped += 1;
        }
        if (pubStatus === "pending" || dmStatus === "pending" || pubStatus === "processing" || dmStatus === "processing") {
          autoPending += 1;
        }
        if (pubStatus === "unknown" || dmStatus === "unknown" || pubStatus === "reconciliation_required" || dmStatus === "reconciliation_required") {
          autoUnknown += 1;
        }
      }

      unresolvedFailuresTotal += autoUnresolvedFailures;
      totalFailedAttempts += Math.max(a.stats?.totalFailedAttempts || 0, autoUnresolvedFailures);

      // Reconcile automation.stats.failed using atomic updateOne to bypass legacy log validation
      if ((a.stats?.failed || 0) !== autoUnresolvedFailures) {
        a.stats = a.stats || {};
        a.stats.failed = autoUnresolvedFailures;
        await Automation.updateOne(
          { _id: a._id },
          { $set: { "stats.failed": autoUnresolvedFailures } }
        ).catch(() => {});
      }
    }

    // Tally totals across all user automations
    let totalSkipped = 0;
    let totalPending = 0;
    let totalUnknown = 0;
    for (const a of automations) {
      for (const log of a.activityLog || []) {
        if (log.isDuplicate || log.publicReply?.status === "skipped" || log.privateReply?.status === "skipped") {
          totalSkipped += 1;
        }
        if (log.publicReply?.status === "pending" || log.privateReply?.status === "pending" || log.publicReply?.status === "processing" || log.privateReply?.status === "processing") {
          totalPending += 1;
        }
        if (log.publicReply?.status === "unknown" || log.privateReply?.status === "unknown" || log.publicReply?.status === "reconciliation_required" || log.privateReply?.status === "reconciliation_required") {
          totalUnknown += 1;
        }
      }
    }

    const summary = {
      totalAutomations: automations.length,
      activeAutomations: automations.filter((a) => a.status === "active").length,
      commentsReceived: totalComments,
      repliesSent: repliesSent,
      dmsSent: dmsSent,
      confirmedReplies: repliesSent,
      confirmedDms: dmsSent,
      failedActions: unresolvedFailuresTotal,
      skippedActions: totalSkipped,
      pendingActions: totalPending,
      unknownActions: totalUnknown,
      totalFailedAttempts: Math.max(totalFailedAttempts, unresolvedFailuresTotal),
    };

    return res.json({ ok: true, summary });
  } catch (err) {
    console.error("❌ [Activity Summary Error]:", err.message);
    return res.status(500).json({ ok: false, error: err.message });
  }
});

// ── POST /api/activity/retry-all-failed ───────────────────────────────────────
router.post("/retry-all-failed", authenticate, async (req, res) => {
  try {
    const user = await User.findById(req.user._id);
    const igToken = user?.instagram?.accessToken || process.env.INSTAGRAM_ACCESS_TOKEN;
    if (!igToken) {
      return res.status(400).json({
        ok: false,
        error: "Instagram account not connected or access token missing. Please connect Instagram in Settings.",
        reconnectRequired: true,
      });
    }

    const automations = await Automation.find({ userId: req.user._id });
    let totalEligible = 0;
    let successCount = 0;
    let failedCount = 0;
    const now = Date.now();
    const BATCH_LIMIT = 15;

    for (const automation of automations) {
      let modified = false;

      for (const entry of automation.activityLog || []) {
        if (totalEligible >= BATCH_LIMIT) break;

        const isDmFailed = Boolean(automation.openingDm?.enabled) &&
          !entry.privateReply?.sent &&
          entry.privateReply?.status === "failed";

        if (!isDmFailed) continue;

        const commentDate = entry.commentTimestamp || entry.timestamp || entry.createdAt;
        const commentAgeMs = commentDate ? now - new Date(commentDate).getTime() : 0;
        const isWithin7Days = commentAgeMs <= MESSAGING_RULES.MAX_COMMENT_AGE_MS;

        const attempts = entry.privateReply?.attempts || 0;
        if (
          !isWithin7Days ||
          entry.privateReply?.retryEligible === false ||
          entry.privateReply?.isProcessing ||
          attempts >= MAX_DM_RETRIES
        ) {
          continue;
        }

        const igUserId = user?.instagram?.id || req.user._id.toString();
        const cleanMedia = String(automation.mediaId || "").trim().split("_").pop();

        // 1. Authoritative ActionLedger deduplication & eligibility check
        const ledgerCheck = await ActionLedgerService.checkAlreadySent({
          igUserId,
          mediaId: cleanMedia,
          commentId: entry.commentId,
          recipientId: entry.recipientId || null,
          actionType: "dm",
        });

        if (ledgerCheck.isAlreadySent) {
          if (ActionLedgerService.isSentStatus(ledgerCheck.status) || ActionLedgerService.isSentStatus(ledgerCheck.record?.status)) {
            entry.privateReply.sent = true;
            entry.privateReply.status = "sent";
            entry.privateReply.retryEligible = false;
            entry.privateReply.retryReason = "Delivered previously";
            automation.stats.dmsSent = (automation.stats.dmsSent || 0) + 1;
            automation.stats.failed = Math.max(0, (automation.stats.failed || 0) - 1);
            modified = true;
            continue;
          } else {
            entry.privateReply.status = "skipped";
            entry.privateReply.retryEligible = false;
            entry.privateReply.retryReason = ledgerCheck.reason || "Skipped";
            modified = true;
            continue;
          }
        }

        // 2. Claim action atomically
        const claimRes = await ActionLedgerService.claimAction({
          igUserId,
          mediaId: cleanMedia,
          commentId: entry.commentId,
          recipientId: entry.recipientId || null,
          username: entry.username || "unknown",
          actionType: "dm",
          automationId: automation._id,
          source: "retry",
        });

        if (!claimRes.claimed) {
          continue;
        }

        totalEligible++;
        entry.privateReply.attempts = (entry.privateReply.attempts || 0) + 1;
        entry.privateReply.lastAttemptAt = new Date();

        try {
          const rawDmMsg = entry.privateReply.message || automation.openingDm?.message || "";
          const buttonText = (entry.privateReply.buttonText || automation.openingDm?.buttonText || "Open Link").trim();
          const linkUrl = (entry.privateReply.link || automation.openingDm?.link || "").trim();

          const dmResult = await InstagramService.sendPrivateReply(
            entry.commentId,
            rawDmMsg,
            igToken,
            buttonText,
            linkUrl,
            commentDate
          );

          const dmKey = claimRes.record?.actionKey || ActionLedgerService.buildActionKey({ igUserId, mediaId: cleanMedia, commentId: entry.commentId, actionType: "dm" });

          if (dmResult.ok) {
            await ActionLedgerService.finalizeAction({
              actionKey: dmKey,
              claimToken: claimRes.claimToken,
              result: dmResult,
            });

            entry.privateReply.sent = true;
            entry.privateReply.status = "sent";
            entry.privateReply.messageId = dmResult.messageId;
            entry.privateReply.lastSuccessAt = new Date();
            entry.privateReply.retryEligible = false;
            entry.privateReply.retryReason = "Delivered successfully";
            entry.privateReply.error = null;
            entry.privateReply.errorMessage = null;

            if (entry.publicReply?.status === "failed") {
              entry.error = `[Public Reply] ${entry.publicReply.errorMessage || entry.publicReply.error}`;
            } else {
              entry.error = null;
            }

            automation.stats.dmsSent = (automation.stats.dmsSent || 0) + 1;
            automation.stats.failed = Math.max(0, (automation.stats.failed || 0) - 1);
            successCount++;
            modified = true;
          } else {
            const err = dmResult.error || {};
            const metaClass = ActionLedgerService.classifyMetaError(err);

            if (metaClass.isAlreadyReplied) {
              await ActionLedgerService.finalizeAction({
                actionKey: dmKey,
                claimToken: claimRes.claimToken,
                error: err,
              });
              entry.privateReply.sent = true;
              entry.privateReply.status = "sent";
              entry.privateReply.messageId = dmResult.messageId || null;
              entry.privateReply.lastSuccessAt = new Date();
              entry.privateReply.retryEligible = false;
              entry.privateReply.retryReason = "Confirmed already sent by Meta API";
              entry.privateReply.error = null;
              entry.privateReply.errorMessage = null;

              if (entry.publicReply?.status === "failed") {
                entry.error = `[Public Reply] ${entry.publicReply.errorMessage || entry.publicReply.error}`;
              } else {
                entry.error = null;
              }

              automation.stats.dmsSent = (automation.stats.dmsSent || 0) + 1;
              automation.stats.failed = Math.max(0, (automation.stats.failed || 0) - 1);
              successCount++;
              modified = true;
            } else if (metaClass.isIneligible) {
              await ActionLedgerService.finalizeAction({
                actionKey: dmKey,
                claimToken: claimRes.claimToken,
                error: err,
                skipReason: metaClass.reason,
              });
              entry.privateReply.sent = false;
              entry.privateReply.status = "skipped";
              entry.privateReply.errorCategory = metaClass.category;
              entry.privateReply.errorMessage = err.message || "DM action ineligible";
              entry.privateReply.retryEligible = false;
              entry.privateReply.retryReason = `Skipped: ${metaClass.reason}`;
            } else if (err.isAmbiguous) {
              await ActionLedgerService.finalizeAction({
                actionKey: dmKey,
                claimToken: claimRes.claimToken,
                error: err,
                isAmbiguous: true,
              });
              entry.privateReply.sent = false;
              entry.privateReply.status = "unknown";
              entry.privateReply.errorCategory = "AMBIGUOUS_DELIVERY";
              entry.privateReply.errorMessage = err.message || "Ambiguous delivery outcome";
              entry.privateReply.retryEligible = false;
              entry.privateReply.retryReason = "Ambiguous delivery outcome (timeout)";
              failedCount++;
            } else {
              await ActionLedgerService.finalizeAction({
                actionKey: dmKey,
                claimToken: claimRes.claimToken,
                error: err,
              });
              entry.privateReply.sent = false;
              entry.privateReply.lastFailedAt = new Date();
              entry.privateReply.errorCategory = err.category || "API_ERROR";
              entry.privateReply.errorMessage = err.message || "Failed to deliver direct message";
              entry.privateReply.error = err.message || "Failed to deliver direct message";
              entry.privateReply.status = "failed";

              const canRetry =
                entry.privateReply.attempts < MAX_DM_RETRIES &&
                err.category !== "ACTION_BLOCKED" &&
                err.category !== "ALREADY_REPLIED" &&
                err.isRetryable !== false;
              entry.privateReply.retryEligible = canRetry;
              entry.privateReply.retryReason = canRetry ? "Eligible for retry" : (err.message || "Retry not permitted");

              automation.stats.totalFailedAttempts = (automation.stats.totalFailedAttempts || 0) + 1;
              failedCount++;
            }
            modified = true;
          }
        } catch (_) {
          failedCount++;
        }
      }

      if (modified) {
        await automation.save();
      }
    }

    return res.json({
      ok: true,
      retriedCount: totalEligible,
      successCount,
      failedCount,
      message: totalEligible === 0
        ? "No eligible failed actions found to resend."
        : `Resent ${totalEligible} action(s): ${successCount} succeeded, ${failedCount} failed.`,
    });
  } catch (err) {
    console.error("❌ [Retry All Failed Error]:", err.message);
    return res.status(500).json({ ok: false, error: err.message });
  }
});

// ── POST /api/activity/:activityId/retry-dm ──────────────────────────────────
router.post("/:activityId/retry-dm", authenticate, async (req, res) => {
  const { activityId } = req.params;

  if (!activityId || typeof activityId !== "string") {
    return res.status(400).json({ ok: false, error: "Invalid activity ID provided" });
  }

  try {
    // 1. Find if the activity exists on ANY automation
    const isObjectId = mongoose.Types.ObjectId.isValid(activityId);
    const lookupQuery = isObjectId
      ? { $or: [{ "activityLog._id": new mongoose.Types.ObjectId(activityId) }, { "activityLog.commentId": activityId }] }
      : { "activityLog.commentId": activityId };

    const automation = await Automation.findOne(lookupQuery);
    if (!automation) {
      return res.status(404).json({ ok: false, error: "Activity record not found" });
    }

    // 2. Ownership & Authorization Check
    if (automation.userId.toString() !== req.user._id.toString()) {
      return res.status(403).json({ ok: false, error: "Unauthorized access to this activity record" });
    }

    // 3. Find specific activity entry
    const entry = automation.activityLog.find(
      (e) => (e._id && e._id.toString() === activityId) || e.commentId === activityId
    );
    if (!entry) {
      return res.status(404).json({ ok: false, error: "Activity entry not found in automation log" });
    }

    // 4. Validate DM Action Configuration
    if (!entry.privateReply || entry.privateReply.status === "disabled") {
      return res.status(400).json({ ok: false, error: "Private DM action was not enabled for this comment" });
    }

    if (entry.privateReply.sent === true || entry.privateReply.status === "sent") {
      return res.status(409).json({ ok: false, error: "Private DM has already been sent successfully for this comment" });
    }

    if (entry.privateReply.retryEligible === false) {
      const reason = entry.privateReply.retryReason || (entry.privateReply.errorCategory === "ACTION_BLOCKED" ? "Action blocked by Instagram" : "Action is not retryable");
      return res.status(400).json({
        ok: false,
        error: `Cannot retry: ${reason.toLowerCase()}`,
        retryEligible: false,
      });
    }

    // Concurrency check: Reject if retry is currently in progress
    if (entry.privateReply.isProcessing) {
      const lockAge = entry.privateReply.processingLockAt
        ? Date.now() - new Date(entry.privateReply.processingLockAt).getTime()
        : 0;
      if (lockAge < 60000) {
        return res.status(409).json({
          ok: false,
          error: "A retry request is currently in progress for this DM",
        });
      }
    }

    const user = await User.findById(req.user._id);
    const igToken = user?.instagram?.accessToken || process.env.INSTAGRAM_ACCESS_TOKEN;
    const igUserId = user?.instagram?.id || req.user._id.toString();
    const cleanMedia = String(automation.mediaId || "").trim().split("_").pop();

    // 5. Authoritative ActionLedger check: refuse already successful, skipped, or ambiguous DMs
    const ledgerCheck = await ActionLedgerService.checkAlreadySent({
      igUserId,
      mediaId: cleanMedia,
      commentId: entry.commentId,
      recipientId: entry.recipientId || null,
      actionType: "dm",
    });

    if (ledgerCheck.isAlreadySent) {
      if (ActionLedgerService.isSentStatus(ledgerCheck.status) || ActionLedgerService.isSentStatus(ledgerCheck.record?.status)) {
        entry.privateReply.sent = true;
        entry.privateReply.status = "sent";
        entry.privateReply.retryEligible = false;
        entry.privateReply.retryReason = "Delivered previously";
        await automation.save();
        return res.status(409).json({ ok: false, error: "Private DM has already been sent successfully for this comment" });
      } else if (ledgerCheck.record?.status === "skipped") {
        entry.privateReply.status = "skipped";
        entry.privateReply.retryEligible = false;
        entry.privateReply.retryReason = ledgerCheck.reason || "Skipped permanently";
        await automation.save();
        return res.status(400).json({ ok: false, error: `Cannot retry: DM was skipped (${ledgerCheck.reason})`, retryEligible: false });
      } else if (ledgerCheck.record?.status === "unknown" || ledgerCheck.record?.status === "reconciliation_required") {
        return res.status(400).json({ ok: false, error: "Cannot retry: Delivery outcome is ambiguous. Manual verification required.", retryEligible: false });
      }
    }

    if (entry.privateReply.sent === true || entry.privateReply.status === "sent") {
      return res.status(409).json({ ok: false, error: "Private DM has already been sent successfully for this comment" });
    }

    // 6. Max Retry Limit Check
    const currentAttempts = entry.privateReply.attempts || 0;
    if (currentAttempts >= MAX_DM_RETRIES) {
      return res.status(429).json({
        ok: false,
        error: `Maximum retry attempts exceeded (${MAX_DM_RETRIES}/${MAX_DM_RETRIES})`,
        retryEligible: false,
      });
    }

    // 7. Meta 7-Day Window Policy Check
    const commentDate = entry.commentTimestamp || entry.timestamp || entry.createdAt;
    if (commentDate) {
      const commentAgeMs = Date.now() - new Date(commentDate).getTime();
      if (commentAgeMs > MESSAGING_RULES.MAX_COMMENT_AGE_MS) {
        entry.privateReply.status = "skipped";
        entry.privateReply.retryEligible = false;
        entry.privateReply.retryReason = "Comment is older than 7 days (Meta policy expired)";
        await automation.save();
        return res.status(400).json({
          ok: false,
          error: "Cannot retry: Comment is older than 7 days per Meta Messaging Policy",
          retryEligible: false,
        });
      }
    }

    // 8. Verify Instagram Connected Token
    if (!igToken) {
      return res.status(400).json({
        ok: false,
        error: "Instagram account not connected or access token missing. Please reconnect Instagram in Settings.",
        reconnectRequired: true,
        retryEligible: true,
      });
    }

    // 9. Atomically Claim the Retry Action via ActionLedger
    const claimRes = await ActionLedgerService.claimAction({
      igUserId,
      mediaId: cleanMedia,
      commentId: entry.commentId,
      recipientId: entry.recipientId || null,
      username: entry.username || "unknown",
      actionType: "dm",
      automationId: automation._id,
      source: "retry",
    });

    if (!claimRes.claimed) {
      return res.status(409).json({
        ok: false,
        error: claimRes.reason || "A retry request is currently in progress for this DM",
        retryEligible: false,
      });
    }

    // 10. Acquire In-Memory Processing Lock
    entry.privateReply.isProcessing = true;
    entry.privateReply.processingLockAt = new Date();
    await automation.save();

    let dmResult;
    try {
      const rawDmMsg = entry.privateReply.message || automation.openingDm?.message || "";
      const buttonText = (entry.privateReply.buttonText || automation.openingDm?.buttonText || "Open Link").trim();
      const linkUrl = (entry.privateReply.link || automation.openingDm?.link || "").trim();

      dmResult = await InstagramService.sendPrivateReply(
        entry.commentId,
        rawDmMsg,
        igToken,
        buttonText,
        linkUrl,
        commentDate
      );
    } catch (err) {
      dmResult = {
        ok: false,
        error: { message: err.message, category: "NETWORK_ERROR", isRetryable: true },
      };
    } finally {
      entry.privateReply.isProcessing = false;
      entry.privateReply.processingLockAt = null;
    }

    // 11. Handle Delivery Outcome & Finalize ActionLedger
    entry.privateReply.attempts = (entry.privateReply.attempts || 0) + 1;
    entry.privateReply.lastAttemptAt = new Date();
    const dmKey = claimRes.record?.actionKey || ActionLedgerService.buildActionKey({ igUserId, mediaId: cleanMedia, commentId: entry.commentId, actionType: "dm" });

    if (dmResult.ok) {
      await ActionLedgerService.finalizeAction({
        actionKey: dmKey,
        claimToken: claimRes.claimToken,
        result: dmResult,
      });

      entry.privateReply.sent = true;
      entry.privateReply.status = "sent";
      entry.privateReply.messageId = dmResult.messageId;
      entry.privateReply.lastSuccessAt = new Date();
      entry.privateReply.retryEligible = false;
      entry.privateReply.retryReason = "Delivered successfully";
      entry.privateReply.error = null;
      entry.privateReply.errorMessage = null;
      entry.privateReply.errorCategory = null;
      entry.privateReply.errorCode = null;
      entry.privateReply.errorSubcode = null;

      if (entry.publicReply?.status === "failed") {
        entry.error = `[Public Reply] ${entry.publicReply.errorMessage || entry.publicReply.error}`;
      } else {
        entry.error = null;
      }

      automation.stats.dmsSent = (automation.stats.dmsSent || 0) + 1;
      automation.stats.failed = Math.max(0, (automation.stats.failed || 0) - 1);
      await automation.save();
      console.log(`✅ [Retry DM Success] Delivered DM for comment [${entry.commentId}]`);

      return res.status(200).json({
        ok: true,
        message: "DM retried and sent successfully",
        activity: formatActivityEntry(automation, entry),
      });
    } else {
      const err = dmResult.error || {};
      const metaClass = ActionLedgerService.classifyMetaError(err);

      if (metaClass.isAlreadyReplied) {
        await ActionLedgerService.finalizeAction({
          actionKey: dmKey,
          claimToken: claimRes.claimToken,
          error: err,
        });

        entry.privateReply.sent = true;
        entry.privateReply.status = "sent";
        entry.privateReply.messageId = dmResult.messageId || null;
        entry.privateReply.lastSuccessAt = new Date();
        entry.privateReply.retryEligible = false;
        entry.privateReply.retryReason = "Confirmed already sent by Meta API";
        entry.privateReply.error = null;
        entry.privateReply.errorMessage = null;
        entry.privateReply.errorCategory = null;

        if (entry.publicReply?.status === "failed") {
          entry.error = `[Public Reply] ${entry.publicReply.errorMessage || entry.publicReply.error}`;
        } else {
          entry.error = null;
        }

        automation.stats.dmsSent = (automation.stats.dmsSent || 0) + 1;
        automation.stats.failed = Math.max(0, (automation.stats.failed || 0) - 1);
        await automation.save();
        console.log(`✅ [Retry DM Reconciled] Meta confirms DM was delivered for comment [${entry.commentId}]`);

        return res.status(200).json({
          ok: true,
          message: "DM retried and sent successfully",
          reconciled: true,
          activity: formatActivityEntry(automation, entry),
        });
      } else if (metaClass.isIneligible) {
        await ActionLedgerService.finalizeAction({
          actionKey: dmKey,
          claimToken: claimRes.claimToken,
          error: err,
          skipReason: metaClass.reason,
        });

        entry.privateReply.sent = false;
        entry.privateReply.status = "skipped";
        entry.privateReply.errorCategory = metaClass.category;
        entry.privateReply.errorMessage = err.message || "DM action ineligible";
        entry.privateReply.error = err.message || "DM action ineligible";
        entry.privateReply.retryEligible = false;
        entry.privateReply.retryReason = `Skipped: ${metaClass.reason}`;
        entry.error = `[DM] ${entry.privateReply.errorMessage}`;
        await automation.save();

        return res.status(400).json({
          ok: false,
          error: `DM action ineligible: ${metaClass.reason}`,
          activity: formatActivityEntry(automation, entry),
        });
      } else if (err.isAmbiguous) {
        await ActionLedgerService.finalizeAction({
          actionKey: dmKey,
          claimToken: claimRes.claimToken,
          error: err,
          isAmbiguous: true,
        });

        entry.privateReply.sent = false;
        entry.privateReply.status = "unknown";
        entry.privateReply.errorCategory = "AMBIGUOUS_DELIVERY";
        entry.privateReply.errorMessage = err.message || "Ambiguous delivery outcome";
        entry.privateReply.error = err.message || "Ambiguous delivery outcome";
        entry.privateReply.retryEligible = false;
        entry.privateReply.retryReason = "Ambiguous delivery outcome (timeout). Manual reconciliation required.";
        entry.error = `[DM] Ambiguous delivery outcome`;
        await automation.save();

        return res.status(400).json({
          ok: false,
          error: "Delivery outcome is ambiguous. Please verify before retrying.",
          activity: formatActivityEntry(automation, entry),
        });
      } else {
        await ActionLedgerService.finalizeAction({
          actionKey: dmKey,
          claimToken: claimRes.claimToken,
          error: err,
        });

        entry.privateReply.sent = false;
        entry.privateReply.lastFailedAt = new Date();
        entry.privateReply.errorCategory = err.category || "API_ERROR";
        entry.privateReply.errorCode = err.code || null;
        entry.privateReply.errorSubcode = err.subcode || null;
        entry.privateReply.errorMessage = err.message || "Failed to deliver direct message";
        entry.privateReply.error = err.message || "Failed to deliver direct message";
        entry.privateReply.status = "failed";

        const canRetry =
          entry.privateReply.attempts < MAX_DM_RETRIES &&
          err.category !== "ACTION_BLOCKED" &&
          err.category !== "ALREADY_REPLIED" &&
          err.isRetryable !== false;
        entry.privateReply.retryEligible = canRetry;
        entry.privateReply.retryReason = canRetry ? "Eligible for retry" : (err.message || "Retry not permitted");
        entry.error = `[DM] ${entry.privateReply.errorMessage}`;

        automation.stats.totalFailedAttempts = (automation.stats.totalFailedAttempts || 0) + 1;
        if (err.shouldPauseAutomation) {
          automation.status = "paused";
        }
        await automation.save();

        const httpStatus = err.category === "RATE_LIMIT" ? 429 : 400;
        return res.status(httpStatus).json({
          ok: false,
          error: err.message || "Failed to deliver direct message",
          activity: formatActivityEntry(automation, entry),
        });
      }
    }
  } catch (err) {
    console.error("❌ [Retry DM Server Error]:", err.message);
    return res.status(500).json({ ok: false, error: err.message });
  }
});

module.exports = router;
