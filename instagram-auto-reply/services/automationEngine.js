// ════════════════════════════════════════════════════════════════════════════
// Instagram Automation Engine
// Core processing pipeline strictly following Meta Instagram Automation Rules
// ════════════════════════════════════════════════════════════════════════════
const Automation = require("../models/Automation");
const User = require("../models/User");
const InstagramService = require("./instagramService");
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
    const commentTimestamp = commentData?.timestamp ? new Date(commentData.timestamp) : new Date();

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
    const isSelf =
      Boolean(commentData?.from?.self_ig_scoped_id) ||
      (botUsername && username.toLowerCase() === botUsername) ||
      (botUserId && commenterId === botUserId);

    if (isSelf) {
      console.log(`🤖 [Loop Guard] Ignored self comment from bot [@${username}]`);
      return;
    }

    // ── Instagram Rule: Comment Deduplication ──────────────────────────────────
    if (this.isDuplicate(commentId)) {
      console.log(`🔁 [Dedup Guard] Duplicate comment [${commentId}] ignored`);
      return;
    }
    this.markProcessed(commentId);

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

    if (!ruleMatched) {
      console.log(`📭 [Trigger Check] Comment [${commentId}] did not match configured trigger keywords.`);
      return;
    }

    console.log(`🎯 [Trigger Matched] "${matchedRuleName}" on automation "${automation.name || automation._id}"`);

    // ── Retrieve User Token & Configuration ────────────────────────────────────
    const user = await User.findById(automation.userId);
    const igToken = user?.instagram?.accessToken || process.env.INSTAGRAM_ACCESS_TOKEN;
    const isDryRun = process.env.DRY_RUN === "true";

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
      commentId,
      username,
      text,
      ruleMatched: matchedRuleName,
      publicReply: { sent: false, status: "disabled" },
      privateReply: { sent: false, status: "disabled" },
      timestamp: new Date(),
    };

    // ── 1. Execute Public Reply (if enabled) ──────────────────────────────────
    if (automation.publicReply?.enabled) {
      const messages = automation.publicReply.messages || [];
      // Pick random variation to prevent duplicate detection (Instagram Rule)
      const selectedTemplate = messages.length > 0
        ? messages[Math.floor(Math.random() * messages.length)]
        : "@{username} Thank you for your comment! Check your DMs! 📩";

      const formattedPublicMsg = this.formatMessage(selectedTemplate, {
        username,
        productName: process.env.PRODUCT_NAME,
        price: process.env.PRODUCT_PRICE,
        link: process.env.PRODUCT_LINK,
      });

      if (!isDryRun && igToken) {
        const replyResult = await InstagramService.publishCommentReply(commentId, formattedPublicMsg, igToken);
        if (replyResult.ok) {
          logEntry.publicReply = { sent: true, status: "sent", message: formattedPublicMsg };
        } else {
          logEntry.publicReply = {
            sent: false,
            status: "api_error",
            message: formattedPublicMsg,
            error: replyResult.error?.message,
          };
          if (replyResult.error?.shouldPauseAutomation) {
            console.error(`🚨 [Action Blocked] Meta returned error ${replyResult.error.code}. Pausing automation to protect account!`);
            automation.status = "paused";
          }
        }
      } else {
        logEntry.publicReply = {
          sent: false,
          status: isDryRun ? "simulated" : "no_token",
          message: formattedPublicMsg,
        };
      }
      console.log(`📢 [Public Reply] "${formattedPublicMsg}" → ${logEntry.publicReply.status}`);
    }

    // ── 2. Execute Private Reply (DM) (if enabled) ────────────────────────────
    if (automation.openingDm?.enabled) {
      // Instagram Rule: Check 7-Day Window
      const commentAgeMs = Date.now() - commentTimestamp.getTime();
      const isWithin7Days = commentAgeMs <= MESSAGING_RULES.MAX_COMMENT_AGE_MS;

      if (!isWithin7Days) {
        console.warn(`⏳ [Instagram Rule Enforcement] Comment [${commentId}] is older than 7 days. DM skipped per Meta policy.`);
        logEntry.privateReply = {
          sent: false,
          status: "expired_7_days",
          message: "Skipped: Comment is older than 7 days (Meta Messaging Policy)",
        };
      } else {
        const rawDmMsg = automation.openingDm.message || "";
        const formattedDmMsg = this.formatMessage(rawDmMsg, {
          username,
          productName: process.env.PRODUCT_NAME,
          price: process.env.PRODUCT_PRICE,
          link: automation.openingDm.link || process.env.PRODUCT_LINK,
        });

        const buttonText = (automation.openingDm.buttonText || "Open Link").trim();
        const linkUrl = (automation.openingDm.link || automation.finalDm?.link || process.env.PRODUCT_LINK || "").trim();

        if (!isDryRun && igToken) {
          const dmResult = await InstagramService.sendPrivateReply(
            commentId,
            formattedDmMsg,
            igToken,
            buttonText,
            linkUrl,
            commentTimestamp
          );

          if (dmResult.ok) {
            logEntry.privateReply = {
              sent: true,
              status: "sent",
              message: formattedDmMsg,
              link: linkUrl,
            };
          } else {
            logEntry.privateReply = {
              sent: false,
              status: dmResult.error?.category === "WINDOW_CLOSED_7_DAYS" ? "expired_7_days" : "api_error",
              message: formattedDmMsg,
              error: dmResult.error?.message,
            };
            if (dmResult.error?.shouldPauseAutomation) {
              console.error(`🚨 [Action Blocked] Meta returned error ${dmResult.error.code}. Pausing automation!`);
              automation.status = "paused";
            }
          }
        } else {
          logEntry.privateReply = {
            sent: false,
            status: isDryRun ? "simulated" : "no_token",
            message: formattedDmMsg,
            link: linkUrl,
          };
        }
        console.log(`📨 [Private Reply] "${formattedDmMsg}" → ${logEntry.privateReply.status}`);
      }
    }

    // ── Update Automation Stats & Audit History ────────────────────────────────
    automation.stats.commentsReceived += 1;
    if (logEntry.publicReply.sent) automation.stats.repliesSent += 1;
    if (logEntry.privateReply.sent) automation.stats.dmsSent += 1;

    if (!isDryRun && igToken) {
      if (
        (automation.publicReply?.enabled && !logEntry.publicReply.sent) ||
        (automation.openingDm?.enabled && !logEntry.privateReply.sent)
      ) {
        automation.stats.failed = (automation.stats.failed || 0) + 1;
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
