// ════════════════════════════════════════════════════════════════════════════
// AI Reply Suggestion Service
// Generates diverse, high-converting replies adhering to Instagram Community Guidelines
// ════════════════════════════════════════════════════════════════════════════

class AiReplyService {
  /**
   * Generates categorized reply suggestions based on comment text and product context
   */
  static generateSuggestions(commentText, options = {}) {
    if (!commentText || !commentText.trim()) {
      return [];
    }

    const text = commentText.toLowerCase().trim();
    const username = options.username ? `@${options.username}` : "there";
    const productName = options.productName || process.env.PRODUCT_NAME || "our product";
    const price = options.price || process.env.PRODUCT_PRICE || "";
    const currency = options.currency || process.env.CURRENCY || "Rs. ";
    const link = options.link || process.env.PRODUCT_LINK || "https://yourwebsite.com";
    const priceStr = price ? `${currency}${price}` : "";

    const suggestions = [];

    // 1. Price / Cost / Rate inquiries
    if (/price|cost|how much|rate|charge|fee|₹|rs\.|rupee|inr|kitna/i.test(text)) {
      if (priceStr) {
        suggestions.push(`Hi ${username}! The ${productName} is currently ${priceStr}. Just sent you the direct link in your DMs! 🛍️✨`);
        suggestions.push(`Thanks for asking ${username}! It's ${priceStr}. Check your DMs for details & exclusive offer 🎁`);
        suggestions.push(`Hey ${username}! It's available for ${priceStr} with free shipping! Check your DM for the instant order link 🚀`);
      } else {
        suggestions.push(`Hi ${username}! Sent you our current pricing & special bundle deals in your DMs! 📩✨`);
        suggestions.push(`Thanks for reaching out ${username}! All the pricing details are waiting in your DMs 💬`);
      }
    }
    // 2. Link / Where to buy / Shop
    else if (/link|buy|order|purchase|where.*get|get.*where|shop|website|store|grab/i.test(text)) {
      suggestions.push(`Hey ${username}! Dropped the direct link right in your DMs! Tap it to explore 📲🔗`);
      suggestions.push(`Check your DMs ${username}! Sent you the official link so you don't miss out ✨`);
      suggestions.push(`Just sent the link your way ${username}! Let us know if you need any help with ordering 💜`);
    }
    // 3. Compliments / Appreciation / Hype
    else if (/love|amazing|great|awesome|beautiful|nice|wow|fire|cool|lit|stunner|gorgeous|perfect/i.test(text)) {
      suggestions.push(`Thank you so much ${username}! That truly makes our day! ❤️🙌`);
      suggestions.push(`Aww thank you ${username}! We poured so much love into this ✨`);
      suggestions.push(`You're amazing ${username}! Thanks for the incredible love & support 🌟`);
    }
    // 4. Availability / Stock
    else if (/available|in stock|stock|restock|ready/i.test(text)) {
      suggestions.push(`Yes ${username}! It's in stock right now and ready for dispatch. Check your DMs for the order link 📦🚀`);
      suggestions.push(`Hey ${username}! Fresh stock just landed! Sent the details straight to your DMs ⚡`);
    }
    // 5. Questions / Information / Quality / Shipping
    else if (/\?|how|what|when|which|shipping|delivery|dispatch|material|quality|features|specs/i.test(text)) {
      suggestions.push(`Great question ${username}! Sent you full details and specs in your DMs 📋✨`);
      suggestions.push(`Hi ${username}! We deliver nationwide with fast courier service. Dropped more details in your DMs 🚚`);
      suggestions.push(`Hey ${username}! Just sent you an in-depth answer in your DMs so you have all the facts 💜`);
    }
    // 6. Generic friendly default variations
    else {
      suggestions.push(`Thank you for your comment ${username}! We appreciate your support 🙌`);
      suggestions.push(`Hi ${username}! Thanks for stopping by! Check your DMs if you have any questions ✨`);
      suggestions.push(`Hey ${username}! Sent you a quick DM with more details about ${productName} 😊`);
    }

    return suggestions.slice(0, 3);
  }
}

module.exports = AiReplyService;
