// ════════════════════════════════════════════════════════════════════════════
// InstaAuto — Backfill Comments Service
// Allows executing automation rules on pre-existing Instagram comments
// Complies with Meta 7-day conversation window, anti-spam pacing, idempotency,
// and resilient error isolation (one failed member never stops other members).
// ════════════════════════════════════════════════════════════════════════════
const mongoose = require("mongoose");
const crypto = require("crypto");
const Automation = require("../models/Automation");
const User = require("../models/User");
const BackfillJob = require("../models/BackfillJob");
const ActionLedger = require("../models/ActionLedger");
const InstagramService = require("./instagramService");
const AutomationEngine = require("./automationEngine");
const ActionLedgerService = require("./actionLedgerService");
const EligibilityService = require("./eligibilityService");
const { ANTI_SPAM_RULES, MESSAGING_RULES } = require("../config/instagramRules");

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function escapeRegex(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

class BackfillService {
  /**
   * Validate preconditions for backfill:
   * 1. Automation exists and is owned by userId
   * 2. Automation must be ACTIVE (throws AUTOMATION_INACTIVE)
   * 3. At least one action (public reply or DM) is enabled
   * 4. User exists and has connected Instagram account / token
   */
  static async validatePreconditions(userId, automationId, mediaId = null) {
    const automation = await Automation.findOne({ _id: automationId, userId });
    if (!automation) {
      const err = new Error("Automation not found or unauthorized");
      err.code = "AUTOMATION_NOT_FOUND";
      throw err;
    }

    if (automation.status !== "active") {
      const err = new Error("Automation is inactive. Activate automation to process existing comments.");
      err.code = "AUTOMATION_INACTIVE";
      throw err;
    }

    const publicEnabled = Boolean(automation.publicReply?.enabled);
    const dmEnabled = Boolean(automation.openingDm?.enabled);
    if (!publicEnabled && !dmEnabled) {
      const err = new Error("Neither public reply nor direct message is enabled for this automation.");
      err.code = "NO_ACTIONS_ENABLED";
      throw err;
    }

    const targetMediaId = mediaId || automation.mediaId;
    if (!targetMediaId) {
      const err = new Error("No media post associated with this automation");
      err.code = "NO_MEDIA";
      throw err;
    }

    const user = await User.findById(userId);
    const token = user?.instagram?.accessToken || process.env.INSTAGRAM_ACCESS_TOKEN;
    if (!token) {
      const err = new Error("Instagram access token missing or account disconnected");
      err.code = "NO_INSTAGRAM_ACCOUNT";
      throw err;
    }

    return { automation, user, token, targetMediaId, publicEnabled, dmEnabled };
  }

  /**
   * Preview comments on a media post against an automation rule
   * Returns eligibility breakdown and list of comments with predicted actions
   */
  static async preview(userId, automationId, mediaId = null) {
    const { automation, token, targetMediaId } = await this.validatePreconditions(userId, automationId, mediaId);

    // Fetch existing comments on the post (with pagination up to 200)
    let allComments = [];
    let cursor = null;
    let pageCount = 0;
    const maxPages = 4; // 4 pages * 50 = up to 200 comments

    do {
      pageCount++;
      const res = await InstagramService.fetchComments(targetMediaId, token, 50, cursor);
      if (!res.ok) {
        if (pageCount === 1) {
          throw new Error(res.error?.message || "Failed to fetch comments from Instagram");
        }
        break; // Partial fetch is acceptable
      }
      const pageData = res.comments || [];
      allComments.push(...pageData);

      cursor = res.paging?.cursors?.after;
      if (!cursor || !res.paging?.next) break;
    } while (cursor && pageCount < maxPages);

    const botUsername = (process.env.BOT_USERNAME || "").toLowerCase();
    const botUserId = process.env.INSTAGRAM_USER_ID;
    const trigger = automation.trigger || {};
    const existingActivity = automation.activityLog || [];

    // Query authoritative ActionLedger to prevent duplicate actions across jobs/retries
    const cleanMediaId = String(targetMediaId || "").trim().split("_").pop();
    const ledgerRecords = await ActionLedger.find({ mediaId: cleanMediaId }).lean();

    const ledgerByComment = new Map();
    const sentDmRecipients = new Set();
    const sentDmUsernames = new Set();

    for (const rec of ledgerRecords) {
      ledgerByComment.set(`${rec.commentId}:${rec.actionType}`, rec);
      if (rec.actionType === "dm" && ActionLedgerService.isSentStatus(rec.status)) {
        if (rec.recipientId) sentDmRecipients.add(String(rec.recipientId));
        if (rec.username && rec.username !== "unknown") sentDmUsernames.add(rec.username.toLowerCase());
      }
    }

    // Also populate sent sets from existing activityLog for backward compatibility
    for (const entry of existingActivity) {
      if (entry.privateReply?.sent || ActionLedgerService.isSentStatus(entry.privateReply?.status)) {
        if (entry.recipientId) sentDmRecipients.add(String(entry.recipientId));
        if (entry.username && entry.username !== "unknown") sentDmUsernames.add(entry.username.toLowerCase());
      }
    }

    // Track recipients assigned a DM in the current preview batch to enforce single-DM-per-user-per-post
    const batchDmRecipients = new Set();
    const batchDmUsernames = new Set();

    const previewItems = [];
    let eligibleCount = 0;
    let alreadyProcessedCount = 0;
    let unmatchedCount = 0;
    let expiredDmCount = 0;

    for (const c of allComments) {
      const commentId = String(c.id);
      const text = c.text || "";
      const username = c.from?.username || c.username || "unknown";
      const commenterId = c.from?.id;

      // Safely parse timestamp via shared EligibilityService
      const tsResult = EligibilityService.parseTimestamp(c.timestamp);
      const commentTimestamp = tsResult.valid ? tsResult.date : new Date();

      // Check self-comment
      const isSelf = EligibilityService.isSelfComment({
        username,
        recipientId: commenterId,
        botUsername,
        botUserId,
      });
      if (isSelf) continue;

      // Check activity log and ActionLedger for already processed status
      const existingEntry = existingActivity.find((e) => String(e.commentId) === commentId);
      const pubLedger = ledgerByComment.get(`${commentId}:public_reply`);
      const dmLedger = ledgerByComment.get(`${commentId}:dm`);

      const publicReplyAlreadySent = ActionLedgerService.isSentStatus(pubLedger?.status) || Boolean(existingEntry?.publicReply?.sent);
      const commentDmAlreadySent = ActionLedgerService.isSentStatus(dmLedger?.status) || Boolean(existingEntry?.privateReply?.sent);
      const userAlreadyReceivedDm = (commenterId && sentDmRecipients.has(String(commenterId))) || (username && sentDmUsernames.has(username.toLowerCase()));
      const userAlreadyInBatch = (commenterId && batchDmRecipients.has(String(commenterId))) || (username && batchDmUsernames.has(username.toLowerCase()));

      const dmAlreadySent = commentDmAlreadySent || userAlreadyReceivedDm;
      const dmDuplicateUser = !commentDmAlreadySent && (userAlreadyReceivedDm || userAlreadyInBatch);
      const dmSkippedInLedger = dmLedger?.status === "skipped";
      const dmAmbiguousInLedger = dmLedger?.status === "unknown" || dmLedger?.status === "reconciliation_required";
      const dmSkipReason = dmLedger?.skipReason || (dmDuplicateUser ? "ALREADY_SENT_TO_USER" : (dmAmbiguousInLedger ? "AMBIGUOUS_OUTCOME" : null));

      // Check trigger match
      let ruleMatched = false;
      let matchedRuleName = "no_match";

      if (trigger.matchType === "any") {
        ruleMatched = true;
        matchedRuleName = "any_word";
      } else if (trigger.keywords?.length > 0) {
        const normalized = text.toLowerCase().replace(/\s+/g, " ").trim();
        for (const kw of trigger.keywords) {
          const match = trigger.wholeWord
            ? new RegExp(`(?<![a-z0-9])${escapeRegex(kw)}(?![a-z0-9])`, "i").test(normalized)
            : normalized.includes(kw.toLowerCase().trim());
          if (match) {
            ruleMatched = true;
            matchedRuleName = kw;
            break;
          }
        }
      }

      // Check Meta 7-day conversation window
      const isWithin7Days = tsResult.valid && (Date.now() - commentTimestamp.getTime() <= MESSAGING_RULES.MAX_COMMENT_AGE_MS);

      const publicEnabled = Boolean(automation.publicReply?.enabled);
      const dmEnabled = Boolean(automation.openingDm?.enabled);

      const canSendPublic = publicEnabled && !publicReplyAlreadySent;
      const canSendDm = dmEnabled && !dmAlreadySent && !dmDuplicateUser && !dmSkippedInLedger && !dmAmbiguousInLedger && isWithin7Days;
      const dmExpired = dmEnabled && !dmAlreadySent && !isWithin7Days;

      if (canSendDm) {
        if (commenterId) batchDmRecipients.add(String(commenterId));
        if (username && username !== "unknown") batchDmUsernames.add(username.toLowerCase());
      }

      if (dmExpired) expiredDmCount++;

      let status = "eligible";
      let reason = null;

      if (!ruleMatched) {
        status = "unmatched";
        reason = "Did not match trigger keywords";
        unmatchedCount++;
      } else if (!canSendPublic && !canSendDm) {
        if (publicReplyAlreadySent && dmAlreadySent) {
          status = "already_processed";
          reason = "Both public reply and DM were already sent";
          alreadyProcessedCount++;
        } else if (dmAmbiguousInLedger && (!publicEnabled || publicReplyAlreadySent)) {
          status = "skipped";
          reason = "DM delivery outcome is ambiguous. Automatic resend prohibited.";
          alreadyProcessedCount++;
        } else if (dmDuplicateUser && (!publicEnabled || publicReplyAlreadySent)) {
          status = "skipped";
          reason = "DM already sent to this user on this post";
          alreadyProcessedCount++;
        } else if (dmExpired && (!publicEnabled || publicReplyAlreadySent)) {
          status = "skipped";
          reason = "Comment is older than 7 days (Meta policy expired)";
        } else if (dmSkippedInLedger && (!publicEnabled || publicReplyAlreadySent)) {
          status = "skipped";
          reason = `DM ineligible (${dmSkipReason})`;
          alreadyProcessedCount++;
        } else {
          status = "already_processed";
          reason = "Configured actions were already sent";
          alreadyProcessedCount++;
        }
      } else {
        status = "eligible";
        eligibleCount++;
      }

      previewItems.push({
        commentId,
        recipientId: commenterId ? String(commenterId) : null,
        username,
        text,
        commentTimestamp,
        timestamp: commentTimestamp,
        ruleMatched: matchedRuleName,
        status,
        isEligible: status === "eligible",
        reason,
        isWithin7Days,
        isOlderThan7Days: dmExpired,
        canSendPublic,
        canSendDm,
        willSendPublicReply: canSendPublic,
        willSendDm: canSendDm,
        dmExpired,
        dmDuplicateUser,
        publicReplyAlreadySent,
        dmAlreadySent,
        dmAmbiguousInLedger: Boolean(dmAmbiguousInLedger),
        dmSkippedInLedger: Boolean(dmSkippedInLedger),
        dmSkipReason: dmSkipReason || null,
      });
    }

    return {
      automationId: automation._id,
      automationName: automation.name,
      mediaId: targetMediaId,
      mediaThumbnail: automation.mediaThumbnail,
      mediaCaption: automation.mediaCaption,
      totalFound: allComments.length,
      totalComments: allComments.length,
      eligibleCount,
      alreadyProcessedCount,
      unmatchedCount,
      expiredDmCount,
      comments: previewItems,
    };
  }

  /**
   * Start an asynchronous backfill job
   */
  static async startJob(userId, automationId, mediaId = null, selectedCommentIds = null) {
    const { automation, targetMediaId } = await this.validatePreconditions(userId, automationId, mediaId);

    // Check for an active job already in progress
    const activeJob = await BackfillJob.findOne({
      automationId,
      mediaId: targetMediaId,
      status: "processing",
    });

    if (activeJob) {
      // Check if job is stale (running for over 15 minutes)
      const isStale = Date.now() - new Date(activeJob.updatedAt).getTime() > 15 * 60 * 1000;
      if (!isStale) {
        return { ok: true, job: activeJob, isAlreadyRunning: true };
      }
      activeJob.status = "failed";
      activeJob.error = "Previous job timed out or server restarted";
      activeJob.isLocked = false;
      await activeJob.save();
    }

    // Generate preview to get action list
    const previewData = await this.preview(userId, automationId, targetMediaId);
    let targetActions = previewData.comments.filter((c) => c.status === "eligible");

    if (Array.isArray(selectedCommentIds) && selectedCommentIds.length > 0) {
      const idSet = new Set(selectedCommentIds.map(String));
      targetActions = targetActions.filter((c) => idSet.has(String(c.commentId)));
    }

    if (targetActions.length === 0) {
      throw new Error("No eligible comments found to process");
    }

    // Build initial action list for the job
    const jobActions = targetActions.map((c) => ({
      commentId: c.commentId,
      recipientId: c.recipientId || null,
      username: c.username,
      text: c.text,
      commentTimestamp: c.commentTimestamp,
      ruleMatched: c.ruleMatched,
      status: "pending",
      publicReply: {
        status: c.canSendPublic ? "pending" : (c.publicReplyAlreadySent ? "sent" : "disabled"),
        attempts: 0,
      },
      privateReply: {
        status: c.canSendDm
          ? "pending"
          : c.dmAlreadySent
          ? "sent"
          : c.dmAmbiguousInLedger
          ? "unknown"
          : c.dmExpired
          ? "skipped"
          : c.dmDuplicateUser
          ? "skipped"
          : c.dmSkippedInLedger
          ? "skipped"
          : "disabled",
        skipReason: c.dmAmbiguousInLedger
          ? "AMBIGUOUS_OUTCOME"
          : c.dmExpired
          ? "WINDOW_CLOSED_7_DAYS"
          : c.dmDuplicateUser
          ? "ALREADY_SENT_TO_USER"
          : c.dmSkipReason || null,
        retryReason: c.dmAmbiguousInLedger
          ? "Delivery outcome ambiguous. Automatic resend prohibited."
          : c.dmExpired
          ? "Comment is older than 7 days (Meta policy expired)"
          : c.dmDuplicateUser
          ? "Already sent to user on this post"
          : null,
        attempts: 0,
      },
    }));

    const job = await BackfillJob.create({
      userId,
      automationId,
      mediaId: targetMediaId,
      mediaCaption: automation.mediaCaption,
      mediaThumbnail: automation.mediaThumbnail,
      status: "processing",
      totalComments: jobActions.length,
      processedCount: 0,
      successCount: 0,
      failedCount: 0,
      skippedCount: 0,
      actions: jobActions,
      startedAt: new Date(),
    });

    // Execute asynchronously in background
    setImmediate(() => {
      this.executeJob(job._id).catch((err) => {
        console.error(`❌ [Backfill Job Error] Job ${job._id}:`, err);
      });
    });

    return { ok: true, job };
  }

  /**
   * Resume an incomplete, paused, or failed BackfillJob without creating duplicate workers
   * Preserves existing progress and NEVER resends already completed actions
   */
  static async resumeJob(jobId, userId) {
    const job = await BackfillJob.findOne({ _id: jobId, userId });
    if (!job) {
      const err = new Error("Job not found or unauthorized");
      err.code = "JOB_NOT_FOUND";
      throw err;
    }

    await this.validatePreconditions(userId, job.automationId, job.mediaId);

    const now = new Date();
    const lockToken = crypto.randomUUID();
    // Concurrency protection: atomically acquire execution lock
    const lockedJob = await BackfillJob.findOneAndUpdate(
      {
        _id: jobId,
        $or: [{ isLocked: { $ne: true } }, { lockExpiresAt: { $lt: now } }],
      },
      {
        $set: {
          isLocked: true,
          lockToken,
          lockExpiresAt: new Date(now.getTime() + 15 * 60 * 1000),
          status: "processing",
          error: null,
        },
      },
      { returnDocument: "after" }
    );

    if (!lockedJob) {
      return { ok: false, error: "Job is already being processed by another worker", isAlreadyRunning: true };
    }

    setImmediate(() => {
      this.executeJob(job._id, { isResume: true, lockToken }).catch((err) => {
        console.error(`❌ [Backfill Job Error] Resume job ${job._id}:`, err);
      });
    });

    return { ok: true, job: lockedJob };
  }

  /**
   * Background execution worker for BackfillJob.
   * Key invariants:
   * - One failed member NEVER stops remaining members.
   * - Every comment is wrapped in its own try/catch.
   * - Transient errors are retried with bounded backoff.
   * - Atomic updates preserve progress after every action.
   * - Fatal errors (e.g. revoked token) safely pause/fail the job.
   */
  static async executeJob(jobId, { isResume = false, lockToken = null } = {}) {
    let activeLockToken = lockToken;
    let job;

    if (activeLockToken) {
      job = await BackfillJob.findOne({ _id: jobId, lockToken: activeLockToken });
    } else {
      const now = new Date();
      activeLockToken = crypto.randomUUID();
      job = await BackfillJob.findOneAndUpdate(
        {
          _id: jobId,
          $or: [{ isLocked: { $ne: true } }, { lockExpiresAt: { $lt: now } }],
        },
        {
          $set: {
            isLocked: true,
            lockToken: activeLockToken,
            lockExpiresAt: new Date(now.getTime() + 15 * 60 * 1000),
            status: "processing",
          },
        },
        { returnDocument: "after" }
      );
    }

    if (!job) {
      console.warn(`🔒 [Backfill Concurrency Guard] Job ${jobId} already claimed by another worker.`);
      return;
    }

    try {
      const automation = await Automation.findById(job.automationId);
      const user = await User.findById(job.userId);
      const token = user?.instagram?.accessToken || process.env.INSTAGRAM_ACCESS_TOKEN;
      const isDryRun = process.env.DRY_RUN === "true";

      if (!automation || automation.status !== "active") {
        await BackfillJob.updateOne(
          { _id: jobId },
          {
            isLocked: false,
            status: "paused",
            error: "Automation is inactive. Activate automation to process existing comments.",
          }
        );
        return;
      }

      if (!token) {
        await BackfillJob.updateOne(
          { _id: jobId },
          {
            isLocked: false,
            status: "failed",
            error: "Instagram access token missing or account disconnected",
            completedAt: new Date(),
          }
        );
        return;
      }

      console.log(`🚀 [Backfill Job Started] Processing ${job.actions.length} comments for post [${job.mediaId}]`);

      for (let i = 0; i < job.actions.length; i++) {
        const action = job.actions[i];
        const commentId = String(action.commentId);
        const username = action.username;
        const commentTimestamp = action.commentTimestamp ? new Date(action.commentTimestamp) : new Date();

        // Check if action was already fully processed successfully
        const isPublicDone = action.publicReply?.status === "sent" || action.publicReply?.status === "disabled" || action.publicReply?.status === "skipped";
        const isDmDone = action.privateReply?.status === "sent" || action.privateReply?.status === "disabled" || action.privateReply?.status === "skipped";

        if (action.status === "success" || (isPublicDone && isDmDone)) {
          continue; // Skip already completed action
        }

        // Recheck automation status periodically
        const currentAuto = await Automation.findById(job.automationId);
        if (!currentAuto || currentAuto.status !== "active") {
          console.warn(`⏸️ [Backfill Paused] Automation deactivated during execution.`);
          await BackfillJob.updateOne(
            { _id: jobId },
            {
              isLocked: false,
              status: "paused",
              error: "Automation was deactivated during execution. Resume after activating.",
            }
          );
          return;
        }

        // Anti-spam in-memory lock
        AutomationEngine.markProcessed(commentId);

        // Load persisted state from activityLog for idempotency
        const existingEntry = currentAuto.activityLog.find((e) => String(e.commentId) === commentId);
        const alreadyPublicSent = action.publicReply?.status === "sent" || Boolean(existingEntry?.publicReply?.sent);
        const alreadyDmSent = action.privateReply?.status === "sent" || Boolean(existingEntry?.privateReply?.sent);

        const publicEnabled = Boolean(currentAuto.publicReply?.enabled);
        const dmEnabled = Boolean(currentAuto.openingDm?.enabled);

        if ((!publicEnabled || alreadyPublicSent) && (!dmEnabled || alreadyDmSent)) {
          action.status = "already_processed";
          action.skipReason = "Already completed previously";
          action.processedAt = new Date();
          await BackfillJob.updateOne(
            { _id: jobId },
            {
              $set: { [`actions.${i}`]: action },
              $inc: { skippedCount: 1, processedCount: 1 },
            }
          );
          continue;
        }

        action.status = "processing";

        // Inner try/catch for member processing to isolate failures
        try {
          // Human-like pacing delay
          if (ANTI_SPAM_RULES?.ENABLE_HUMAN_DELAY && !isDryRun) {
            await sleep(Math.floor(Math.random() * 500 + 400));
          }

          const logEntry = existingEntry || {
            _id: new mongoose.Types.ObjectId(),
            commentId,
            commentTimestamp,
            username,
            text: action.text,
            ruleMatched: action.ruleMatched,
            source: "backfill",
            publicReply: { sent: false, status: "disabled", message: "", attempts: 0 },
            privateReply: { sent: false, status: "disabled", message: "", attempts: 0, retryEligible: false },
            timestamp: new Date(),
            isDuplicate: false,
            error: null,
          };
          logEntry.source = "backfill";

          let memberHasFailure = false;
          let memberHasSuccess = false;
          let memberIsAmbiguous = false;

          // ── 1. Execute Public Reply (if enabled and not already sent) ───────
          const igUserId = user?.instagram?.id || automation.userId?.toString() || "default";

          if (publicEnabled && !alreadyPublicSent) {
            const messages = currentAuto.publicReply.messages || [];
            const template = messages.length > 0
              ? messages[Math.floor(Math.random() * messages.length)]
              : "@{username} Thank you for your comment! Check your DMs! 📩";

            const formattedPublic = AutomationEngine.formatMessage(template, {
              username,
              productName: process.env.PRODUCT_NAME,
              price: process.env.PRODUCT_PRICE,
              link: process.env.PRODUCT_LINK,
            });

            action.publicReply.message = formattedPublic;
            logEntry.publicReply.message = formattedPublic;

            if (isDryRun) {
              action.publicReply.status = "skipped";
              logEntry.publicReply.status = "skipped";
              logEntry.publicReply.errorCategory = "DRY_RUN";
            } else {
              const pubClaim = await ActionLedgerService.claimAction({
                igUserId,
                mediaId: job.mediaId,
                commentId,
                recipientId: action.recipientId || null,
                username,
                actionType: "public_reply",
                automationId: job.automationId,
                jobId: job._id,
                source: "backfill",
              });

              if (!pubClaim.claimed) {
                if (pubClaim.status === "success" || pubClaim.status === "already_processed") {
                  action.publicReply.status = "sent";
                  logEntry.publicReply.sent = true;
                  logEntry.publicReply.status = "sent";
                  memberHasSuccess = true;
                } else if (pubClaim.status === "skipped") {
                  action.publicReply.status = "skipped";
                  action.publicReply.retryEligible = false;
                  logEntry.publicReply.status = "skipped";
                }
              } else {
                action.publicReply.attempts = (action.publicReply.attempts || 0) + 1;
                logEntry.publicReply.attempts = (logEntry.publicReply.attempts || 0) + 1;
                action.publicReply.lastAttemptAt = new Date();
                logEntry.publicReply.lastAttemptAt = new Date();

                // Bounded retry with backoff for transient errors
                let pubRes;
                for (let attempt = 1; attempt <= 2; attempt++) {
                  pubRes = await InstagramService.publishCommentReply(commentId, formattedPublic, token);
                  if (pubRes.ok || !pubRes.error?.isRetryable) break;
                  if (attempt < 2) await sleep(500 * attempt);
                }

                const pubKey = pubClaim.record?.actionKey || ActionLedgerService.buildActionKey({ igUserId, mediaId: job.mediaId, commentId, actionType: "public_reply" });

                if (pubRes.ok) {
                  await ActionLedgerService.finalizeAction({
                    actionKey: pubKey,
                    claimToken: pubClaim.claimToken,
                    result: pubRes,
                  });
                  action.publicReply.status = "sent";
                  action.publicReply.messageId = pubRes.replyId;
                  action.publicReply.error = null;
                  logEntry.publicReply.sent = true;
                  logEntry.publicReply.status = "sent";
                  logEntry.publicReply.messageId = pubRes.replyId;
                  logEntry.publicReply.lastSuccessAt = new Date();
                  memberHasSuccess = true;
                } else {
                  const err = pubRes.error || {};
                  const ineligibility = ActionLedgerService.classifyIneligibility(err);

                  if (ineligibility.isIneligible) {
                    await ActionLedgerService.finalizeAction({
                      actionKey: pubKey,
                      claimToken: pubClaim.claimToken,
                      error: err,
                      skipReason: ineligibility.reason,
                    });
                    action.publicReply.status = "skipped";
                    action.publicReply.error = err.message || "Public reply not eligible";
                    action.publicReply.errorCode = err.code || null;
                    action.publicReply.errorCategory = ineligibility.reason;
                    action.publicReply.retryEligible = false;
                    action.publicReply.retryReason = `Skipped: ${ineligibility.reason}`;

                    logEntry.publicReply.sent = false;
                    logEntry.publicReply.status = "skipped";
                    logEntry.publicReply.error = err.message || "Public reply not eligible";
                    logEntry.publicReply.errorCategory = ineligibility.reason;
                    logEntry.publicReply.retryEligible = false;
                    logEntry.publicReply.retryReason = `Skipped: ${ineligibility.reason}`;
                  } else {
                    await ActionLedgerService.finalizeAction({
                      actionKey: pubKey,
                      claimToken: pubClaim.claimToken,
                      error: err,
                      isAmbiguous: Boolean(err.isAmbiguous),
                    });
                    action.publicReply.status = err.isAmbiguous ? "unknown" : "failed";
                    action.publicReply.error = err.message || "Failed to publish reply";
                    action.publicReply.errorCode = err.code || null;
                    action.publicReply.errorCategory = err.category || "API_ERROR";
                    action.publicReply.retryEligible = !err.isAmbiguous && err.isRetryable !== false;
                    action.publicReply.retryReason = err.message;

                    logEntry.publicReply.sent = false;
                    logEntry.publicReply.status = err.isAmbiguous ? "unknown" : "failed";
                    logEntry.publicReply.error = err.message || "Failed to publish reply";
                    logEntry.publicReply.errorCode = err.code || null;
                    logEntry.publicReply.errorCategory = err.category || "API_ERROR";
                    logEntry.publicReply.lastFailedAt = new Date();
                    memberHasFailure = true;

                    // Check fatal token authorization failure
                    if (err.category === "TOKEN_EXPIRED" || err.code === 190 || err.category === "NO_TOKEN") {
                      await this._recordFatalError(jobId, action, i, logEntry, "Instagram authorization expired or revoked", currentAuto);
                      return;
                    }
                  }
                }
              }
            }
          } else if (alreadyPublicSent) {
            action.publicReply.status = "sent";
          }

          // ── 2. Execute Private Reply (if enabled and not already sent) ───────
          if (dmEnabled && !alreadyDmSent) {
            const commentAgeMs = Date.now() - commentTimestamp.getTime();
            const isWithin7Days = commentAgeMs <= MESSAGING_RULES.MAX_COMMENT_AGE_MS;

            const rawDm = currentAuto.openingDm.message || "";
            const formattedDm = AutomationEngine.formatMessage(rawDm, {
              username,
              productName: process.env.PRODUCT_NAME,
              price: process.env.PRODUCT_PRICE,
              link: currentAuto.openingDm.link || process.env.PRODUCT_LINK,
            });

            const hasButton = currentAuto.openingDm.buttonEnabled !== false &&
              Boolean(currentAuto.openingDm.buttonText?.trim()) &&
              Boolean(currentAuto.openingDm.link?.trim() || (currentAuto.openingDm.buttonEnabled && process.env.PRODUCT_LINK));

            const buttonText = hasButton ? (currentAuto.openingDm.buttonText || "Open Link").trim() : "";
            const linkUrl = hasButton ? (currentAuto.openingDm.link || process.env.PRODUCT_LINK || "").trim() : "";

            action.privateReply.message = formattedDm;
            logEntry.privateReply.message = formattedDm;
            action.privateReply.link = linkUrl;
            logEntry.privateReply.link = linkUrl;
            action.privateReply.buttonText = buttonText;
            logEntry.privateReply.buttonText = buttonText;

            if (!isWithin7Days) {
              action.privateReply.status = "skipped";
              action.privateReply.error = "Comment is older than 7 days (Meta policy expired)";
              action.privateReply.errorCategory = "WINDOW_CLOSED_7_DAYS";
              action.privateReply.retryEligible = false;
              action.privateReply.retryReason = "Comment is older than 7 days (Meta policy expired)";

              logEntry.privateReply.sent = false;
              logEntry.privateReply.status = "skipped";
              logEntry.privateReply.errorCategory = "WINDOW_CLOSED_7_DAYS";
              logEntry.privateReply.errorMessage = "Comment is older than 7 days (Meta policy expired)";
              logEntry.privateReply.retryEligible = false;
              logEntry.privateReply.retryReason = "Comment is older than 7 days (Meta policy expired)";

              const dmKey = ActionLedgerService.buildActionKey({ igUserId, mediaId: job.mediaId, commentId, actionType: "dm" });
              await ActionLedger.findOneAndUpdate(
                { actionKey: dmKey },
                {
                  $set: {
                    actionKey: dmKey,
                    igUserId: String(igUserId),
                    mediaId: String(job.mediaId).trim().split("_").pop(),
                    commentId: String(commentId),
                    recipientId: action.recipientId || null,
                    username,
                    actionType: "dm",
                    status: "skipped",
                    skipReason: "WINDOW_CLOSED_7_DAYS",
                    automationId: job.automationId,
                    jobId: job._id,
                    source: "backfill",
                    processedAt: new Date(),
                  },
                },
                { upsert: true }
              );
            } else if (isDryRun) {
              action.privateReply.status = "skipped";
              logEntry.privateReply.status = "skipped";
              logEntry.privateReply.errorCategory = "DRY_RUN";
            } else {
              // Atomically claim DM action via ActionLedger (enforces single DM per user & concurrency)
              const dmClaim = await ActionLedgerService.claimAction({
                igUserId,
                mediaId: job.mediaId,
                commentId,
                recipientId: action.recipientId || null,
                username,
                actionType: "dm",
                automationId: job.automationId,
                jobId: job._id,
                source: "backfill",
              });

              if (!dmClaim.claimed) {
                if (dmClaim.status === "success" || dmClaim.status === "already_processed") {
                  action.privateReply.status = "sent";
                  logEntry.privateReply.sent = true;
                  logEntry.privateReply.status = "sent";
                  memberHasSuccess = true;
                } else {
                  // User already received a DM or action is skipped
                  action.privateReply.status = "skipped";
                  action.privateReply.retryEligible = false;
                  action.privateReply.retryReason = dmClaim.reason || "Skipped";
                  logEntry.privateReply.sent = false;
                  logEntry.privateReply.status = "skipped";
                  logEntry.privateReply.retryEligible = false;
                  logEntry.privateReply.retryReason = dmClaim.reason || "Skipped";
                }
              } else {
                action.privateReply.attempts = (action.privateReply.attempts || 0) + 1;
                logEntry.privateReply.attempts = (logEntry.privateReply.attempts || 0) + 1;
                action.privateReply.lastAttemptAt = new Date();
                logEntry.privateReply.lastAttemptAt = new Date();

                let dmRes;
                for (let attempt = 1; attempt <= 2; attempt++) {
                  dmRes = await InstagramService.sendPrivateReply(
                    commentId,
                    formattedDm,
                    token,
                    buttonText,
                    linkUrl,
                    commentTimestamp,
                    action.recipientId || null
                  );
                  if (dmRes.ok || !dmRes.error?.isRetryable) break;
                  if (attempt < 2) await sleep(500 * attempt);
                }

                const dmKey = dmClaim.record?.actionKey || ActionLedgerService.buildActionKey({ igUserId, mediaId: job.mediaId, commentId, actionType: "dm" });

                if (dmRes.ok) {
                  await ActionLedgerService.finalizeAction({
                    actionKey: dmKey,
                    claimToken: dmClaim.claimToken,
                    result: dmRes,
                  });
                  action.privateReply.status = "sent";
                  action.privateReply.messageId = dmRes.messageId;
                  action.privateReply.error = null;
                  action.privateReply.retryEligible = false;
                  logEntry.privateReply.sent = true;
                  logEntry.privateReply.status = "sent";
                  logEntry.privateReply.messageId = dmRes.messageId;
                  logEntry.privateReply.lastSuccessAt = new Date();
                  logEntry.privateReply.retryEligible = false;
                  memberHasSuccess = true;
                } else {
                  const err = dmRes.error || {};
                  const metaClass = ActionLedgerService.classifyMetaError(err);

                  if (metaClass.isAlreadyReplied) {
                    await ActionLedgerService.finalizeAction({
                      actionKey: dmKey,
                      claimToken: dmClaim.claimToken,
                      error: err,
                    });
                    action.privateReply.status = "sent";
                    action.privateReply.messageId = dmRes.messageId || null;
                    action.privateReply.error = null;
                    action.privateReply.retryEligible = false;
                    action.privateReply.retryReason = "Confirmed already sent by Meta API";

                    logEntry.privateReply.sent = true;
                    logEntry.privateReply.status = "sent";
                    logEntry.privateReply.messageId = dmRes.messageId || null;
                    logEntry.privateReply.lastSuccessAt = new Date();
                    logEntry.privateReply.retryEligible = false;
                    memberHasSuccess = true;
                  } else if (metaClass.isIneligible) {
                    await ActionLedgerService.finalizeAction({
                      actionKey: dmKey,
                      claimToken: dmClaim.claimToken,
                      error: err,
                      skipReason: metaClass.reason,
                    });
                    action.privateReply.status = "skipped";
                    action.privateReply.skipReason = metaClass.reason;
                    action.skipReason = metaClass.reason;
                    action.privateReply.error = err.message || "Action not possible";
                    action.privateReply.errorCode = err.code || null;
                    action.privateReply.errorCategory = metaClass.reason;
                    action.privateReply.retryEligible = false;
                    action.privateReply.retryReason = `Skipped: ${metaClass.reason}`;

                    logEntry.privateReply.sent = false;
                    logEntry.privateReply.status = "skipped";
                    logEntry.privateReply.skipReason = metaClass.reason;
                    logEntry.privateReply.error = err.message || "Action not possible";
                    logEntry.privateReply.errorCode = err.code || null;
                    logEntry.privateReply.errorCategory = metaClass.reason;
                    logEntry.privateReply.retryEligible = false;
                    logEntry.privateReply.retryReason = `Skipped: ${metaClass.reason}`;
                    logEntry.privateReply.lastFailedAt = new Date();
                    // Ineligible action is skipped, not failed
                  } else if (err.isAmbiguous) {
                    await ActionLedgerService.finalizeAction({
                      actionKey: dmKey,
                      claimToken: dmClaim.claimToken,
                      error: err,
                      isAmbiguous: true,
                    });
                    action.privateReply.status = "unknown";
                    action.privateReply.error = err.message || "Ambiguous delivery outcome";
                    action.privateReply.errorCode = err.code || null;
                    action.privateReply.errorCategory = "AMBIGUOUS_DELIVERY";
                    action.privateReply.retryEligible = false;
                    action.privateReply.retryReason = "Ambiguous delivery outcome (timeout). Manual reconciliation required.";

                    logEntry.privateReply.sent = false;
                    logEntry.privateReply.status = "unknown";
                    logEntry.privateReply.error = err.message || "Ambiguous delivery outcome";
                    logEntry.privateReply.errorCategory = "AMBIGUOUS_DELIVERY";
                    logEntry.privateReply.retryEligible = false;
                    logEntry.privateReply.retryReason = "Ambiguous delivery outcome (timeout). Manual reconciliation required.";
                    memberHasFailure = false;
                    memberIsAmbiguous = true;
                  } else {
                    await ActionLedgerService.finalizeAction({
                      actionKey: dmKey,
                      claimToken: dmClaim.claimToken,
                      error: err,
                    });
                    action.privateReply.status = "failed";
                    action.privateReply.error = err.message || "Failed to send DM";
                    action.privateReply.errorCode = err.code || null;
                    action.privateReply.errorCategory = err.category || "API_ERROR";
                    action.privateReply.retryEligible = err.isRetryable !== false;
                    action.privateReply.retryReason = err.isRetryable !== false ? "Eligible for retry" : (err.message || "Retry not permitted");

                    logEntry.privateReply.sent = false;
                    logEntry.privateReply.status = "failed";
                    logEntry.privateReply.error = err.message || "Failed to send DM";
                    logEntry.privateReply.errorCode = err.code || null;
                    logEntry.privateReply.errorCategory = err.category || "API_ERROR";
                    logEntry.privateReply.lastFailedAt = new Date();
                    logEntry.privateReply.retryEligible = action.privateReply.retryEligible;
                    logEntry.privateReply.retryReason = action.privateReply.retryReason;
                    memberHasFailure = true;

                    // Check fatal token authorization failure
                    if (err.category === "TOKEN_EXPIRED" || err.code === 190 || err.category === "NO_TOKEN") {
                      await this._recordFatalError(jobId, action, i, logEntry, "Instagram authorization expired or revoked", currentAuto);
                      return;
                    }
                  }
                }
              }
            }
          } else if (alreadyDmSent) {
            action.privateReply.status = "sent";
          }

          // Determine final action status
          if (memberIsAmbiguous) {
            action.status = "unknown";
          } else if (memberHasFailure) {
            action.status = "failed";
          } else if (memberHasSuccess || alreadyPublicSent || alreadyDmSent) {
            action.status = "success";
          } else {
            action.status = "skipped";
          }

          action.processedAt = new Date();

          // Atomic persistence of member result into Automation activityLog & stats
          await this._persistMemberResult(currentAuto, logEntry, action, memberHasSuccess, memberHasFailure, isDryRun);

          // Atomic persistence of BackfillJob action and counters
          await this._persistJobAction(jobId, i, action, memberHasSuccess, memberHasFailure);

        } catch (memberErr) {
          console.error(`⚠️ [Backfill Member Error] Comment ${commentId}:`, memberErr);
          action.status = "failed";
          action.processedAt = new Date();
          if (action.publicReply?.status === "pending") {
            action.publicReply.status = "failed";
            action.publicReply.error = memberErr.message;
            action.publicReply.retryEligible = true;
          }
          if (action.privateReply?.status === "pending") {
            action.privateReply.status = "failed";
            action.privateReply.error = memberErr.message;
            action.privateReply.retryEligible = true;
          }
          await this._persistJobAction(jobId, i, action, false, true);
        }
      }

      // Calculate final job status after all members processed
      await this._finalizeJob(jobId);

    } catch (err) {
      console.error(`❌ [Backfill Job Fatal Error] Job ${jobId}:`, err);
      await BackfillJob.updateOne(
        { _id: jobId },
        {
          isLocked: false,
          status: "failed",
          error: err.message || "An unexpected error occurred during backfill",
          completedAt: new Date(),
        }
      );
    }
  }

  /**
   * Helper: Record fatal authorization error and abort remaining comments
   */
  static async _recordFatalError(jobId, action, index, logEntry, errorMsg, automation) {
    console.error(`🛑 [Backfill Fatal Error]: ${errorMsg}`);
    action.status = "failed";
    action.processedAt = new Date();

    await Automation.updateOne(
      { _id: automation._id },
      { $push: { activityLog: { $each: [logEntry], $slice: -500 } } }
    );

    await BackfillJob.updateOne(
      { _id: jobId },
      {
        $set: {
          [`actions.${index}`]: action,
          status: "failed",
          error: errorMsg,
          isLocked: false,
          completedAt: new Date(),
        },
        $inc: { failedCount: 1, processedCount: 1 },
      }
    );
  }

  /**
   * Helper: Atomically persist member action result into Automation activityLog & stats
   */
  static async _persistMemberResult(automation, logEntry, action, memberHasSuccess, memberHasFailure, isDryRun) {
    const commentId = String(logEntry.commentId);
    const existingIndex = automation.activityLog.findIndex((e) => String(e.commentId) === commentId);

    const updateOps = {};
    const statsInc = {};

    if (!isDryRun) {
      if (action.publicReply?.status === "sent") {
        statsInc["stats.repliesSent"] = 1;
      }
      if (action.privateReply?.status === "sent") {
        statsInc["stats.dmsSent"] = 1;
      }
      if (memberHasFailure) {
        statsInc["stats.failed"] = 1;
        statsInc["stats.totalFailedAttempts"] = 1;
      }
    }

    if (existingIndex >= 0) {
      updateOps.$set = {
        [`activityLog.${existingIndex}`]: logEntry,
      };
      if (Object.keys(statsInc).length > 0) {
        updateOps.$inc = statsInc;
      }
    } else {
      updateOps.$push = {
        activityLog: { $each: [logEntry], $slice: -500 },
      };
      if (Object.keys(statsInc).length > 0) {
        updateOps.$inc = statsInc;
      }
    }

    await Automation.updateOne({ _id: automation._id }, updateOps);
  }

  /**
   * Helper: Atomically update BackfillJob action and counters
   */
  static async _persistJobAction(jobId, index, action, memberHasSuccess, memberHasFailure) {
    const incOps = { processedCount: 1 };
    if (memberHasFailure) {
      incOps.failedCount = 1;
    } else if (memberHasSuccess) {
      incOps.successCount = 1;
    } else {
      incOps.skippedCount = 1;
    }

    await BackfillJob.updateOne(
      { _id: jobId },
      {
        $set: { [`actions.${index}`]: action },
        $inc: incOps,
      }
    );
  }

  /**
   * Helper: Reconcile final status and counts directly from authoritative actions array
   */
  static async _finalizeJob(jobId) {
    const finalJob = await BackfillJob.findById(jobId);
    if (!finalJob) return;

    let success = 0;
    let failed = 0;
    let skipped = 0;
    let pending = 0;
    let hasAnySuccess = false;
    let hasAnyFailure = false;

    for (const a of finalJob.actions) {
      const pubSent = a.publicReply?.status === "sent";
      const dmSent = a.privateReply?.status === "sent";
      const pubFailed = a.publicReply?.status === "failed";
      const dmFailed = a.privateReply?.status === "failed";

      if (pubSent || dmSent) hasAnySuccess = true;
      if (pubFailed || dmFailed) hasAnyFailure = true;

      if (a.status === "success" || a.status === "sent") success++;
      else if (a.status === "failed") failed++;
      else if (a.status === "skipped" || a.status === "already_processed" || a.status === "already_sent" || a.status === "unknown" || a.status === "reconciliation_required") skipped++;
      else pending++;
    }

    let finalStatus = "completed";
    if (pending > 0) {
      finalStatus = "paused";
    } else if (failed > 0 || hasAnyFailure) {
      finalStatus = (success > 0 || hasAnySuccess) ? "completed_with_errors" : "failed";
    }

    await BackfillJob.updateOne(
      { _id: jobId },
      {
        status: finalStatus,
        successCount: success,
        failedCount: failed,
        skippedCount: skipped,
        processedCount: success + failed + skipped,
        isLocked: false,
        lockToken: null,
        lockExpiresAt: null,
        completedAt: finalStatus === "paused" ? null : new Date(),
      }
    );

    console.log(`✅ [Backfill Job Completed] Job ${jobId} finished with status: ${finalStatus} (${success} success, ${failed} failed, ${skipped} skipped)`);
  }

  /**
   * Retry failed actions (DMs and public replies) from a specific BackfillJob
   * Idempotent: only retries retryable failed actions, never duplicates sent ones
   */
  static async retryJob(jobId, userId) {
    const now = new Date();
    const lockToken = crypto.randomUUID();

    // Concurrency protection: atomically acquire execution lock FIRST
    const lockedJob = await BackfillJob.findOneAndUpdate(
      {
        _id: jobId,
        userId,
        $or: [{ isLocked: { $ne: true } }, { lockExpiresAt: { $lt: now } }],
      },
      {
        $set: {
          isLocked: true,
          lockToken,
          lockExpiresAt: new Date(now.getTime() + 15 * 60 * 1000),
        },
      },
      { returnDocument: "after" }
    );

    if (!lockedJob) {
      return { ok: false, error: "Job is already being processed or retried by another worker", isAlreadyRunning: true };
    }

    const job = lockedJob;

    try {
      const { automation, user, token } = await this.validatePreconditions(userId, job.automationId, job.mediaId);

      // Filter retryable actions
      const retryableActions = [];
      for (const a of job.actions) {
        const canRetryDm = a.privateReply?.status === "failed" && a.privateReply?.retryEligible !== false;
        const canRetryPub = a.publicReply?.status === "failed" && a.publicReply?.retryEligible !== false;
        if (canRetryDm || canRetryPub) {
          retryableActions.push(a);
        }
      }

      if (retryableActions.length === 0) {
        await BackfillJob.updateOne({ _id: jobId, lockToken }, { $set: { isLocked: false, lockToken: null, lockExpiresAt: null } });
        return { ok: false, error: "No eligible failed actions to retry" };
      }

      let retriedCount = 0;
      let successCount = 0;
      let failedCount = 0;

      for (const action of retryableActions) {
        retriedCount++;
        const commentId = String(action.commentId);
        const commentTimestamp = action.commentTimestamp ? new Date(action.commentTimestamp) : new Date();
        const igUserId = user?.instagram?.id || automation.userId?.toString() || "default";

        let dmSuccess = false;
        let pubSuccess = false;
        let hasError = false;

        // 1. Retry failed Public Reply
        if (action.publicReply?.status === "failed" && action.publicReply?.retryEligible !== false) {
          const pubCheck = await ActionLedgerService.checkAlreadySent({
            igUserId,
            mediaId: job.mediaId,
            commentId,
            actionType: "public_reply",
          });

          if (pubCheck.isAlreadySent && ActionLedgerService.isSentStatus(pubCheck.status)) {
            action.publicReply.status = "sent";
            action.publicReply.error = null;
            pubSuccess = true;
          } else {
            const claimRes = await ActionLedgerService.claimAction({
              igUserId,
              mediaId: job.mediaId,
              commentId,
              recipientId: action.recipientId || null,
              username: action.username,
              actionType: "public_reply",
              automationId: job.automationId,
              jobId: job._id,
              source: "retry",
            });

            if (claimRes.claimed) {
              const pubMsg = action.publicReply.message || "@{username} Thank you for your comment! Check your DMs! 📩";
              const pubRes = await InstagramService.publishCommentReply(commentId, pubMsg, token);
              const pubKey = claimRes.record?.actionKey || ActionLedgerService.buildActionKey({ igUserId, mediaId: job.mediaId, commentId, actionType: "public_reply" });

              if (pubRes.ok) {
                await ActionLedgerService.finalizeAction({ actionKey: pubKey, claimToken: claimRes.claimToken, result: pubRes });
                action.publicReply.status = "sent";
                action.publicReply.messageId = pubRes.replyId;
                action.publicReply.error = null;
                pubSuccess = true;
              } else {
                const metaClass = ActionLedgerService.classifyMetaError(pubRes.error);
                if (metaClass.isAlreadyReplied) {
                  await ActionLedgerService.finalizeAction({ actionKey: pubKey, claimToken: claimRes.claimToken, error: pubRes.error });
                  action.publicReply.status = "sent";
                  action.publicReply.messageId = pubRes.replyId || null;
                  action.publicReply.error = null;
                  pubSuccess = true;
                } else if (metaClass.isIneligible) {
                  await ActionLedgerService.finalizeAction({ actionKey: pubKey, claimToken: claimRes.claimToken, error: pubRes.error, skipReason: metaClass.reason });
                  action.publicReply.status = "skipped";
                  action.publicReply.retryEligible = false;
                  action.publicReply.retryReason = `Skipped: ${metaClass.reason}`;
                } else {
                  await ActionLedgerService.finalizeAction({ actionKey: pubKey, claimToken: claimRes.claimToken, error: pubRes.error });
                  action.publicReply.error = pubRes.error?.message || "Retry failed";
                  action.publicReply.attempts = (action.publicReply.attempts || 0) + 1;
                  hasError = true;
                }
              }
            }
          }
        }

        // 2. Retry failed DM
        if (action.privateReply?.status === "failed" && action.privateReply?.retryEligible !== false) {
          const commentAgeMs = Date.now() - commentTimestamp.getTime();
          const isWithin7Days = commentAgeMs <= MESSAGING_RULES.MAX_COMMENT_AGE_MS;

          if (!isWithin7Days) {
            action.privateReply.status = "skipped";
            action.privateReply.errorCategory = "WINDOW_CLOSED_7_DAYS";
            action.privateReply.retryEligible = false;
            action.privateReply.retryReason = "Comment is older than 7 days (Meta policy expired)";
          } else {
            const dmCheck = await ActionLedgerService.checkAlreadySent({
              igUserId,
              mediaId: job.mediaId,
              commentId,
              recipientId: action.recipientId || null,
              actionType: "dm",
            });

            if (dmCheck.isAlreadySent) {
              if (ActionLedgerService.isSentStatus(dmCheck.status) || ActionLedgerService.isSentStatus(dmCheck.record?.status)) {
                action.privateReply.status = "sent";
                action.privateReply.error = null;
                action.privateReply.retryEligible = false;
                dmSuccess = true;
              } else {
                action.privateReply.status = "skipped";
                action.privateReply.retryEligible = false;
                action.privateReply.retryReason = dmCheck.reason || "Already sent to user";
              }
            } else {
              const claimRes = await ActionLedgerService.claimAction({
                igUserId,
                mediaId: job.mediaId,
                commentId,
                recipientId: action.recipientId || null,
                username: action.username,
                actionType: "dm",
                automationId: job.automationId,
                jobId: job._id,
                source: "retry",
              });

              if (claimRes.claimed) {
                const buttonText = action.privateReply.buttonText || automation.openingDm?.buttonText || "Open Link";
                const linkUrl = action.privateReply.link || automation.openingDm?.link || "";

                const dmRes = await InstagramService.sendPrivateReply(
                  commentId,
                  action.privateReply.message,
                  token,
                  buttonText,
                  linkUrl,
                  commentTimestamp,
                  action.recipientId || null
                );
                const dmKey = claimRes.record?.actionKey || ActionLedgerService.buildActionKey({ igUserId, mediaId: job.mediaId, commentId, actionType: "dm" });

                if (dmRes.ok) {
                  await ActionLedgerService.finalizeAction({ actionKey: dmKey, claimToken: claimRes.claimToken, result: dmRes });
                  action.privateReply.status = "sent";
                  action.privateReply.messageId = dmRes.messageId;
                  action.privateReply.error = null;
                  action.privateReply.retryEligible = false;
                  dmSuccess = true;
                } else {
                  const metaClass = ActionLedgerService.classifyMetaError(dmRes.error);
                  if (metaClass.isAlreadyReplied) {
                    await ActionLedgerService.finalizeAction({ actionKey: dmKey, claimToken: claimRes.claimToken, error: dmRes.error });
                    action.privateReply.status = "sent";
                    action.privateReply.messageId = dmRes.messageId || null;
                    action.privateReply.error = null;
                    action.privateReply.retryEligible = false;
                    action.privateReply.retryReason = "Confirmed already sent by Meta API";
                    dmSuccess = true;
                  } else if (metaClass.isIneligible) {
                    await ActionLedgerService.finalizeAction({ actionKey: dmKey, claimToken: claimRes.claimToken, error: dmRes.error, skipReason: metaClass.reason });
                    action.privateReply.status = "skipped";
                    action.privateReply.retryEligible = false;
                    action.privateReply.retryReason = `Skipped: ${metaClass.reason}`;
                  } else if (dmRes.error?.isAmbiguous) {
                    await ActionLedgerService.finalizeAction({ actionKey: dmKey, claimToken: claimRes.claimToken, error: dmRes.error, isAmbiguous: true });
                    action.privateReply.status = "unknown";
                    action.privateReply.retryEligible = false;
                    action.privateReply.retryReason = "Ambiguous delivery outcome";
                    hasError = true;
                  } else {
                    await ActionLedgerService.finalizeAction({ actionKey: dmKey, claimToken: claimRes.claimToken, error: dmRes.error });
                    action.privateReply.error = dmRes.error?.message || "Retry failed";
                    action.privateReply.attempts = (action.privateReply.attempts || 0) + 1;
                    hasError = true;
                  }
                }
              }
            }
          }
        }

        // Update action overall status
        if (!hasError && (pubSuccess || dmSuccess || action.publicReply?.status === "sent" || action.privateReply?.status === "sent")) {
          action.status = "success";
          successCount++;
        } else if (action.publicReply?.status === "skipped" && action.privateReply?.status === "skipped") {
          action.status = "skipped";
        } else {
          action.status = "failed";
          failedCount++;
        }

        action.processedAt = new Date();

        // Atomically update action within BackfillJob
        const actionIdx = job.actions.findIndex((a) => String(a.commentId) === commentId);
        if (actionIdx >= 0) {
          await BackfillJob.updateOne(
            { _id: jobId },
            { $set: { [`actions.${actionIdx}`]: action } }
          );
        }

        // Atomically update Automation activityLog & stats without .save()
        const existingIdx = automation.activityLog.findIndex((e) => String(e.commentId) === commentId);
        const updateOps = {};
        const statsInc = {};

        if (pubSuccess) statsInc["stats.repliesSent"] = 1;
        if (dmSuccess) statsInc["stats.dmsSent"] = 1;
        if (!hasError && (pubSuccess || dmSuccess)) statsInc["stats.failed"] = -1;

        if (existingIdx >= 0) {
          const setFields = {};
          if (pubSuccess) {
            setFields[`activityLog.${existingIdx}.publicReply.sent`] = true;
            setFields[`activityLog.${existingIdx}.publicReply.status`] = "sent";
            setFields[`activityLog.${existingIdx}.publicReply.lastSuccessAt`] = new Date();
          }
          if (dmSuccess) {
            setFields[`activityLog.${existingIdx}.privateReply.sent`] = true;
            setFields[`activityLog.${existingIdx}.privateReply.status`] = "sent";
            setFields[`activityLog.${existingIdx}.privateReply.retryEligible`] = false;
            setFields[`activityLog.${existingIdx}.privateReply.retryReason`] = "Delivered on retry";
            setFields[`activityLog.${existingIdx}.privateReply.lastSuccessAt`] = new Date();
          }
          if (Object.keys(setFields).length > 0) updateOps.$set = setFields;
        }
        if (Object.keys(statsInc).length > 0) updateOps.$inc = statsInc;

        if (Object.keys(updateOps).length > 0) {
          await Automation.updateOne({ _id: automation._id }, updateOps);
        }
      }

      // Reconcile and finalize BackfillJob counts atomically
      await this._finalizeJob(jobId);

      const refreshedJob = await BackfillJob.findById(jobId);

      return {
        ok: true,
        retriedCount,
        successCount,
        failedCount,
        job: refreshedJob,
      };
    } finally {
      await BackfillJob.updateOne(
        { _id: jobId, lockToken },
        { $set: { isLocked: false, lockToken: null, lockExpiresAt: null } }
      ).catch(() => {});
    }
  }
}

module.exports = BackfillService;
