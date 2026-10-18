// ════════════════════════════════════════════════════════════════════════════
// Database Connection Manager (MongoDB via Mongoose)
// ════════════════════════════════════════════════════════════════════════════
const mongoose = require("mongoose");
const dns = require("dns");

const connectDatabase = async () => {
  const MONGO_URI = process.env.MONGO_URI || "mongodb://127.0.0.1:27017/instauto";
  
  // Use public DNS for mongodb+srv SRV record resolution
  if (MONGO_URI.startsWith("mongodb+srv://")) {
    try {
      dns.setServers(["8.8.8.8", "1.1.1.1", "8.8.4.4"]);
    } catch (_) {}
  }

  try {
    await mongoose.connect(MONGO_URI);
    const sanitized = MONGO_URI.replace(/:([^@]+)@/, ":****@");
    console.log(`✅ MongoDB connected successfully: ${sanitized}`);
  } catch (err) {
    console.error("❌ MongoDB connection failed:", err.message);
  }

  mongoose.connection.on("error", (err) => {
    console.error("⚠️ MongoDB runtime error:", err.message);
  });

  mongoose.connection.on("disconnected", () => {
    console.warn("⚠️ MongoDB disconnected. Attempting reconnection...");
  });

  mongoose.connection.on("reconnected", () => {
    console.log("🔄 MongoDB reconnected successfully.");
  });
};

module.exports = { connectDatabase };
