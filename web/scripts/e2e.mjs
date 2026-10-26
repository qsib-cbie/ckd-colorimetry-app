import { spawn } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline";
import { once } from "node:events";

const web = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const root = resolve(web, "..");
const scratch = mkdtempSync(join(tmpdir(), "ckd-e2e-"));
const token = randomUUID();
const python = process.env.CKD_PYTHON || join(root, ".venv/bin/python");
const executable = process.env.CKD_ENGINE_EXECUTABLE;
const arguments_ = ["--workspace", join(scratch, "workspace"), "--state-dir", join(scratch, "settings"), "--parent-pipe"];
if (!executable) arguments_.push("--static-dir", join(web, "dist"));
const engine = spawn(executable || python, executable ? arguments_ : ["-m", "ckd.runtime", ...arguments_], {
  cwd: root,
  env: { ...process.env, PYTHONPATH: join(root, "api"), CKD_DESKTOP_TOKEN: token },
  stdio: ["pipe", "pipe", "inherit"],
});
const exited = once(engine, "exit");
try {
  const lines = createInterface({ input: engine.stdout });
  const line = await Promise.race([once(lines, "line").then(([value]) => value), exited.then(() => { throw Error("Local engine exited before startup"); }), new Promise((_, reject) => { setTimeout(() => reject(Error("Engine startup timed out")), 30000).unref(); })]);
  const baseURL = new URL(JSON.parse(line).url).origin;
  let ready = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    try { ready = (await fetch(`${baseURL}/api/ready`, { headers: { "X-CKD-Token": token } })).ok; } catch {}
    if (ready) break;
    await new Promise((done) => setTimeout(done, 100));
  }
  if (!ready) throw Error("Engine did not become ready");
  const require = createRequire(import.meta.url);
  const child = spawn(process.execPath, [require.resolve("@playwright/test/cli"), "test", ...process.argv.slice(2)], { cwd: web, env: { ...process.env, CKD_BASE_URL: baseURL, CKD_TEST_TOKEN: token }, stdio: "inherit" });
  const [code] = await once(child, "exit");
  process.exitCode = code ?? 1;
} finally {
  engine.stdin.end();
  await exited;
  console.log(`Test workspace preserved at ${scratch}`);
}
