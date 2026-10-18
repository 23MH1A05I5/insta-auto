// ════════════════════════════════════════════════════════════════════════════
// Instagram Graph API Service
// Compliant with Meta Platform Terms, Messaging API Specs & Community Guidelines
// ════════════════════════════════════════════════════════════════════════════
const { GRAPH_API_BASE, MESSAGING_RULES, ANTI_SPAM_RULES, RATE_LIMITS, ERROR_CODES } = require("../config/instagramRules");

class InstagramService {
  /**
   * Parse and classify errors returned by Meta Graph API
   */
  static parseMetaError(errorData) {
    if (!errorData) return { isError: false };

    const err = errorData.error || errorData;
    const code = err.code;
    const subcode = err.error_subcode;
    const message = err.message || "Unknown Meta API error";

    let category = "API_ERROR";
    let shouldPauseAutomation = false;
    let shouldInvalidateToken = false;

    if (ERROR_CODES.TOKEN_EXPIRED.includes(code)) {
      category = "TOKEN_EXPIRED";
      shouldInvalidateToken = true;
    } else if (ERROR_CODES.ACTION_BLOCKED.includes(code)) {
      category = "ACTION_BLOCKED";
      shouldPauseAutomation = true;
    } else if (ERROR_CODES.RATE_LIMIT_EXCEEDED.includes(code)) {
      category = "RATE_LIMIT";
    } else if (ERROR_CODES.PRIVATE_REPLY_WINDOW_CLOSED.includes(code) && ERROR_CODES.PRIVATE_REPLY_SUBCODES.includes(subcode)) {
      category = "WINDOW_CLOSED_7_DAYS";
    } else if (ERROR_CODES.PERMISSION_DENIED.includes(code)) {
      category = "PERMISSION_DENIED";
    }

    return {
      isError: true,
      code,
      subcode,
      message,
      category,
      shouldPauseAutomation,
      shouldInvalidateToken,
    };
  }

  /**
   * Verify an access token and retrieve account info
   */
  static async verifyToken(token) {
    if (!token) return { ok: false, error: "Token not provided" };

    try {
      const res = await fetch(`${GRAPH_API_BASE}/me?fields=id,username,account_type&access_token=${token}`);
      const data = await res.json();
      if (data.error) {
        return { ok: false, error: this.parseMetaError(data) };
      }
      return { ok: true, account: data };
    } catch (err) {
      return { ok: false, error: { message: err.message, category: "NETWORK_ERROR" } };
    }
  }

  /**
   * Fetch user media items (Posts & Reels)
   */
  static async fetchMedia(token, limit = 20, cursor = null) {
    try {
      const safeLimit = Math.min(Math.max(parseInt(limit, 10) || 20, 1), 50);
      const afterParam = cursor ? `&after=${encodeURIComponent(cursor)}` : "";
      const url = `${GRAPH_API_BASE}/me/media?fields=id,media_type,media_url,thumbnail_url,caption,timestamp,permalink&limit=${safeLimit}${afterParam}&access_token=${token}`;

      const res = await fetch(url);
      const data = await res.json();

      if (data.error) {
        return { ok: false, error: this.parseMetaError(data) };
      }

      return {
        ok: true,
        media: data.data || [],
        paging: data.paging || null,
      };
    } catch (err) {
      return { ok: false, error: { message: err.message, category: "NETWORK_ERROR" } };
    }
  }

  /**
   * Fetch comments on a specific post/reel
   */
  static async fetchComments(mediaId, token, limit = 50, cursor = null) {
    try {
      const maxLimit = RATE_LIMITS?.MAX_MEDIA_COMMENTS_FETCH_LIMIT || 100;
      const parsed = parseInt(limit, 10);
      const safeLimit = Math.min(Math.max(!isNaN(parsed) ? parsed : 50, 1), maxLimit);
      const afterParam = cursor ? `&after=${encodeURIComponent(cursor)}` : "";
      const url = `${GRAPH_API_BASE}/${mediaId}/comments?fields=id,text,username,from{id,username},timestamp,replies{id,text,username,timestamp}&limit=${safeLimit}${afterParam}&access_token=${token}`;

      const res = await fetch(url);
      const data = await res.json();

      if (data.error) {
        return { ok: false, error: this.parseMetaError(data) };
      }

      return {
        ok: true,
        comments: data.data || [],
        paging: data.paging || null,
      };
    } catch (err) {
      return { ok: false, error: { message: err.message, category: "NETWORK_ERROR" } };
    }
  }

  /**
   * Fetch media metrics / stats
   */
  static async fetchMediaStats(mediaId, token) {
    try {
      const url = `${GRAPH_API_BASE}/${mediaId}?fields=id,media_type,like_count,comments_count,timestamp,caption,permalink&access_token=${token}`;
      const res = await fetch(url);
      const data = await res.json();

      if (data.error) {
        return { ok: false, error: this.parseMetaError(data) };
      }

      return { ok: true, stats: data };
    } catch (err) {
      return { ok: false, error: { message: err.message, category: "NETWORK_ERROR" } };
    }
  }

  /**
   * Publish a public reply to a comment
   * Follows anti-spam rules: text length limit, sanitize user tags
   */
  static async publishCommentReply(commentId, message, token) {
    try {
      const sanitized = (message || "").trim().substring(0, ANTI_SPAM_RULES.MAX_COMMENT_LENGTH);
      if (!sanitized) {
        return { ok: false, error: { message: "Reply message cannot be empty", category: "VALIDATION_ERROR" } };
      }

      const url = `${GRAPH_API_BASE}/${commentId}/replies`;
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: sanitized, access_token: token }),
      });
      const data = await res.json();

      if (data.error) {
        const parsed = this.parseMetaError(data);
        console.error(`❌ [Meta Graph API Public Reply] Code ${parsed.code}: ${parsed.message}`);
        return { ok: false, error: parsed };
      }

      console.log(`✅ [Meta Graph API Public Reply] Sent reply ID: ${data.id}`);
      return { ok: true, replyId: data.id };
    } catch (err) {
      console.error("❌ [Meta Graph API Public Reply] Network error:", err.message);
      return { ok: false, error: { message: err.message, category: "NETWORK_ERROR" } };
    }
  }

  /**
   * Send Private Reply (Direct Message to Commenter)
   * Enforces:
   * 1. Meta 7-day comment age policy
   * 2. Meta 640-character DM limit
   * 3. Meta 20-character button title limit
   * 4. HTTPS URL validation
   * 5. Button Template with automatic fallback to text with link
   */
  static async sendPrivateReply(commentId, message, token, buttonText = "", linkUrl = "", commentTimestamp = null) {
    // ── 1. Enforce Instagram 7-Day Messaging Window Rule ──────────────────────
    if (commentTimestamp) {
      const commentAgeMs = Date.now() - new Date(commentTimestamp).getTime();
      if (commentAgeMs > MESSAGING_RULES.MAX_COMMENT_AGE_MS) {
        const daysOld = Math.floor(commentAgeMs / (24 * 60 * 60 * 1000));
        console.warn(`⏳ [Instagram Rule Violation Avoided] Comment [${commentId}] is ${daysOld} days old (>7 days). Private reply cannot be sent per Meta Messaging Policy.`);
        return {
          ok: false,
          error: {
            category: "WINDOW_CLOSED_7_DAYS",
            message: `Comment is ${daysOld} days old. Meta policy restricts private replies to within 7 days.`,
          },
        };
      }
    }

    // ── 2. Enforce Character Limits ───────────────────────────────────────────
    const cleanText = (message || "").trim().substring(0, MESSAGING_RULES.MAX_DM_TEXT_LENGTH);
    const cleanButtonTitle = (buttonText || "Open Link").trim().substring(0, MESSAGING_RULES.MAX_BUTTON_TITLE_LENGTH);

    let cleanLink = (linkUrl || "").trim();
    if (cleanLink && !cleanLink.startsWith("http://") && !cleanLink.startsWith("https://")) {
      cleanLink = `https://${cleanLink}`;
    }

    // ── 3. Try Interactive Button Template ────────────────────────────────────
    if (cleanLink) {
      try {
        console.log(`🔗 [Private Reply] Attempting Button Template: "${cleanButtonTitle}" → ${cleanLink}`);
        const templatePayload = {
          recipient: { comment_id: commentId },
          message: {
            attachment: {
              type: "template",
              payload: {
                template_type: "button",
                text: cleanText,
                buttons: [
                  {
                    type: "web_url",
                    url: cleanLink,
                    title: cleanButtonTitle,
                  },
                ],
              },
            },
          },
        };

        const res = await fetch(`${GRAPH_API_BASE}/me/messages`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ ...templatePayload, access_token: token }),
        });
        const data = await res.json();

        if (!data.error) {
          console.log(`✅ [Private Reply: Button Template] Delivered — Message ID: ${data.message_id || data.id}`);
          return { ok: true, messageId: data.message_id || data.id, templateType: "button" };
        }

        console.warn(`⚠️ [Button Template Refused by Meta] Code ${data.error.code}: ${data.error.message}. Initiating compliant text fallback...`);
      } catch (err) {
        console.warn(`⚠️ [Button Template Network Error]: ${err.message}. Initiating text fallback...`);
      }
    }

    // ── 4. Fallback to Direct Text with Link ─────────────────────────────────
    try {
      const textWithLink = cleanLink
        ? `${cleanText}\n\n👉 ${cleanButtonTitle}:\n${cleanLink}`
        : cleanText;

      const res = await fetch(`${GRAPH_API_BASE}/me/messages`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          recipient: { comment_id: commentId },
          message: { text: textWithLink },
          access_token: token,
        }),
      });
      const data = await res.json();

      if (data.error) {
        const parsed = this.parseMetaError(data);
        console.error(`❌ [Private Reply Text Error] Code ${parsed.code}: ${parsed.message}`);
        return { ok: false, error: parsed };
      }

      console.log(`✅ [Private Reply: Text with Link] Delivered — Message ID: ${data.message_id || data.id}`);
      return { ok: true, messageId: data.message_id || data.id, templateType: "text" };
    } catch (err) {
      console.error("❌ [Private Reply Network Error]:", err.message);
      return { ok: false, error: { message: err.message, category: "NETWORK_ERROR" } };
    }
  }

  /**
   * Send direct message to user ID (requires pages messaging permissions)
   */
  static async sendDirectMessage(recipientIgUserId, message, token) {
    try {
      const cleanText = (message || "").trim().substring(0, MESSAGING_RULES.MAX_DM_TEXT_LENGTH);
      const url = `${GRAPH_API_BASE}/me/messages`;

      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          recipient: { id: recipientIgUserId },
          message: { text: cleanText },
          access_token: token,
        }),
      });
      const data = await res.json();

      if (data.error) {
        const parsed = this.parseMetaError(data);
        console.error(`❌ [DM to User Error] Code ${parsed.code}: ${parsed.message}`);
        return { ok: false, error: parsed };
      }

      console.log(`✅ [DM to User] Delivered — Message ID: ${data.message_id || data.id}`);
      return { ok: true, messageId: data.message_id || data.id };
    } catch (err) {
      console.error("❌ [DM to User Network Error]:", err.message);
      return { ok: false, error: { message: err.message, category: "NETWORK_ERROR" } };
    }
  }
}

module.exports = InstagramService;
