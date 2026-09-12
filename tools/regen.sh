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
#   --cfg-roots   seed analysis from every func declaration in recomp/*.cfg
#   -h|--help     this message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

VERIFY=1
CFG_ROOTS=0
STRICT_IDEMPOTENT=0
ROM="${SNESRECOMP_ROM:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --rom) ROM=$2; shift 2 ;;
    --no-verify) VERIFY=0; shift ;;
    --cfg-roots) CFG_ROOTS=1; shift ;;
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
# (snesrecomp_cli generate); these two are declarations about Super Metroid,
# which is why they are the only lines here that are not the wizard's:
#   --source-root src            host roots live in src/, so root discovery
#                                has to look there as well as in recomp/*.cfg
#   --profile-manifest ...       tier-2 coverage that seeds optional AOT roots.
#                                Dropping it changes which functions are AOT
#                                vs LLE, i.e. changes the generated C.
# Both are plain snesrecomp_cli options (see `generate --help`), so nothing
# here forks the engine's pipeline.
#
# These were deleted by the 2026-09-11 template sync, which replaced this
# script wholesale with the scaffold's copy. That left profiles/attract_tier2.json
# orphaned and silently changed the AOT/LLE split on the next regen, which is
# exactly what the comment above warns about. Restored, and the divergence
# from the stock template is now deliberate and written down.
PROFILE="profiles/attract_tier2.json"
if [ ! -f "$PROFILE" ]; then
  echo "regen.sh: missing $PROFILE — it selects this title's observed AOT work" >&2
  exit 1
fi
GEN_ARGS+=(--source-root src --profile-manifest "$PROFILE")
if [ -n "${SNESRECOMP_ANALYSIS_BACKEND:-}" ]; then
  GEN_ARGS+=(--analysis-backend "$SNESRECOMP_ANALYSIS_BACKEND")
fi
if [ "$CFG_ROOTS" -eq 1 ]; then GEN_ARGS+=(--cfg-roots); fi
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
  if diff -r --brief src/gen "$SCRATCH/gen"; then
    echo "ok: two generations produced byte-identical output"
  else
    echo "regen.sh: generation is NOT idempotent (differences above)" >&2
    exit 1
  fi
fi

echo
echo "Done. Build with:"
echo "  cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j"
