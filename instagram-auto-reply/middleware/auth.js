const jwt  = require("jsonwebtoken");
const User = require("../models/User");

const JWT_SECRET = process.env.JWT_SECRET || "change_me_in_production";

/**
 * Middleware: verifies Bearer JWT and attaches req.user (safe object, no password/token).
 */
async function authenticate(req, res, next) {
  const authHeader = req.headers.authorization || "";
  if (!authHeader.startsWith("Bearer ")) {
    return res.status(401).json({ ok: false, error: "No token provided" });
  }

  const token = authHeader.slice(7);
  try {
    const payload = jwt.verify(token, JWT_SECRET);
    const user    = await User.findById(payload.id).select("-password");
    if (!user) return res.status(401).json({ ok: false, error: "User not found" });
    req.user = user;
    next();
  } catch (err) {
    return res.status(401).json({ ok: false, error: "Invalid or expired token" });
  }
}

module.exports = { authenticate };
