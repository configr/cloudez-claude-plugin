// cloudez-mcp 0.2.1 — gerado por 'npm run bundle'. Nao edite.

// src/deploy-state.ts
import { mkdirSync, readdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

// src/errors.ts
var ToolError = class extends Error {
  body;
  constructor(code, message, opts = {}) {
    super(message);
    this.name = "ToolError";
    this.body = {
      error: {
        code,
        message,
        retryable: opts.retryable ?? false,
        ...opts.hint ? { hint: opts.hint } : {}
      }
    };
  }
};

// src/deploy-state.ts
function stateDir() {
  return process.env.CLOUDEZ_STATE_DIR || join(homedir(), ".cloudez", "state");
}
function stateDirLegado() {
  return ".cloudez/state";
}
function statePath(deployId) {
  return join(stateDir(), `${deployId}.json`);
}
function loadState(deployId) {
  for (const dir of [stateDir(), stateDirLegado()]) {
    try {
      return JSON.parse(readFileSync(join(dir, `${deployId}.json`), "utf8"));
    } catch {
    }
  }
  throw new ToolError("deploy_not_found", `deploy_id '${deployId}' desconhecido. Chame cloudez_begin_deploy primeiro.`);
}
function saveState(state) {
  const file = statePath(state.deploy_id);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(state, null, 2));
  return state;
}
export {
  loadState,
  saveState,
  statePath
};
