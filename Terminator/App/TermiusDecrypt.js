#!/usr/bin/env node

const fs = require("fs");

async function main() {
  const [input, keytarPath, libtermiusPath, preferredService] = process.argv.slice(2);
  if (!input || !keytarPath || !libtermiusPath || !preferredService) {
    throw new Error("Missing Termius decryptor arguments");
  }

  const root = JSON.parse(fs.readFileSync(input, "utf8"));
  const keytar = require(keytarPath);
  const { crypto } = require(libtermiusPath);
  crypto.init();

  const services = [
    preferredService,
    `${preferredService} (MAS)`,
    "Termius",
    "Termius (MAS)",
    "termius",
    "com.termius-dmg.mac",
    "com.termius.mac",
  ];
  const ciphertext = firstCiphertext(root);
  let system = null;
  const indexedDBKey = findNamedValue(root, "localKey");
  const candidateKeys = [];
  for (const service of [...new Set(services)]) {
    let value = null;
    try { value = await keytar.getPassword(service, "localKey"); } catch {}
    if (value) candidateKeys.push(value);
  }
  if (indexedDBKey) candidateKeys.push(indexedDBKey);
  for (const value of [...new Set(candidateKeys)]) {
    try {
      const candidate = crypto.systems.FromEncryptionKey(Buffer.from(value, "base64"));
      if (!ciphertext || candidate.decrypt(Buffer.from(ciphertext, "base64")) !== null) {
        system = candidate;
        break;
      }
    } catch {}
  }
  if (!system) throw new Error("Termius localKey was not found or did not match this profile");

  process.stdout.write(JSON.stringify(walk(root, system)));
}

function findNamedValue(root, wantedKey) {
  let found = null;
  const seen = new WeakSet();
  function visit(value, key = "") {
    if (found || !value) return;
    if (key === wantedKey && typeof value === "string" && /^[A-Za-z0-9+/=]{32,}$/.test(value)) {
      found = value;
      return;
    }
    if (typeof value !== "object" || seen.has(value)) return;
    seen.add(value);
    for (const [childKey, child] of Object.entries(value)) visit(child, childKey);
  }
  visit(root);
  return found;
}

function firstCiphertext(value) {
  if (typeof value === "string" && isCiphertext(value)) return value;
  if (!value || typeof value !== "object") return null;
  for (const item of Array.isArray(value) ? value : Object.values(value)) {
    const found = firstCiphertext(item);
    if (found) return found;
  }
  return null;
}

function isCiphertext(value) {
  if (typeof value !== "string" || value.length < 56 || value.length % 4 !== 0) return false;
  try {
    const bytes = Buffer.from(value, "base64");
    return bytes.length >= 42 && bytes[0] === 4 && bytes[1] === 1;
  } catch { return false; }
}

function walk(value, system) {
  if (typeof value === "string") {
    if (!isCiphertext(value)) return value;
    try {
      const clear = system.decrypt(Buffer.from(value, "base64"));
      return clear === null ? value : clear.toString();
    } catch { return value; }
  }
  if (!value || typeof value !== "object") return value;
  if (Array.isArray(value)) return value.map((item) => walk(item, system));
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, walk(item, system)]));
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
});
