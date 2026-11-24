// Runs automatically in every new T3 Code worktree (see t3.json).
// Gives the fresh checkout what git does not carry: dev tooling, the Python
// environment, the SeedVR2 runtime source, and the model weights.
import { execFileSync } from "node:child_process";
import { existsSync, symlinkSync } from "node:fs";
import { dirname, resolve } from "node:path";

const worktree = process.cwd();

function run(command, args) {
  console.log(`\n$ ${command} ${args.join(" ")}`);
  execFileSync(command, args, { cwd: worktree, stdio: "inherit" });
}

// The main checkout is the parent of the repository's shared .git directory.
function mainCheckout() {
  const commonDir = execFileSync(
    "git",
    ["rev-parse", "--path-format=absolute", "--git-common-dir"],
    {
      cwd: worktree,
      encoding: "utf8",
    },
  ).trim();
  return dirname(commonDir);
}

// Reuse the main checkout's ~400 MB of weights instead of downloading them again.
// setup.sh still verifies their checksums below.
const main = mainCheckout();
const models = resolve(worktree, "models");
const mainModels = resolve(main, "models");
if (main !== worktree && !existsSync(models) && existsSync(mainModels)) {
  symlinkSync(mainModels, models);
  console.log(`Linked models/ from ${mainModels}`);
}

run("pnpm", ["install", "--frozen-lockfile"]);
// uv sync (locked), input/output folders, SeedVR2 source, then model checks.
run("./setup.sh", []);

console.log("\nWorktree ready. Run `pnpm run check` for the fast checks.");
