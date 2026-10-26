// ════════════════════════════════════════════════════════════════════════════
// InstaAuto — Action Ledger & Strong Idempotency Service
// Implements canonical action state machine, atomic distributed leases,
// duplicate DM prevention, and Meta already-sent reconciliation.
// ════════════════════════════════════════════════════════════════════════════

const crypto = require("crypto");
const ActionLedger = require("../models/ActionLedger");
const EligibilityService = require("./eligibilityService");
const { MESSAGING_RULES } = require("../config/instagramRules");

// Canonical Action States
const ACTION_STATES = {
  PENDING: "pending",
  PROCESSING: "processing",
  SENT: "sent",
  SKIPPED: "skipped",
  FAILED: "failed",
  UNKNOWN: "unknown",
  RECONCILIATION_REQUIRED: "reconciliation_required",
};

class ActionLedgerService {
  static get STATES() {
    return ACTION_STATES;
  }

  /**
   * Helper to check if a status represents confirmed or reconciled delivery.
   */
  static isSentStatus(status) {
    return status === "sent" || status === "success" || status === "already_processed" || status === "already_sent";
  }

  /**
   * Build consistent, deterministic actionKey
   */
  static buildActionKey({ igUserId, mediaId, commentId, actionType }) {
    const cleanMedia = String(mediaId || "").trim().split("_").pop();
    const cleanUser = String(igUserId || "default").trim();
    const cleanComment = String(commentId || "").trim();
    return `${cleanUser}:${cleanMedia}:${cleanComment}:${actionType}`;
  }

  /**
   * Inspect Meta API error payload to distinguish confirmed already-sent delivery
   * from ineligibility skips and technical failures.
   */
  static classifyMetaError(err) {
    if (!err) return { isError: false };

    const code = Number(err.code || err.errorCode);
    const subcode = Number(err.subcode || err.errorSubcode);
    const category = String(err.category || err.errorCategory || "");
    const msg = String(err.message || "").toLowerCase();

    // 1. Confirmed prior delivery by Meta (Private Reply Already Sent)
    const isAlreadyReplied =
      subcode === 2018002 ||
      category === "ALREADY_REPLIED" ||
      msg.includes("already replied") ||
      msg.includes("already been sent") ||
      msg.includes("cannot be replied to more than once");

    if (isAlreadyReplied) {
      return {
        isAlreadyReplied: true,
        isIneligible: false,
        isRetryable: false,
        category: "ALREADY_REPLIED",
        reason: "ALREADY_REPLIED_META",
        message: "A private reply has already been sent for this comment per Meta Graph API",
      };
    }

    // 2. Comment age > 7 days per Meta Messaging Policy
    if (
      category === "WINDOW_CLOSED_7_DAYS" ||
      subcode === 2018001 ||
      msg.includes("7 days") ||
      msg.includes("older than 7 days") ||
      msg.includes("window closed")
    ) {
      return {
        isAlreadyReplied: false,
        isIneligible: true,
        isRetryable: false,
        category: "WINDOW_CLOSED_7_DAYS",
        reason: "WINDOW_CLOSED_7_DAYS",
        message: "Comment is older than 7 days (Meta policy expired)",
      };
    }

    // 3. Recipient message window closed (24h standard messaging window)
    if (subcode === 2534022 || msg.includes("outside of allowed window")) {
      return {
        isAlreadyReplied: false,
        isIneligible: true,
        isRetryable: false,
        category: "WINDOW_CLOSED_24H",
        reason: "WINDOW_CLOSED_24H",
        message: "Recipient is outside allowed messaging window",
      };
    }

    // 4. Recipient not found on Instagram
    if (subcode === 2534014 || (code === 100 && msg.includes("user cannot be found"))) {
      return {
        isAlreadyReplied: false,
        isIneligible: true,
        isRetryable: false,
        category: "RECIPIENT_NOT_FOUND",
        reason: "RECIPIENT_NOT_FOUND",
        message: "Instagram recipient not found",
      };
    }

    // 5. Meta App Development Mode restriction — Only classify when explicitly stated!
    // Do NOT treat generic Code 1 as dev-mode unless message or context confirms it.
    if (
      code === 1 &&
      (msg.includes("instagram testers") || msg.includes("development mode") || msg.includes("developer mode"))
    ) {
      return {
        isAlreadyReplied: false,
        isIneligible: true,
        isRetryable: false,
        category: "DEV_MODE_RESTRICTION",
        reason: "DEV_MODE_RESTRICTION",
        message: "Meta App in development mode: delivery restricted to tester accounts",
      };
    }

    // 6. Rate limits
    if (category === "RATE_LIMIT" || [4, 17, 32, 613].includes(code) || msg.includes("rate limit") || msg.includes("calls have exceeded")) {
      return {
        isAlreadyReplied: false,
        isIneligible: false,
        isRetryable: true,
        category: "RATE_LIMIT",
        reason: "RATE_LIMIT_EXCEEDED",
        message: "Meta API rate limit exceeded",
      };
    }

    // 7. Authorization / Token Expired
    if (category === "TOKEN_EXPIRED" || [190, 463, 467].includes(code) || msg.includes("token expired") || msg.includes("invalid token")) {
      return {
        isAlreadyReplied: false,
        isIneligible: false,
        isRetryable: false,
        category: "TOKEN_EXPIRED",
        reason: "TOKEN_EXPIRED",
        message: "Instagram authorization expired. Reconnection required.",
      };
    }

    // 8. Explicit ineligibility flag passed from caller
    if (err.isIneligible === true) {
      return {
        isAlreadyReplied: false,
        isIneligible: true,
        isRetryable: false,
        category: err.category || "INELIGIBLE",
        reason: err.reason || "NOT_ELIGIBLE",
        message: err.message || "Action not eligible",
      };
    }

    // 9. Network timeouts & ambiguous aborts (marked ambiguous or timeout)
    if (err.isTimeout || err.isAmbiguous || err.category === "AMBIGUOUS_TIMEOUT" || (err.code === "ETIMEDOUT" && err.isRetryable === false)) {
      return {
        isAlreadyReplied: false,
        isIneligible: false,
        isRetryable: false,
        isTimeout: true,
        isAmbiguous: true,
        category: "NETWORK_TIMEOUT",
        reason: "AMBIGUOUS_TIMEOUT",
        message: err.message || "Network timeout during API call",
      };
    }

    // 10. Generic API / network error
    return {
      isAlreadyReplied: false,
      isIneligible: false,
      isRetryable: err.isRetryable !== false,
      category: category || "API_ERROR",
      reason: category || "API_ERROR",
      message: err.message || "Meta API error",
    };
  }

  /**
   * Legacy backward-compatibility wrapper for classifyIneligibility
   */
  static classifyIneligibility(err) {
    const classified = this.classifyMetaError(err);
    return {
      isIneligible: classified.isIneligible,
      reason: classified.reason,
      isAlreadyReplied: classified.isAlreadyReplied,
    };
  }

  /**
   * Evaluate DM and Public Reply eligibility before claiming or sending
   */
  static checkPreSendEligibility({ actionType, commentTimestamp, recipientId, username, botUsername, botUserId, automation = null }) {
    return EligibilityService.evaluateEligibility({
      actionType,
      commentTimestamp,
      recipientId,
      username,
      botUsername,
      botUserId,
      automation,
    });
  }

  /**
   * Check if action or recipient has already received a message on this media post
   */
  static async checkAlreadySent({ igUserId, mediaId, commentId, recipientId, actionType }) {
    const cleanMedia = String(mediaId || "").trim().split("_").pop();
    const actionKey = this.buildActionKey({ igUserId, mediaId: cleanMedia, commentId, actionType });

    // 1. Direct check on this exact comment action in ActionLedger
    const existing = await ActionLedger.findOne({ actionKey });
    if (existing) {
      if (this.isSentStatus(existing.status)) {
        return {
          isAlreadySent: true,
          status: "sent",
          canonicalStatus: ACTION_STATES.SENT,
          reason: "ALREADY_SENT",
          record: existing,
        };
      }
      if (existing.status === ACTION_STATES.SKIPPED) {
        return {
          isAlreadySent: true,
          status: "skipped",
          canonicalStatus: ACTION_STATES.SKIPPED,
          reason: existing.skipReason || "SKIPPED_PREVIOUSLY",
          record: existing,
        };
      }
      if (existing.status === ACTION_STATES.UNKNOWN || existing.status === ACTION_STATES.RECONCILIATION_REQUIRED) {
        return {
          isAlreadySent: true,
          status: existing.status,
          canonicalStatus: existing.status,
          reason: "AMBIGUOUS_OUTCOME",
          record: existing,
        };
      }
    }

    // 2. Single-DM-per-user-per-post rule: If a DM was already delivered to this recipient on this post
    if (actionType === "dm" && recipientId) {
      const priorUserDm = await ActionLedger.findOne({
        igUserId: String(igUserId),
        mediaId: cleanMedia,
        recipientId: String(recipientId),
        actionType: "dm",
        status: { $in: ["sent", "success", "already_processed", "already_sent"] },
      });

      if (priorUserDm) {
        return {
          isAlreadySent: true,
          status: "skipped",
          canonicalStatus: ACTION_STATES.SKIPPED,
          reason: "ALREADY_SENT_TO_USER",
          record: priorUserDm,
        };
      }
    }

    return { isAlreadySent: false };
  }

  /**
   * Atomically claim an action for execution using distributed lease semantics
   */
  static async claimAction({
    igUserId,
    mediaId,
    commentId,
    recipientId = null,
    username = "unknown",
    actionType,
    automationId = null,
    jobId = null,
    source = "webhook",
    leaseDurationMs = 30000,
  }) {
    const cleanMedia = String(mediaId || "").trim().split("_").pop();
    const actionKey = this.buildActionKey({ igUserId, mediaId: cleanMedia, commentId, actionType });
    const now = new Date();
    const expiresAt = new Date(now.getTime() + leaseDurationMs);
    const claimToken = crypto.randomUUID();

    // 1. Check if already completed, skipped, or delivered to this user on this post
    const checkResult = await this.checkAlreadySent({
      igUserId,
      mediaId: cleanMedia,
      commentId,
      recipientId,
      actionType,
    });

    if (checkResult.isAlreadySent) {
      if (checkResult.reason === "ALREADY_SENT_TO_USER") {
        // Record this specific comment action as skipped (ALREADY_SENT_TO_USER)
        const skippedRecord = await ActionLedger.findOneAndUpdate(
          { actionKey },
          {
            $set: {
              actionKey,
              igUserId: String(igUserId),
              mediaId: cleanMedia,
              commentId: String(commentId),
              recipientId: recipientId ? String(recipientId) : null,
              username: username || "unknown",
              actionType,
              status: ACTION_STATES.SKIPPED,
              skipReason: "ALREADY_SENT_TO_USER",
              automationId,
              jobId,
              source,
              processedAt: now,
            },
          },
          { upsert: true, returnDocument: "after" }
        );
        return { claimed: false, status: ACTION_STATES.SKIPPED, reason: "ALREADY_SENT_TO_USER", record: skippedRecord };
      }

      return {
        claimed: false,
        status: checkResult.status,
        canonicalStatus: checkResult.canonicalStatus,
        reason: checkResult.reason,
        record: checkResult.record,
      };
    }

    // 2. Ambiguous delivery outcome check: Never allow automatic claim without reconciliation
    const existingRecord = await ActionLedger.findOne({ actionKey });
    if (existingRecord) {
      if (this.isSentStatus(existingRecord.status)) {
        return {
          claimed: false,
          status: ACTION_STATES.SENT,
          reason: "ALREADY_SENT",
          record: existingRecord,
        };
      }
      if (existingRecord.status === ACTION_STATES.SKIPPED) {
        return {
          claimed: false,
          status: ACTION_STATES.SKIPPED,
          reason: existingRecord.skipReason || "SKIPPED_PERMANENTLY",
          record: existingRecord,
        };
      }
      if (existingRecord.status === ACTION_STATES.UNKNOWN || existingRecord.status === ACTION_STATES.RECONCILIATION_REQUIRED) {
        return {
          claimed: false,
          status: existingRecord.status,
          reason: "RECONCILIATION_REQUIRED",
          record: existingRecord,
        };
      }
      // If currently processing with a valid unexpired lease, reject concurrent worker
      if (existingRecord.status === ACTION_STATES.PROCESSING && existingRecord.claimExpiresAt && existingRecord.claimExpiresAt > now) {
        return {
          claimed: false,
          status: ACTION_STATES.PROCESSING,
          reason: "CONCURRENT_CLAIM",
          record: existingRecord,
        };
      }
    }

    // 3. Atomically claim via findOneAndUpdate
    try {
      const filter = {
        actionKey,
        status: { $in: [ACTION_STATES.PENDING, ACTION_STATES.FAILED, ACTION_STATES.PROCESSING] },
        $or: [{ claimExpiresAt: null }, { claimExpiresAt: { $lt: now } }],
      };

      const update = {
        $set: {
          actionKey,
          igUserId: String(igUserId),
          mediaId: cleanMedia,
          commentId: String(commentId),
          recipientId: recipientId ? String(recipientId) : null,
          username: username || "unknown",
          actionType,
          status: ACTION_STATES.PROCESSING,
          claimToken,
          claimExpiresAt: expiresAt,
          automationId,
          jobId,
          source,
          lastAttemptAt: now,
        },
        $inc: { attempts: 1 },
      };

      const claimedRecord = await ActionLedger.findOneAndUpdate(filter, update, {
        upsert: !existingRecord, // Only upsert if record doesn't exist to prevent accidental duplicate key races
        returnDocument: "after",
      });

      if (!claimedRecord) {
        // Another worker claimed it or updated it between check and findOneAndUpdate
        const refreshed = await ActionLedger.findOne({ actionKey });
        return {
          claimed: false,
          status: refreshed?.status || ACTION_STATES.PROCESSING,
          reason: "CONCURRENT_CLAIM",
          record: refreshed,
        };
      }

      const isRecovery = Boolean(existingRecord && existingRecord.status === ACTION_STATES.PROCESSING);
      return { claimed: true, claimToken, record: claimedRecord, isRecovery };
    } catch (err) {
      if (err.code === 11000) {
        const refreshed = await ActionLedger.findOne({ actionKey });
        return {
          claimed: false,
          status: refreshed?.status || ACTION_STATES.PROCESSING,
          reason: "CONCURRENT_CLAIM",
          record: refreshed,
        };
      }
      throw err;
    }
  }

  /**
   * Finalize action state after execution with strict state-machine transitions
   */
  static async finalizeAction({
    actionKey,
    claimToken = null,
    result = null,
    error = null,
    isAmbiguous = false,
    skipReason = null,
  }) {
    const now = new Date();
    const updateSet = {
      claimToken: null,
      claimExpiresAt: null,
      processedAt: now,
    };

    const errToInspect = error || result?.error;

    if (result && result.ok) {
      // Confirmed successful delivery
      updateSet.status = ACTION_STATES.SENT;
      updateSet.messageId = result.messageId || result.replyId || null;
      updateSet.error = null;
      updateSet.errorCode = null;
      updateSet.errorCategory = null;
      updateSet.skipReason = null;
      updateSet.isRetryable = false;
      updateSet.isAmbiguous = false;
    } else if (skipReason) {
      // Explicitly skipped (terminal policy window closed, already sent to user, self comment, etc.)
      updateSet.status = ACTION_STATES.SKIPPED;
      updateSet.skipReason = skipReason;
      updateSet.error = errToInspect?.message || null;
      updateSet.errorCode = errToInspect?.code || null;
      updateSet.errorCategory = errToInspect?.category || null;
      updateSet.isRetryable = false;
      updateSet.isAmbiguous = false;
    } else if (errToInspect) {
      const metaClassification = this.classifyMetaError(errToInspect);

      if (metaClassification.isAlreadyReplied) {
        // Requirement 2.B: Meta confirms already replied.
        // Must NOT classify as failed or skipped! Map to canonical 'sent' state with reconciliation metadata.
        updateSet.status = ACTION_STATES.SENT;
        updateSet.reconciledAt = now;
        updateSet.reconciliationReason = "ALREADY_REPLIED_META";
        updateSet.reconciledFrom = "meta_graph_api";
        updateSet.error = null;
        updateSet.errorCode = null;
        updateSet.errorCategory = "ALREADY_REPLIED";
        updateSet.skipReason = null;
        updateSet.isRetryable = false;
        updateSet.isAmbiguous = false;
        // Preserve original message ID if provided; do NOT invent a messageId
        if (result?.messageId || errToInspect?.messageId) {
          updateSet.messageId = result?.messageId || errToInspect?.messageId;
        }
      } else if (metaClassification.isIneligible) {
        // Permanent terminal ineligibility
        updateSet.status = ACTION_STATES.SKIPPED;
        updateSet.skipReason = metaClassification.reason;
        updateSet.error = errToInspect.message;
        updateSet.errorCode = errToInspect.code || null;
        updateSet.errorCategory = metaClassification.category;
        updateSet.isRetryable = false;
        updateSet.isAmbiguous = false;
      } else if (isAmbiguous || errToInspect.isAmbiguous || metaClassification.isAmbiguous || metaClassification.isTimeout) {
        // Ambiguous timeout: do not blindly retry
        updateSet.status = ACTION_STATES.UNKNOWN;
        updateSet.error = errToInspect.message || "Ambiguous delivery outcome (network timeout)";
        updateSet.errorCategory = "AMBIGUOUS_DELIVERY";
        updateSet.skipReason = "AMBIGUOUS_OUTCOME";
        updateSet.isAmbiguous = true;
        updateSet.isRetryable = false; // requires reconciliation before retry
      } else {
        // Definitive failure
        updateSet.status = ACTION_STATES.FAILED;
        updateSet.error = errToInspect.message || "Failed to deliver message";
        updateSet.errorCode = errToInspect.code || null;
        updateSet.errorCategory = errToInspect.category || "API_ERROR";
        updateSet.isRetryable = metaClassification.isRetryable;
        updateSet.isAmbiguous = false;
      }
    } else {
      updateSet.status = ACTION_STATES.FAILED;
      updateSet.error = "Unknown execution failure";
      updateSet.isRetryable = true;
    }

    // Only update if claimToken matches (prevent stale worker from overwriting finalized state)
    const filter = claimToken ? { actionKey, claimToken } : { actionKey };
    const finalized = await ActionLedger.findOneAndUpdate(filter, { $set: updateSet }, { returnDocument: "after" });

    return finalized;
  }
}

module.exports = ActionLedgerService;
