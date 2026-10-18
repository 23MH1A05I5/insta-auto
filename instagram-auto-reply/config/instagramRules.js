// ════════════════════════════════════════════════════════════════════════════
// Instagram / Meta Graph API Platform Rules & Policy Constants
// Official Meta Documentation: https://developers.facebook.com/docs/instagram-platform
// ════════════════════════════════════════════════════════════════════════════

module.exports = {
  // Graph API version
  GRAPH_API_VERSION: "v21.0",
  GRAPH_API_BASE: "https://graph.instagram.com/v21.0",

  // ── Instagram Direct Messaging (Private Replies) Rules ─────────────────────
  // Rule: Businesses can only send ONE direct message in response to a comment.
  // Rule: The comment must be created within the last 7 days (168 hours).
  MESSAGING_RULES: {
    MAX_COMMENT_AGE_MS: 7 * 24 * 60 * 60 * 1000, // 7 days in milliseconds
    MAX_DM_TEXT_LENGTH: 640,                     // Meta max characters for DM text
    MAX_BUTTON_TITLE_LENGTH: 20,                // Meta max characters for button label
    MAX_BUTTONS_COUNT: 3,                       // Meta max buttons per template
    ONLY_ONE_DM_PER_COMMENT: true,              // Meta policy rule
  },

  // ── Public Comment Reply Anti-Spam Guidelines ──────────────────────────────
  // Rule: Meta penalizes identical repetitive comments. Automations must rotate templates.
  ANTI_SPAM_RULES: {
    MIN_REPLY_VARIATIONS: 3,                    // Recommended variations to prevent duplicate detection
    MAX_COMMENT_LENGTH: 2200,                   // Instagram max comment length
    ENABLE_HUMAN_DELAY: true,                   // Introduce human-like pacing
    MIN_DELAY_MS: 2000,                         // 2s min delay before replying
    MAX_DELAY_MS: 4500,                         // 4.5s max jitter delay
    USER_COOLDOWN_MS: 60 * 1000,                // 1 min cooldown per user per post to prevent comment bombing
    DEDUP_WINDOW_MS: 15 * 60 * 1000,            // 15 minutes comment ID deduplication cache
  },

  // ── Rate Limiting & Safety ──────────────────────────────────────────────────
  RATE_LIMITS: {
    MAX_REQUESTS_PER_MINUTE: 30,                // Conservative safe ceiling per account
    MAX_MEDIA_COMMENTS_FETCH_LIMIT: 100,        // Max allowed per comments request
  },

  // ── Meta Graph API Error Codes Classification ──────────────────────────────
  ERROR_CODES: {
    TOKEN_EXPIRED: [190, 463, 467],             // OAuth token expired or invalidated
    ACTION_BLOCKED: [368],                      // Instagram detected spam / rate violation; account action blocked
    RATE_LIMIT_EXCEEDED: [4, 17, 32, 613],      // Meta API rate limit hit
    PERMISSION_DENIED: [10, 200],               // Missing required permission scope
    PRIVATE_REPLY_WINDOW_CLOSED: [100],         // Comment older than 7 days or already replied
    PRIVATE_REPLY_SUBCODES: [2018001],          // Subcode for comment older than 7 days
  },
};
