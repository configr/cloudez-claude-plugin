// cloudez-mcp 0.2.19 — gerado por 'npm run bundle'. Nao edite.

// src/auth.ts
import { readFile } from "node:fs/promises";

// src/config.ts
function apiUrl() {
  return (process.env.CLOUDEZ_API_URL || "https://api.cloudez.io").replace(/\/+$/, "");
}
function validatePath() {
  return process.env.CLOUDEZ_API_VALIDATE_PATH || "/auth/token/validate/";
}
function apiTimeoutMs() {
  const raw = Number(process.env.CLOUDEZ_API_TIMEOUT);
  return Number.isFinite(raw) && raw > 0 ? raw * 1e3 : 1e4;
}
function tokenFile() {
  const override = process.env.CLOUDEZ_TOKEN_FILE;
  if (override) return override;
  const home = process.env.HOME || process.env.USERPROFILE || "";
  return `${home}/.cloudez/token`;
}

// src/auth.ts
async function resolveToken() {
  const fromEnv = process.env.CLOUDEZ_TOKEN?.trim();
  if (fromEnv) return fromEnv;
  try {
    const contents = (await readFile(tokenFile(), "utf8")).trim();
    return contents || null;
  } catch {
    return null;
  }
}
async function tokenSource() {
  if (process.env.CLOUDEZ_TOKEN?.trim()) return "env";
  try {
    const contents = (await readFile(tokenFile(), "utf8")).trim();
    return contents ? "file" : "none";
  } catch {
    return "none";
  }
}
async function verifyToken(token) {
  try {
    const response = await fetch(`${apiUrl()}${validatePath()}`, {
      method: "GET",
      headers: { Authorization: `Token ${token}` },
      signal: AbortSignal.timeout(apiTimeoutMs())
    });
    if (response.ok) return "valid";
    if (response.status === 401 || response.status === 403) return "invalid";
    return "unknown";
  } catch {
    return "unknown";
  }
}

// src/token-store.ts
import { chmod, mkdir, readFile as readFile2, rm, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
async function escreverSegredo(arquivo, token) {
  await writeFile(arquivo, token + "\n", { mode: 384 });
  await chmod(arquivo, 384);
}
async function saveToken(token) {
  const arquivo = tokenFile();
  let anterior = null;
  try {
    anterior = (await readFile2(arquivo, "utf8")).trim() || null;
  } catch {
  }
  await mkdir(dirname(arquivo), { recursive: true, mode: 448 });
  await escreverSegredo(arquivo, token);
  const verdict = await verifyToken(token);
  if (verdict === "invalid") {
    if (anterior) await escreverSegredo(arquivo, anterior);
    else await rm(arquivo, { force: true });
    return { verdict, restored: Boolean(anterior) };
  }
  return { verdict, restored: false };
}
export {
  resolveToken,
  saveToken,
  tokenFile,
  tokenSource,
  verifyToken
};
