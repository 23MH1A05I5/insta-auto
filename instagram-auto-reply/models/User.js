const mongoose = require("mongoose");
const bcrypt   = require("bcryptjs");

const instagramSchema = new mongoose.Schema({
  userId       : { type: String, default: null },
  username     : { type: String, default: null },
  accountType  : { type: String, default: null },   // CREATOR | BUSINESS
  accessToken  : { type: String, default: null },   // encrypted at rest in production
  tokenExpiry  : { type: Date,   default: null },
  connectedAt  : { type: Date,   default: null },
}, { _id: false });

const userSchema = new mongoose.Schema({
  name      : { type: String, required: true, trim: true },
  email     : { type: String, required: true, unique: true, lowercase: true, trim: true },
  password  : { type: String, required: true, minlength: 6 },
  instagram : { type: instagramSchema, default: () => ({}) },
  createdAt : { type: Date, default: Date.now },
}, { timestamps: true });

// Hash password before saving
userSchema.pre("save", async function () {
  if (!this.isModified("password")) return;
  const salt = await bcrypt.genSalt(12);
  this.password = await bcrypt.hash(this.password, salt);
});

// Instance method: compare password
userSchema.methods.comparePassword = function (candidate) {
  return bcrypt.compare(candidate, this.password);
};

// Never return password or token in JSON
userSchema.methods.toSafeObject = function () {
  const obj = this.toObject();
  delete obj.password;
  if (obj.instagram) delete obj.instagram.accessToken;
  return obj;
};

module.exports = mongoose.model("User", userSchema);
