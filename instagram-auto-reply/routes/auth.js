const router   = require("express").Router();
const jwt      = require("jsonwebtoken");
const User     = require("../models/User");
const { authenticate } = require("../middleware/auth");

const JWT_SECRET  = process.env.JWT_SECRET  || "change_me_in_production";
const JWT_EXPIRES = process.env.JWT_EXPIRES || "7d";

function signToken(id) {
  return jwt.sign({ id }, JWT_SECRET, { expiresIn: JWT_EXPIRES });
}

// ── POST /api/auth/register ──────────────────────────────────────────────────
router.post("/register", async (req, res) => {
  try {
    const { name, email, password } = req.body;
    if (!name || !email || !password) {
      return res.status(400).json({ ok: false, error: "name, email and password are required" });
    }
    const exists = await User.findOne({ email: email.toLowerCase() });
    if (exists) return res.status(409).json({ ok: false, error: "Email already registered" });

    const user  = await User.create({ name, email, password });
    const token = signToken(user._id);
    return res.status(201).json({ ok: true, token, user: user.toSafeObject() });
  } catch (err) {
    console.error("[/register]", err.message);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

// ── POST /api/auth/login ─────────────────────────────────────────────────────
router.post("/login", async (req, res) => {
  try {
    const { email, password } = req.body;
    if (!email || !password) {
      return res.status(400).json({ ok: false, error: "email and password are required" });
    }
    const user = await User.findOne({ email: email.toLowerCase() });
    if (!user || !(await user.comparePassword(password))) {
      return res.status(401).json({ ok: false, error: "Invalid credentials" });
    }
    const token = signToken(user._id);
    return res.json({ ok: true, token, user: user.toSafeObject() });
  } catch (err) {
    console.error("[/login]", err.message);
    return res.status(500).json({ ok: false, error: "Server error" });
  }
});

// ── GET /api/auth/me ─────────────────────────────────────────────────────────
router.get("/me", authenticate, (req, res) => {
  res.json({ ok: true, user: req.user.toSafeObject() });
});

// ── DELETE /api/auth/account — Permanently delete account & all data ──────────
// Required by Meta Platform Terms for user data deletion compliance
router.delete("/account", authenticate, async (req, res) => {
  try {
    const userId = req.user._id;
    const igUserId = req.user.instagram?.userId;

    // Delete automations and their embedded activity logs
    try {
      const Automation = require("../models/Automation");
      await Automation.deleteMany({ userId });
    } catch (_) {}

    // Delete the user account itself
    await User.findByIdAndDelete(userId);

    console.log(`[DeleteAccount] Permanently deleted account for user ${userId} (IG: ${igUserId || "none"})`);
    return res.json({ ok: true, message: "Account and all associated data permanently deleted" });
  } catch (err) {
    console.error("[DeleteAccount]", err.message);
    return res.status(500).json({ ok: false, error: "Failed to delete account" });
  }
});

// ── PUT /api/auth/change-password ──────────────────────────────────────────
router.put("/change-password", authenticate, async (req, res) => {
  try {
    const { currentPassword, newPassword } = req.body;
    if (!currentPassword || !newPassword) {
      return res.status(400).json({ ok: false, error: "Current and new password are required" });
    }
    if (newPassword.length < 6) {
      return res.status(400).json({ ok: false, error: "New password must be at least 6 characters" });
    }

    const user = await User.findById(req.user._id);
    if (!user) {
      return res.status(404).json({ ok: false, error: "User not found" });
    }

    const isMatch = await user.comparePassword(currentPassword);
    if (!isMatch) {
      return res.status(401).json({ ok: false, error: "Current password is incorrect" });
    }

    user.password = newPassword;
    await user.save();

    console.log(`[ChangePassword] Password updated successfully for user ${user._id}`);
    return res.json({ ok: true, message: "Password updated successfully" });
  } catch (err) {
    console.error("[/change-password]", err.message);
    return res.status(500).json({ ok: false, error: "Failed to update password" });
  }
});

// ── PUT /api/auth/profile ──────────────────────────────────────────────────
router.put("/profile", authenticate, async (req, res) => {
  try {
    const { name } = req.body;
    if (!name || !name.trim()) {
      return res.status(400).json({ ok: false, error: "Name is required" });
    }

    const user = await User.findById(req.user._id);
    if (!user) {
      return res.status(404).json({ ok: false, error: "User not found" });
    }

    user.name = name.trim();
    await user.save();

    return res.json({ ok: true, user: user.toSafeObject() });
  } catch (err) {
    console.error("[/profile]", err.message);
    return res.status(500).json({ ok: false, error: "Failed to update profile" });
  }
});

module.exports = router;
