#!/usr/bin/env -S mise exec -- bun
import { $ } from "bun";
import { existsSync } from "fs";

process.env.FORCE_COLOR = "1";

// dist/ holds only what dist makes, everything a release ships: the
// tarball, its .sha256 (the name install's curl line has always had beside
// it), SHA256SUMS, and install.sh, also a release asset of its own. What
// they are made from is in packaging/.
const TARBALL = "glim-linux-x86_64.tar.gz";
const STAGING = "zig-out/staging";
const PACKAGING = ["install.sh", "glim.service", "glim-follow.service", "glim.conf"];

// ─── Version ────────────────────────────────────────────────────────────────

/** 0.<commits>.<build>: the build number on CI, a timestamp anywhere else. */
async function version(): Promise<string> {
    const branch = process.env.GITHUB_REF_NAME
        || (await $`git rev-parse --abbrev-ref HEAD`.quiet().nothrow()).text().trim();
    const buildNumber = process.env.GITHUB_RUN_NUMBER
        || new Date().toISOString().replace(/[-:T]/g, "").split(".")[0];
    const revisions = (await $`git rev-list --count ${branch}`.quiet().nothrow()).text().trim() || "0";
    return `0.${revisions}.${buildNumber}`;
}

// ─── Commands ──────────────────────────────────────────────────────────────

/** Static, for any x86_64 Linux: baseline CPU, no libc. */
export async function build() {
    const ver = await version();
    console.log(`Building v${ver}...`);
    await $`zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux -Dcpu=baseline -Dversion=${ver}`;
}

/** Under a private bus when dbus-run-session is there, for the D-Bus
 *  client's test: it is handed that bus's address and never sees the session
 *  this was run from. Without one, that test is skipped. */
export async function test() {
    const { exitCode } = await $`which dbus-run-session`.quiet().nothrow();
    if (exitCode === 0) {
        await $`dbus-run-session -- sh -c 'GLIM_TEST_BUS="$DBUS_SESSION_BUS_ADDRESS" exec zig build test --summary all'`;
    } else {
        await $`zig build test --summary all`;
    }
}

export async function lint() {
    await $`shellcheck packaging/install.sh scripts/*.sh`;
}

export async function clean() {
    await $`rm -rf zig-out .zig-cache dist`;
    console.log("Cleaned.");
}

/** Default: what a change has to get through before it is pushed. */
export async function dev() {
    await lint();
    await test();
    await build();
}

/** The release, into dist/: the tarball (the binary, everything install.sh
 *  puts in place, README and LICENSE), its .sha256, install.sh, and
 *  SHA256SUMS over the three. */
export async function dist() {
    if (!existsSync("zig-out/bin/glim")) await build();
    await $`rm -rf ${STAGING} dist && mkdir -p ${STAGING} dist`;
    await $`cp zig-out/bin/glim ${PACKAGING.map(f => `packaging/${f}`)} README.md LICENSE ${STAGING}/`;
    await $`tar -czf dist/${TARBALL} -C ${STAGING} .`;
    await $`rm -rf ${STAGING}`;
    await $`cp packaging/install.sh dist/`;
    await $`sha256sum ${TARBALL} > ${TARBALL}.sha256`.cwd("dist");
    await $`sha256sum ${TARBALL} install.sh > SHA256SUMS`.cwd("dist");
    console.log(`Tarball: dist/${TARBALL} (v${await version()})`);
}

/** The flake, with the tarball in dist/ as its release: the package is a
 *  release tarball fetched (flake.nix), so this stages a nix/release.json
 *  for the one dist made and puts it in the store where fetchurl would
 *  (scripts/nix-local-release.sh), then runs the flake's checks, the NixOS
 *  VM test among them, against it. The staged release.json is taken out
 *  again whatever happens: it belongs on a release tag's own commit, never
 *  on trunk. */
export async function nix() {
    const { exitCode } = await $`which nix`.quiet().nothrow();
    if (exitCode !== 0) {
        console.log("nix: skipped (nix not installed)");
        return;
    }
    if (!existsSync(`dist/${TARBALL}`)) await dist();
    // The version the binary in the tarball says, which a timestamped
    // local build would not otherwise agree on with a second version().
    const work = (await $`mktemp -d`.text()).trim();
    try {
        await $`tar -xzf dist/${TARBALL} -C ${work} ./glim`;
        const ver = (await $`${work}/glim --version`.text()).trim();
        await $`scripts/nix-local-release.sh ${ver} dist`;
        await $`nix flake check --print-build-logs`;
    } finally {
        await $`rm -rf ${work}`;
        await $`git rm -q --cached --ignore-unmatch nix/release.json`.nothrow();
        await $`rm -f nix/release.json`;
    }
}

// ─── Command dispatch ──────────────────────────────────────────────────────

async function printVersion() {
    console.log(await version());
}

const commands: Record<string, Function> = {
    dev, build, test, lint, clean, dist, nix, version: printVersion,
};

const command = process.argv[2] || "dev";
const fn = commands[command];
if (!fn) {
    console.error(`Unknown command: ${command}`);
    console.error(`Available: ${Object.keys(commands).join(", ")}`);
    process.exit(1);
}
try {
    await fn(...process.argv.slice(3));
} catch (e: any) {
    console.error(`Command failed: ${command}`);
    console.error(e.message || e);
    process.exit(1);
}
