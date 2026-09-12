/* Codegen identity for Super Metroid.
 *
 * These digests are the single source of truth for "is this the right ROM".
 * tools/regen.sh and the CI workflow both read them from here via
 * rom_identity.txt, so there is one place to change when a revision changes.
 */

#include "codegen_setup.h"

const GameCodegenIdentity kGameCodegenIdentity = {
    .display_name   = "Super Metroid",
    .rom_file       = "Super Metroid (Japan, USA) (En,Ja).sfc",
    .expected_crc32 = "d63ed5f8",
    .expected_sha256= "12b77c4bc9c1832cee8881244659065ee1d84c70c3d29e6eaf92e6798cc2ca72",
    .mapping        = "lorom",
    .region         = "JPN",
    .cfg_dir        = "recomp",
    .out_dir        = "src/gen",
    .funcs_h        = "recomp/funcs.h",
};
