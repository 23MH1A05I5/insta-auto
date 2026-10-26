// ════════════════════════════════════════════════════════════════════════════
// InstaAuto — Unified Eligibility & Policy Service
// Shared rules engine for Preview, Live Webhooks, Backfill, and Retries
// Compliant with Meta Instagram Platform Policy & Messaging Guidelines
// ════════════════════════════════════════════════════════════════════════════

const { MESSAGING_RULES, ANTI_SPAM_RULES } = require("../config/instagramRules");

class EligibilityService {
  /**
   * Safely parse and validate comment timestamp.
   * Returns { valid: boolean, date: Date|null, error: string|null }
   */
  static parseTimestamp(timestamp) {
    if (!timestamp) {
      return { valid: false, date: null, reason: "MISSING_TIMESTAMP" };
    }
    const date = timestamp instanceof Date ? timestamp : new Date(timestamp);
    if (isNaN(date.getTime())) {
      return { valid: false, date: null, reason: "INVALID_TIMESTAMP" };
    }
    // Protect against future timestamps beyond 5 minutes clock skew
    if (date.getTime() > Date.now() + 5 * 60 * 1000) {
      return { valid: false, date: null, reason: "FUTURE_TIMESTAMP" };
    }
    return { valid: true, date, reason: null };
  }

  /**
   * Check if comment was made by the bot or account owner itself.
   */
  static isSelfComment({ username, recipientId, botUsername, botUserId, isSelfScoped = false }) {
    if (isSelfScoped) return true;
    if (botUsername && username && String(username).toLowerCase() === String(botUsername).toLowerCase()) {
      return true;
    }
    if (botUserId && recipientId && String(recipientId) === String(botUserId)) {
      return true;
    }
    return false;
  }

  /**
   * Universal Eligibility Evaluation for an action (DM or Public Reply).
   * Used identically across:
   *  1. Preview (Backfill preview calculation)
   *  2. Live Webhook Execution (AutomationEngine)
   *  3. Backfill Execution (BackfillService)
   *  4. Manual and Bulk Retries (activity.js & BackfillService)
   */
  static evaluateEligibility({
    actionType, // 'dm' | 'public_reply'
    commentTimestamp,
    username = "unknown",
    recipientId = null,
    botUsername = process.env.BOT_USERNAME,
    botUserId = process.env.INSTAGRAM_USER_ID,
    isSelfScoped = false,
    text = "",
    automation = null,
  }) {
    // 1. Self-comment check (Bots must never reply to themselves per Meta loop prevention)
    if (this.isSelfComment({ username, recipientId, botUsername, botUserId, isSelfScoped })) {
      return {
        isEligible: false,
        isTerminal: true,
        retryEligible: false,
        skipReason: "SELF_COMMENT",
        message: "Comment from bot or account owner ignored to prevent loops",
      };
    }

    // 2. Action Type: Public Reply Rules
    if (actionType === "public_reply") {
      // Public reply does NOT have the 7-day private-reply restriction per Meta specs,
      // but requires non-empty message template and active automation.
      if (automation && !automation.publicReply?.enabled) {
        return {
          isEligible: false,
          isTerminal: true,
          retryEligible: false,
          skipReason: "PUBLIC_REPLY_DISABLED",
          message: "Public reply is disabled on this automation",
        };
      }
      return { isEligible: true };
    }

    // 3. Action Type: Private Reply (DM) Rules
    if (actionType === "dm") {
      if (automation && !automation.openingDm?.enabled) {
        return {
          isEligible: false,
          isTerminal: true,
          retryEligible: false,
          skipReason: "DM_DISABLED",
          message: "Direct message is disabled on this automation",
        };
      }

      // Validate comment timestamp
      const tsResult = this.parseTimestamp(commentTimestamp);
      if (!tsResult.valid) {
        return {
          isEligible: false,
          isTerminal: true,
          retryEligible: false,
          skipReason: tsResult.reason,
          message: `Invalid or missing comment timestamp: ${tsResult.reason}`,
        };
      }

      // Check Meta 7-day conversation window policy (168 hours)
      const ageMs = Date.now() - tsResult.date.getTime();
      const maxAgeMs = MESSAGING_RULES.MAX_COMMENT_AGE_MS || 7 * 24 * 60 * 60 * 1000;

      if (ageMs > maxAgeMs) {
        const daysOld = Math.floor(ageMs / (24 * 60 * 60 * 1000));
        return {
          isEligible: false,
          isTerminal: true,
          retryEligible: false,
          skipReason: "WINDOW_CLOSED_7_DAYS",
          message: `Comment is ${daysOld} days old. Meta policy restricts private replies to within 7 days.`,
        };
      }

      return { isEligible: true, commentDate: tsResult.date };
    }

    return {
      isEligible: false,
      isTerminal: true,
      retryEligible: false,
      skipReason: "UNKNOWN_ACTION_TYPE",
      message: `Unsupported action type: ${actionType}`,
    };
  }

  /**
   * Helper to check if a skip reason is permanent/terminal
   */
  static isTerminalReason(reason) {
    const terminalReasons = new Set([
      "WINDOW_CLOSED_7_DAYS",
      "SELF_COMMENT",
      "TRIGGER_MISMATCH",
      "RECIPIENT_NOT_FOUND",
      "ALREADY_SENT_TO_USER",
      "MISSING_TIMESTAMP",
      "INVALID_TIMESTAMP",
      "DEV_MODE_RESTRICTION",
      "UNKNOWN_ACTION_TYPE",
    ]);
    return terminalReasons.has(reason);
  }
}

module.exports = EligibilityService;
