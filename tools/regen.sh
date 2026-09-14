#!/usr/bin/env bash
# Regenerate src/gen/*.c for Super Metroid from a verified ROM.
#
# Generated C is derived from copyrighted ROM data and is never committed;
# every developer regenerates from their own copy. The ROM digests come from
# rom_identity.txt, which the build and the release workflow read too, so
# there is one place to change when a revision changes.
#
# Flags:
#   --rom <path>  ROM to generate from. Defaults to a known filename at the
#                 repo root, but the ROM does not have to live in the repo —
#                 keeping it on your own drive is the better habit, and
#                 SNESRECOMP_ROM sets it once for a shell.
#   --no-verify   skip the ROM digest check (for a revision this project has
#                 not been pinned to yet — expect the generated C to differ)
#   --no-cfg-roots
#                 do NOT seed analysis from the func declarations in
#                 recomp/*.cfg. You almost certainly do not want this: those
#                 declarations ARE this port's static coverage, harvested from
#                 the snesrev/sm decomp, and seeding them is what lets a clean
#                 checkout reproduce the AOT coverage a PLAYER gets with no run
#                 and no profile manifest.
#   --cfg-roots   seed from cfg func declarations. NOW THE DEFAULT (2026-09-13);
#                 the flag is still accepted so existing invocations keep
#                 working.
#   --profile-manifest <path>
#                 additionally seed optional AOT roots from a tier-2 coverage
#                 manifest (repeatable). This is the burn-down loop's promote
#                 step, NOT the default: the in-launcher "Generate & rebuild"
#                 wizard players use cannot pass a profile at all, so a default
#                 that used one made every developer regenerate a different
#                 program than the one being shipped. See the note below.
#   --strict-idempotent
#                 generate a SECOND time into a scratch tree and require
#                 byte-identical output. Generation is a pure function of
#                 (ROM, cfg, flags); anything that leaks run order or a
#                 timestamp into the emitted C shows up here and nowhere else.
#   -h|--help     this message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

VERIFY=1
CFG_ROOTS=1
STRICT_IDEMPOTENT=0
PROFILES=()
ROM="${SNESRECOMP_ROM:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --rom) ROM=$2; shift 2 ;;
    --no-verify) VERIFY=0; shift ;;
    --cfg-roots) CFG_ROOTS=1; shift ;;
    --no-cfg-roots) CFG_ROOTS=0; shift ;;
    --profile-manifest) PROFILES+=("$2"); shift 2 ;;
    --strict-idempotent) STRICT_IDEMPOTENT=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -n '/^# /p' | sed 's/^# //'; exit 0 ;;
    *) echo "regen.sh: unknown flag: $1 (try --help)" >&2; exit 2 ;;
  esac
done

SNESRECOMP_ROOT="${SNESRECOMP_ROOT:-snesrecomp}"
CLI="$SNESRECOMP_ROOT/snesrecomp_cli.py"
if [ ! -f "$CLI" ]; then
  echo "regen.sh: $CLI missing — run: git submodule update --init --recursive" >&2
  exit 1
fi

PYTHON="${PYTHON:-$(command -v python3 || command -v python || true)}"
if [ -z "$PYTHON" ]; then
  echo "regen.sh: no python3 on PATH" >&2
  exit 1
fi

# The framework parses rom_identity.txt (the same parser CI uses), so this
# script carries no copy of a digest to forget on a revision bump.
IDENTITY="$SNESRECOMP_ROOT/tools/rom_identity.py"
EXPECTED_CRC32="${SNESRECOMP_EXPECTED_CRC32:-$("$PYTHON" "$IDENTITY" "$ROOT/rom_identity.txt" --get expected_crc32)}"
EXPECTED_SHA256="${SNESRECOMP_EXPECTED_SHA256:-$("$PYTHON" "$IDENTITY" "$ROOT/rom_identity.txt" --get expected_sha256)}"

# --rom / SNESRECOMP_ROM win; otherwise look for a known name at the root.
if [ -z "$ROM" ]; then
  for cand in "Super Metroid (Japan, USA) (En,Ja).sfc" "Super Metroid (Japan, USA) (En,Ja).sfc" "Super Metroid (Japan, USA) (En,Ja).smc"; do
    if [ -f "$cand" ]; then ROM="$cand"; break; fi
  done
fi
if [ -z "$ROM" ] || [ ! -f "$ROM" ]; then
  echo "regen.sh: no ROM found." >&2
  echo "          Pass --rom /path/to/Super Metroid (Japan, USA) (En,Ja).sfc, set SNESRECOMP_ROM, or put" >&2
  echo "          it at the repo root. You must legally own a copy of" >&2
  echo "          Super Metroid." >&2
  exit 1
fi

VERIFY_ARGS=()
if [ "$VERIFY" -eq 1 ]; then
  VERIFY_ARGS=(--expected-crc32 "$EXPECTED_CRC32" --expected-sha256 "$EXPECTED_SHA256")
  echo "== Verifying $ROM =="
  "$PYTHON" "$CLI" verify-rom --rom "$ROM" "${VERIFY_ARGS[@]}"
else
  echo "== Skipping ROM verification (--no-verify) =="
fi

GEN_ARGS=(--rom "$ROM" --cfg-dir recomp --out-dir src/gen
          --funcs-h recomp/funcs.h --project-root "$ROOT")

# This title's own generation inputs. The PIPELINE is the framework's
# (snesrecomp_cli generate); the choices below are declarations about Super
# Metroid. They are plain snesrecomp_cli options (see `generate --help`), so
# nothing here forks the engine's pipeline.
#
# History, because this line has moved twice:
#
#   2026-09-11  A template sync replaced this script wholesale with the
#               scaffold's copy, deleting `--source-root src` and
#               `--profile-manifest`. That left profiles/attract_tier2.json
#               orphaned and silently changed the AOT/LLE split. Restored.
#   2026-09-13  Restoring them was the wrong repair. A developer regen and the
#               regen a PLAYER runs were two different programs:
#
#                 dev (this script)  --profile-manifest, no --cfg-roots
#                 player (launcher)  --cfg-roots, no profile
#
#               The in-launcher "Generate & rebuild" wizard is
#               snesrecomp_codegen_host.c; snesrecomp_codegen_host_autowire()
#               hardcodes cfg.cfg_roots = 1, and SnesrecompCodegenHostConfig
#               has no profile-manifest field at all, so a profile CANNOT
#               reach a player's regen. Measured on this ROM: 864 AOT variants
#               / 54 TUs the dev way, 4716 / 98 the player way. CI only ever
#               builds a SETUP HOST (release.yml asserts src/gen is empty), so
#               no job on any platform compiles or links generated C — the
#               configuration every player builds was the one nobody built.
#               Windows players hit undefined cross-variant symbols
#               (`<Name>_M0X0`) in it while developers saw a clean tree.
#
#               So this script now defaults to what the launcher does, the way
#               GundamWingEndlessDuelSNESRecomp's regen.sh already did:
#               --cfg-roots on, no profile manifest. --source-root src is gone
#               because it was a no-op — with no --source-root, v2_emit falls
#               back to <cfg-dir>/../src, which IS src/ (v2_emit.py, "if not
#               source_roots and not args.no_host_root_scan").
#
# profiles/attract_tier2.json is still here and still supported; it is now an
# opt-in promote step (`--profile-manifest profiles/attract_tier2.json`), which
# is what a tier-2 burn-down run wants. Passing it emits ~278 AOT variants that
# a player's tree does not have, so do not ship or benchmark against a tree
# built with it without saying so.
if [ -n "${SNESRECOMP_ANALYSIS_BACKEND:-}" ]; then
  GEN_ARGS+=(--analysis-backend "$SNESRECOMP_ANALYSIS_BACKEND")
fi
if [ "$CFG_ROOTS" -eq 1 ]; then GEN_ARGS+=(--cfg-roots); fi
for _p in ${PROFILES+"${PROFILES[@]}"}; do
  if [ ! -f "$_p" ]; then
    echo "regen.sh: profile manifest not found: $_p" >&2; exit 2
  fi
  GEN_ARGS+=(--profile-manifest "$_p")
done
if [ "$VERIFY" -eq 1 ]; then GEN_ARGS+=("${VERIFY_ARGS[@]}"); fi

echo "== Generating src/gen =="
"$PYTHON" "$CLI" generate "${GEN_ARGS[@]}"

# --strict-idempotent: generate a SECOND time into a scratch tree and require
# byte-identical output. Generation is supposed to be a pure function of (ROM,
# cfg, profile); anything that leaks run order, a timestamp or a hash-map
# iteration into the emitted C shows up here and nowhere else.
#
# README.md, CMakeLists.txt and CLAUDE.md have all documented this flag for a
# long time while the script rejected it with "unknown flag" -- three dead
# build instructions. Implemented rather than removed, because the property it
# checks is worth having.
if [ "$STRICT_IDEMPOTENT" -eq 1 ]; then
  echo "== Verifying generation is idempotent =="
  SCRATCH="$(mktemp -d)"
  trap 'rm -rf "$SCRATCH"' EXIT
  SECOND_ARGS=()
  for a in "${GEN_ARGS[@]}"; do
    case "$a" in
      src/gen) SECOND_ARGS+=("$SCRATCH/gen") ;;
      recomp/funcs.h) SECOND_ARGS+=("$SCRATCH/funcs.h") ;;
      *) SECOND_ARGS+=("$a") ;;
    esac
  done
  "$PYTHON" "$CLI" generate "${SECOND_ARGS[@]}"
  # --exclude .gitkeep: src/gen carries a tracked placeholder so the directory
  # survives in git while its contents are ignored. The scratch tree has no
  # such file, and comparing it reports a difference that is not one.
  if diff -r --brief --exclude=.gitkeep src/gen "$SCRATCH/gen"; then
    echo "ok: two generations produced byte-identical output"
  else
    echo "regen.sh: generation is NOT idempotent (differences above)" >&2
    exit 1
  fi
fi

echo
echo "Done. Build with:"
echo "  cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j"
