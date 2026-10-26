// ════════════════════════════════════════════════════════════════════════════
// Instagram Automation Engine
// Core processing pipeline strictly following Meta Instagram Automation Rules
// ════════════════════════════════════════════════════════════════════════════
const mongoose = require("mongoose");
const Automation = require("../models/Automation");
const User = require("../models/User");
const ActionLedger = require("../models/ActionLedger");
const InstagramService = require("./instagramService");
const ActionLedgerService = require("./actionLedgerService");
const EligibilityService = require("./eligibilityService");
const { ANTI_SPAM_RULES, MESSAGING_RULES } = require("../config/instagramRules");

// In-memory cache for fast deduplication & user cooldown
const processedComments = new Map(); // commentId -> timestamp
const userLastInteraction = new Map(); // `${igUserId}_${commenterUsername}` -> timestamp

// Helper to escape regex special characters
function escapeRegex(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Helper to sleep for human-like pacing
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

class AutomationEngine {
  /**
   * Deduplication check: Has this comment been processed within the dedup window?
   */
  static isDuplicate(commentId) {
    const ts = processedComments.get(commentId);
    return ts && Date.now() - ts < ANTI_SPAM_RULES.DEDUP_WINDOW_MS;
  }

  static markProcessed(commentId) {
    processedComments.set(commentId, Date.now());
    // Prune stale entries
    const now = Date.now();
    for (const [k, ts] of processedComments) {
      if (now - ts > ANTI_SPAM_RULES.DEDUP_WINDOW_MS) {
        processedComments.delete(k);
      }
    }
  }

  /**
   * User cooldown: Prevent spamming a user if they post multiple comments rapidly
   */
  static checkUserCooldown(igUserId, commenterUsername) {
    const key = `${igUserId}_${commenterUsername}`;
    const lastTime = userLastInteraction.get(key);
    if (lastTime && Date.now() - lastTime < ANTI_SPAM_RULES.USER_COOLDOWN_MS) {
      return true; // Still in cooldown
    }
    userLastInteraction.set(key, Date.now());
    return false;
  }

  /**
   * Format message template with placeholders
   */
  static formatMessage(template, { username, productName, price, link }) {
    if (!template) return "";
    const userTag = username && username !== "unknown" ? `@${username}` : "";
    return template
      .replace(/@?\{username\}/g, userTag)
      .replace(/{product}/g, productName || process.env.PRODUCT_NAME || "our product")
      .replace(/{price}/g, price || process.env.PRODUCT_PRICE || "")
      .replace(/{link}/g, link || process.env.PRODUCT_LINK || "")
      .replace(/\s+/g, " ")
      .trim();
  }

  /**
   * Main entry point for incoming Instagram comment events from webhooks
   */
  static async handleIncomingComment(commentData) {
    const commentId = commentData?.id;
    const text = commentData?.text || "";
    const username = commentData?.from?.username || commentData?.from?.id || "unknown";
    const commenterId = commentData?.from?.id;

    // Validate timestamp with shared EligibilityService
    const parsedTs = EligibilityService.parseTimestamp(commentData?.timestamp);
    const commentTimestamp = parsedTs.valid ? parsedTs.date : new Date();

    // Extract clean media post ID
    const rawMediaId = commentData?.media?.id || commentData?.media_id || commentData?.post_id || "";
    let cleanMediaId = String(rawMediaId).trim();
    if (cleanMediaId.includes("_")) {
      cleanMediaId = cleanMediaId.split("_").pop();
    }

    if (!commentId) {
      console.warn("⚠️ [Automation Engine] Comment event missing ID. Ignored.");
      return;
    }

    // ── Instagram Rule: Self-Reply & Bot Loop Protection ───────────────────────
    const botUsername = (process.env.BOT_USERNAME || "").toLowerCase();
    const botUserId = process.env.INSTAGRAM_USER_ID;
    const isSelf = EligibilityService.isSelfComment({
      username,
      recipientId: commenterId,
      botUsername,
      botUserId,
      isSelfScoped: Boolean(commentData?.from?.self_ig_scoped_id),
    });

    if (isSelf) {
      console.log(`🤖 [Loop Guard] Ignored self comment from bot [@${username}]`);
      return;
    }

    // ── Instagram Rule: In-Memory Comment Deduplication ───────────────────────
    if (this.isDuplicate(commentId)) {
      console.log(`🔁 [Dedup Guard] Duplicate comment [${commentId}] ignored (in-memory)`);
      return;
    }

    console.log(`💬 [Comment Ingested] ID:${commentId} @${username} on media:"${cleanMediaId}": "${text}"`);

    // ── Find matching active automation for this post ──────────────────────────
    const candidateMediaIds = [cleanMediaId, String(rawMediaId)].filter(Boolean);
    const automation = await Automation.findOne({
      mediaId: { $in: candidateMediaIds },
      status: "active",
    });

    if (!automation) {
      console.log(`ℹ️ [Automation Engine] No active automation configured for media post [${cleanMediaId}]. Skipping.`);
      return;
    }

    // Database-level deduplication guard against webhook redelivery
    const alreadyProcessed = automation.activityLog.some((e) => e.commentId === commentId);
    if (alreadyProcessed) {
      console.log(`🔁 [Dedup Guard] Comment [${commentId}] already processed in automation activityLog. Skipping.`);
      this.markProcessed(commentId);
      return;
    }
    this.markProcessed(commentId);

    // ── Retrieve User Token & Instagram User ID ───────────────────────────────
    const user = await User.findById(automation.userId);
    const igToken = user?.instagram?.accessToken || process.env.INSTAGRAM_ACCESS_TOKEN;
    const isDryRun = process.env.DRY_RUN === "true";
    const igUserId = user?.instagram?.id || automation.userId?.toString() || "default";

    // ── Evaluate Trigger Rules ────────────────────────────────────────────────
    const trigger = automation.trigger;
    let ruleMatched = false;
    let matchedRuleName = "no_match";

    if (trigger?.matchType === "any") {
      ruleMatched = true;
      matchedRuleName = "any_word";
    } else if (trigger?.keywords?.length > 0) {
      const normalizedText = text.toLowerCase().replace(/\s+/g, " ").trim();
      for (const kw of trigger.keywords) {
        const matched = trigger.wholeWord
          ? new RegExp(`(?<![a-z0-9])${escapeRegex(kw)}(?![a-z0-9])`, "i").test(normalizedText)
          : normalizedText.includes(kw.toLowerCase().trim());
        if (matched) {
          ruleMatched = true;
          matchedRuleName = kw;
          break;
        }
      }
    }

    // Requirement 2.I & Test 28: Persist Trigger Mismatch & Terminal Skip Audit History
    if (!ruleMatched) {
      console.log(`📭 [Trigger Check] Comment [${commentId}] did not match configured trigger keywords.`);

      // Persist terminal skip in ActionLedger
      const dmKey = ActionLedgerService.buildActionKey({ igUserId, mediaId: cleanMediaId, commentId, actionType: "dm" });
      await ActionLedger.findOneAndUpdate(
        { actionKey: dmKey },
        {
          $set: {
            actionKey: dmKey,
            igUserId: String(igUserId),
            mediaId: cleanMediaId,
            commentId: String(commentId),
            recipientId: commenterId ? String(commenterId) : null,
            username,
            actionType: "dm",
            status: "skipped",
            skipReason: "TRIGGER_MISMATCH",
            isRetryable: false,
            automationId: automation._id,
            source: "webhook",
            processedAt: new Date(),
          },
        },
        { upsert: true }
      );

      // Record in activityLog with ruleMatched: 'no_match' and skipped status
      const mismatchLog = {
        _id: new mongoose.Types.ObjectId(),
        commentId,
        commentTimestamp,
        username,
        text,
        ruleMatched: "no_match",
        publicReply: {
          sent: false,
          status: "skipped",
          message: "",
          skipReason: "TRIGGER_MISMATCH",
          attempts: 0,
          retryEligible: false,
        },
        privateReply: {
          sent: false,
          status: "skipped",
          message: "",
          skipReason: "TRIGGER_MISMATCH",
          attempts: 0,
          retryEligible: false,
        },
        timestamp: new Date(),
        isDuplicate: false,
        error: null,
      };

      automation.activityLog.push(mismatchLog);
      if (automation.activityLog.length > 500) {
        automation.activityLog = automation.activityLog.slice(-500);
      }
      await automation.save();
      return;
    }

    console.log(`🎯 [Trigger Matched] "${matchedRuleName}" on automation "${automation.name || automation._id}"`);

    // ── Instagram Rule: Anti-Spam Human-Like Pacing (Delay Queue) ─────────────
    if (ANTI_SPAM_RULES.ENABLE_HUMAN_DELAY && !isDryRun) {
      const jitterMs = Math.floor(
        Math.random() * (ANTI_SPAM_RULES.MAX_DELAY_MS - ANTI_SPAM_RULES.MIN_DELAY_MS + 1) +
          ANTI_SPAM_RULES.MIN_DELAY_MS
      );
      console.log(`⏳ [Anti-Spam Delay] Applying human-like pacing of ${jitterMs}ms before automated response...`);
      await sleep(jitterMs);
    }

    // ── Prepare Log Entry ──────────────────────────────────────────────────────
    const logEntry = {
      _id: new mongoose.Types.ObjectId(),
      commentId,
      commentTimestamp,
      username,
      text,
      ruleMatched: matchedRuleName,
      publicReply: {
        sent: false,
        status: "disabled",
        message: "",
        attempts: 0,
        lastAttemptAt: null,
      },
      privateReply: {
        sent: false,
        status: "disabled",
        message: "",
        link: "",
        attempts: 0,
        lastAttemptAt: null,
        retryEligible: false,
      },
      timestamp: new Date(),
      isDuplicate: false,
      error: null,
    };

    // ── 1. Execute Public Reply (if enabled) ──────────────────────────────────
    if (automation.publicReply?.enabled) {
      const messages = automation.publicReply.messages || [];
      const selectedTemplate =
        messages.length > 0
          ? messages[Math.floor(Math.random() * messages.length)]
          : "@{username} Thank you for your comment! Check your DMs! 📩";

      const formattedPublicMsg = this.formatMessage(selectedTemplate, {
        username,
        productName: process.env.PRODUCT_NAME,
        price: process.env.PRODUCT_PRICE,
        link: process.env.PRODUCT_LINK,
      });

      logEntry.publicReply.message = formattedPublicMsg;

      if (isDryRun) {
        logEntry.publicReply.sent = false;
        logEntry.publicReply.status = "skipped";
        logEntry.publicReply.errorCategory = "DRY_RUN";
        logEntry.publicReply.errorMessage = "Dry run active: public reply simulated";
      } else if (!igToken) {
        logEntry.publicReply.sent = false;
        logEntry.publicReply.status = "failed";
        logEntry.publicReply.errorCategory = "NO_TOKEN";
        logEntry.publicReply.errorCode = 401;
        logEntry.publicReply.errorMessage = "Instagram access token missing or account disconnected";
        logEntry.publicReply.error = "Instagram access token missing or account disconnected";
        logEntry.publicReply.firstFailedAt = new Date();
        logEntry.publicReply.lastFailedAt = new Date();
      } else {
        const pubClaim = await ActionLedgerService.claimAction({
          igUserId,
          mediaId: cleanMediaId,
          commentId,
          recipientId: commenterId ? String(commenterId) : null,
          username,
          actionType: "public_reply",
          automationId: automation._id,
          source: "webhook",
        });

        if (!pubClaim.claimed) {
          if (ActionLedgerService.isSentStatus(pubClaim.status)) {
            logEntry.publicReply.sent = true;
            logEntry.publicReply.status = "sent";
          } else if (pubClaim.status === "skipped") {
            logEntry.publicReply.status = "skipped";
            logEntry.publicReply.retryEligible = false;
          } else if (pubClaim.status === "unknown" || pubClaim.status === "reconciliation_required") {
            logEntry.publicReply.status = pubClaim.status;
            logEntry.publicReply.retryEligible = false;
          }
        } else {
          logEntry.publicReply.attempts = 1;
          logEntry.publicReply.lastAttemptAt = new Date();

          const replyResult = await InstagramService.publishCommentReply(commentId, formattedPublicMsg, igToken);
          const pubKey =
            pubClaim.record?.actionKey ||
            ActionLedgerService.buildActionKey({ igUserId, mediaId: cleanMediaId, commentId, actionType: "public_reply" });

          if (replyResult.ok) {
            await ActionLedgerService.finalizeAction({
              actionKey: pubKey,
              claimToken: pubClaim.claimToken,
              result: replyResult,
            });
            logEntry.publicReply.sent = true;
            logEntry.publicReply.status = "sent";
            logEntry.publicReply.messageId = replyResult.replyId;
            logEntry.publicReply.lastSuccessAt = new Date();
          } else {
            const err = replyResult.error || {};
            const metaClass = ActionLedgerService.classifyMetaError(err);

            if (metaClass.isAlreadyReplied) {
              await ActionLedgerService.finalizeAction({
                actionKey: pubKey,
                claimToken: pubClaim.claimToken,
                error: err,
              });
              logEntry.publicReply.sent = true;
              logEntry.publicReply.status = "sent";
              logEntry.publicReply.lastSuccessAt = new Date();
            } else if (metaClass.isIneligible) {
              await ActionLedgerService.finalizeAction({
                actionKey: pubKey,
                claimToken: pubClaim.claimToken,
                error: err,
                skipReason: metaClass.reason,
              });
              logEntry.publicReply.sent = false;
              logEntry.publicReply.status = "skipped";
              logEntry.publicReply.errorCategory = metaClass.category;
              logEntry.publicReply.errorMessage = err.message || "Public reply ineligible";
              logEntry.publicReply.retryEligible = false;
              logEntry.publicReply.retryReason = `Skipped: ${metaClass.reason}`;
            } else {
              await ActionLedgerService.finalizeAction({
                actionKey: pubKey,
                claimToken: pubClaim.claimToken,
                error: err,
                isAmbiguous: Boolean(err.isAmbiguous),
              });
              logEntry.publicReply.sent = false;
              logEntry.publicReply.status = err.isAmbiguous ? "unknown" : "failed";
              logEntry.publicReply.errorCategory = err.category || "API_ERROR";
              logEntry.publicReply.errorCode = err.code || null;
              logEntry.publicReply.errorSubcode = err.subcode || null;
              logEntry.publicReply.errorMessage = err.message || "Failed to publish comment reply";
              logEntry.publicReply.error = err.message || "Failed to publish comment reply";
              logEntry.publicReply.firstFailedAt = new Date();
              logEntry.publicReply.lastFailedAt = new Date();

              if (replyResult.error?.shouldPauseAutomation) {
                console.error(`🚨 [Action Blocked] Meta returned error ${replyResult.error.code}. Pausing automation!`);
                automation.status = "paused";
              }
            }
          }
        }
      }
      console.log(`📢 [Public Reply] "${formattedPublicMsg}" → ${logEntry.publicReply.status}`);
    }

    // ── 2. Execute Private Reply (DM) (if enabled) ────────────────────────────
    if (automation.openingDm?.enabled) {
      // Shared eligibility evaluation
      const eligibility = EligibilityService.evaluateEligibility({
        actionType: "dm",
        commentTimestamp,
        username,
        recipientId: commenterId,
        botUsername,
        botUserId,
        automation,
      });

      const rawDmMsg = automation.openingDm.message || "";
      const formattedDmMsg = this.formatMessage(rawDmMsg, {
        username,
        productName: process.env.PRODUCT_NAME,
        price: process.env.PRODUCT_PRICE,
        link: automation.openingDm.link || process.env.PRODUCT_LINK,
      });

      const hasButton =
        automation.openingDm.buttonEnabled !== false &&
        Boolean(automation.openingDm.buttonText?.trim()) &&
        Boolean(
          automation.openingDm.link?.trim() ||
            automation.finalDm?.link?.trim() ||
            (automation.openingDm.buttonEnabled && process.env.PRODUCT_LINK)
        );

      const buttonText = hasButton ? (automation.openingDm.buttonText || "Open Link").trim() : "";
      const linkUrl = hasButton
        ? (automation.openingDm.link || automation.finalDm?.link || process.env.PRODUCT_LINK || "").trim()
        : "";

      logEntry.privateReply.message = formattedDmMsg;
      logEntry.privateReply.link = linkUrl;
      logEntry.privateReply.buttonText = buttonText;

      if (!eligibility.isEligible) {
        console.warn(`⏳ [Eligibility Check] Comment [${commentId}] ineligible for DM: ${eligibility.skipReason}`);
        logEntry.privateReply.sent = false;
        logEntry.privateReply.status = "skipped";
        logEntry.privateReply.errorCategory = eligibility.skipReason;
        logEntry.privateReply.errorMessage = eligibility.message;
        logEntry.privateReply.retryEligible = false;
        logEntry.privateReply.retryReason = eligibility.message;

        const dmKey = ActionLedgerService.buildActionKey({ igUserId, mediaId: cleanMediaId, commentId, actionType: "dm" });
        await ActionLedger.findOneAndUpdate(
          { actionKey: dmKey },
          {
            $set: {
              actionKey: dmKey,
              igUserId: String(igUserId),
              mediaId: cleanMediaId,
              commentId: String(commentId),
              recipientId: commenterId ? String(commenterId) : null,
              username,
              actionType: "dm",
              status: "skipped",
              skipReason: eligibility.skipReason,
              isRetryable: false,
              automationId: automation._id,
              source: "webhook",
              processedAt: new Date(),
            },
          },
          { upsert: true }
        );
      } else if (isDryRun) {
        logEntry.privateReply.sent = false;
        logEntry.privateReply.status = "skipped";
        logEntry.privateReply.errorCategory = "DRY_RUN";
        logEntry.privateReply.errorMessage = "Dry run active: DM simulated";
        logEntry.privateReply.retryEligible = false;
      } else if (!igToken) {
        logEntry.privateReply.sent = false;
        logEntry.privateReply.status = "failed";
        logEntry.privateReply.attempts = 1;
        logEntry.privateReply.lastAttemptAt = new Date();
        logEntry.privateReply.firstFailedAt = new Date();
        logEntry.privateReply.lastFailedAt = new Date();
        logEntry.privateReply.errorCategory = "NO_TOKEN";
        logEntry.privateReply.errorCode = 401;
        logEntry.privateReply.errorMessage = "Instagram access token missing or account disconnected";
        logEntry.privateReply.error = "Instagram access token missing or account disconnected";
        logEntry.privateReply.retryEligible = true;
        logEntry.privateReply.retryReason = "Connect Instagram account to retry DM";
      } else {
        // Enforce single DM per user and atomic claiming via ActionLedger
        const dmClaim = await ActionLedgerService.claimAction({
          igUserId,
          mediaId: cleanMediaId,
          commentId,
          recipientId: commenterId ? String(commenterId) : null,
          username,
          actionType: "dm",
          automationId: automation._id,
          source: "webhook",
        });

        if (!dmClaim.claimed) {
          if (ActionLedgerService.isSentStatus(dmClaim.status)) {
            logEntry.privateReply.sent = true;
            logEntry.privateReply.status = "sent";
            logEntry.privateReply.retryEligible = false;
            console.log(`🔁 [Action Ledger] DM already sent to @${username} on media [${cleanMediaId}]. Skipping duplicate.`);
          } else if (dmClaim.status === "skipped") {
            logEntry.privateReply.sent = false;
            logEntry.privateReply.status = "skipped";
            logEntry.privateReply.retryEligible = false;
            logEntry.privateReply.retryReason = dmClaim.reason || "ALREADY_SENT_TO_USER";
            logEntry.privateReply.errorCategory = dmClaim.reason || "ALREADY_SENT_TO_USER";
            console.log(`ℹ️ [Action Ledger] DM skipped for @${username} on media [${cleanMediaId}]: ${dmClaim.reason}`);
          } else if (dmClaim.status === "unknown" || dmClaim.status === "reconciliation_required") {
            logEntry.privateReply.sent = false;
            logEntry.privateReply.status = dmClaim.status;
            logEntry.privateReply.retryEligible = false;
            logEntry.privateReply.retryReason = "Ambiguous delivery outcome. Manual reconciliation required.";
          }
        } else {
          logEntry.privateReply.attempts = 1;
          logEntry.privateReply.lastAttemptAt = new Date();

          const dmResult = await InstagramService.sendPrivateReply(
            commentId,
            formattedDmMsg,
            igToken,
            buttonText,
            linkUrl,
            commentTimestamp,
            commenterId || null
          );
          const dmKey =
            dmClaim.record?.actionKey ||
            ActionLedgerService.buildActionKey({ igUserId, mediaId: cleanMediaId, commentId, actionType: "dm" });

          if (dmResult.ok) {
            await ActionLedgerService.finalizeAction({
              actionKey: dmKey,
              claimToken: dmClaim.claimToken,
              result: dmResult,
            });
            logEntry.privateReply.sent = true;
            logEntry.privateReply.status = "sent";
            logEntry.privateReply.messageId = dmResult.messageId;
            logEntry.privateReply.lastSuccessAt = new Date();
            logEntry.privateReply.retryEligible = false;
            logEntry.privateReply.retryReason = "Delivered successfully";
          } else {
            const err = dmResult.error || {};
            const metaClass = ActionLedgerService.classifyMetaError(err);

            if (metaClass.isAlreadyReplied) {
              // Section 2.B: Meta confirms DM was already sent!
              // Must map to canonical 'sent' state with reconciliation metadata
              await ActionLedgerService.finalizeAction({
                actionKey: dmKey,
                claimToken: dmClaim.claimToken,
                error: err,
              });
              logEntry.privateReply.sent = true;
              logEntry.privateReply.status = "sent";
              logEntry.privateReply.messageId = dmResult.messageId || null;
              logEntry.privateReply.lastSuccessAt = new Date();
              logEntry.privateReply.retryEligible = false;
              logEntry.privateReply.retryReason = "Confirmed already sent by Meta API";
            } else if (metaClass.isIneligible) {
              await ActionLedgerService.finalizeAction({
                actionKey: dmKey,
                claimToken: dmClaim.claimToken,
                error: err,
                skipReason: metaClass.reason,
              });
              logEntry.privateReply.sent = false;
              logEntry.privateReply.status = "skipped";
              logEntry.privateReply.errorCategory = metaClass.category;
              logEntry.privateReply.errorMessage = err.message || "DM action ineligible";
              logEntry.privateReply.retryEligible = false;
              logEntry.privateReply.retryReason = `Skipped: ${metaClass.reason}`;
            } else if (err.isAmbiguous) {
              await ActionLedgerService.finalizeAction({
                actionKey: dmKey,
                claimToken: dmClaim.claimToken,
                error: err,
                isAmbiguous: true,
              });
              logEntry.privateReply.sent = false;
              logEntry.privateReply.status = "unknown";
              logEntry.privateReply.errorCategory = "AMBIGUOUS_DELIVERY";
              logEntry.privateReply.errorMessage = err.message || "Ambiguous delivery outcome";
              logEntry.privateReply.retryEligible = false;
              logEntry.privateReply.retryReason = "Ambiguous delivery outcome (timeout). Manual reconciliation required.";
            } else {
              await ActionLedgerService.finalizeAction({
                actionKey: dmKey,
                claimToken: dmClaim.claimToken,
                error: err,
              });
              logEntry.privateReply.sent = false;
              logEntry.privateReply.status = "failed";
              logEntry.privateReply.errorCategory = err.category || "API_ERROR";
              logEntry.privateReply.errorCode = err.code || null;
              logEntry.privateReply.errorSubcode = err.subcode || null;
              logEntry.privateReply.errorMessage = err.message || "Failed to deliver direct message";
              logEntry.privateReply.error = err.message || "Failed to deliver direct message";
              logEntry.privateReply.firstFailedAt = new Date();
              logEntry.privateReply.lastFailedAt = new Date();
              logEntry.privateReply.retryEligible = metaClass.isRetryable;
              logEntry.privateReply.retryReason = metaClass.isRetryable ? "Eligible for retry" : (err.message || "Retry not permitted");

              if (err.shouldPauseAutomation) {
                console.error(`🚨 [Action Blocked] Meta returned error ${err.code}. Pausing automation!`);
                automation.status = "paused";
              }
            }
          }
        }
      }
      console.log(`📨 [Private Reply] "${formattedDmMsg}" → ${logEntry.privateReply.status}`);
    }

    // ── Update Automation Stats & Audit History ────────────────────────────────
    // Independent action failure tracking:
    const publicFailed = !isDryRun && Boolean(automation.publicReply?.enabled) && logEntry.publicReply.status === "failed";
    const dmFailed = !isDryRun && Boolean(automation.openingDm?.enabled) && logEntry.privateReply.status === "failed";

    let failedActionsIncrement = 0;
    if (publicFailed) failedActionsIncrement += 1;
    if (dmFailed) failedActionsIncrement += 1;

    // Set top-level error summary on logEntry
    if (publicFailed && dmFailed) {
      logEntry.error = `[Public Reply] ${logEntry.publicReply.errorMessage} | [DM] ${logEntry.privateReply.errorMessage}`;
    } else if (publicFailed) {
      logEntry.error = `[Public Reply] ${logEntry.publicReply.errorMessage}`;
    } else if (dmFailed) {
      logEntry.error = `[DM] ${logEntry.privateReply.errorMessage}`;
    } else {
      logEntry.error = null;
    }

    if (!isDryRun) {
      automation.stats.commentsReceived = (automation.stats.commentsReceived || 0) + 1;
      if (logEntry.publicReply.sent) automation.stats.repliesSent = (automation.stats.repliesSent || 0) + 1;
      if (logEntry.privateReply.sent) automation.stats.dmsSent = (automation.stats.dmsSent || 0) + 1;
      if (failedActionsIncrement > 0) {
        automation.stats.failed = (automation.stats.failed || 0) + failedActionsIncrement;
        automation.stats.totalFailedAttempts = (automation.stats.totalFailedAttempts || 0) + failedActionsIncrement;
      }
    }

    automation.activityLog.push(logEntry);
    if (automation.activityLog.length > 500) {
      automation.activityLog = automation.activityLog.slice(-500);
    }

    await automation.save();
    console.log(`💾 [Automation Saved] Updated stats for "${automation.name || automation._id}"`);
  }
}

module.exports = AutomationEngine;
