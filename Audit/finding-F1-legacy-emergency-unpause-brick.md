# F1 — Legacy `emergency_unpause` bypasses the v15 package-version cap: one role can permanently freeze every pool

| | |
|---|---|
| **Severity** | Critical impact / High likelihood-in-role — *permanent, protocol-wide loss of access to 100 % of pooled funds* |
| **Class** | Cross-version callable-surface (stale package still authoritative), missing input bound, unrecoverable state |
| **Component** | `cetus_clmm::config` — `emergency_pause`, `emergency_unpause`, `update_package_version`, `checked_package_version` |
| **Versions** | Live on `v14` (currently active, `VERSION = 14`); **not fixed** by `v15`, `VERSION = 15` |
| **Precondition** | ACL bit 5 (`ACL_EMERGENCY_UNPAUSE` in v15 / `ACL_EMERGENCY_PAUSE` in v14 and earlier) — a role that v15 explicitly treats as *harmless and unpause-only* |
| **PoC** | `packages/cetus_clmm/tests/emergency_unpause_legacy_bypass_tests.move` |
| **Status** | Open — the v15 mitigation is correct but unreachable-in-effect because it lives in only one of the callable packages |

---

## 1. Summary

`config::emergency_unpause(config, version, ctx)` writes an **attacker-chosen `u64` into `GlobalConfig.package_version`**, and `package_version` is the global kill switch: every money path in `pool.move` begins with `checked_package_version`, i.e. `assert!(VERSION >= config.package_version, EPackageVersionDeprecate)` (`config.move:524-526`, 27 call sites in `pool.move`).

v15 hardened this function in PR #6 (`optimize emergency unpause version validation`) by adding an upper bound:

```move
// config.move:554-573 (v15)
assert!(version >= before_version && version <= package_version(), EInvalidPackageVersion);
config.package_version = version;
```

`package_version()` returns the **calling package's** `VERSION` constant (`config.move:587-589`), so the bound is `version <= 15` — correct for v15.

**The bound does not exist anywhere on-chain except inside the v15 package.** Sui packages are immutable and old versions stay callable, and `emergency_pause` / `emergency_unpause` are deliberately *not* version-gated (they must work while the protocol is paused). The v14 package — and every older one — therefore remains a permanently available entry point into the same `GlobalConfig` with the weaker rule:

```move
// config.move:539-554 (v14, branch `version-14`)
public fun emergency_unpause(config: &mut GlobalConfig, version: u64, ctx: &TxContext) {
    check_emergency_pause_role(config, tx_context::sender(ctx));   // ACL bit 5
    assert!(dynamic_field::exists_with_type<..>(EMERGENCY_PAUSE_BEFORE_VERSION), EProtocolNotEmergencyPause);
    let before_version = dynamic_field::remove<..>(EMERGENCY_PAUSE_BEFORE_VERSION);
    assert!(version >= before_version, EInvalidPackageVersion);    // <-- no upper bound
    config.package_version = version;                             // <-- unbounded write
}
```

So the vulnerable primitive that PR #6 was written to remove is **still live**, just in the older module.

## 2. Attack

`bit5` = holder of ACL bit 5 (in v15 this is the *unpause-only* key, kept at bit 5 by design: “*Keep the legacy role at bit 5 so existing multisig unpause permissions remain valid*”, `config.move:54`).

Single transaction, three commands:

1. `v14::config::emergency_pause(&mut GlobalConfig, &ctx)` — v14 checks **bit 5** (v15 would have required the new bit 6). Sets `package_version = 2^63`, records `before_version`.
2. `v14::config::emergency_unpause(&mut GlobalConfig, 0x7FFFFFFFFFFFFFFF, &ctx)` — only `version >= before_version` is checked. Sets `package_version = 2^63 - 1`.
3. Done. Every CLMM pool is now permanently frozen.

Variants:

* If the protocol is already paused for a genuine emergency (the exact scenario the emergency mechanism exists for), step 1 is skipped and **the unpause-only key alone completes the attack**.
* `u64::MAX` works equally well; `2^63 - 1` is the *minimum* value that is irrecoverable and it does **not** trip the `EMERGENCY_PAUSE_VERSION` sentinel, so the config does not even look paused.
* Because step 1 uses the v14 module, the v15 role split is void even without the brick: the “unpause-only” key can still pause, so the property “*the emergency pause role can pause the protocol without being able to unpause it*” (`config.move:21-22`) does not hold on-chain.

## 3. Why the state is unrecoverable

Let `v = 2^63 - 1`. Every write to `package_version` is monotone or bounded below by `before_version`:

| Route | Assertion | Result at `v` |
|---|---|---|
| `update_package_version` (`config.move:575-585`) | `version > old && version < 2^63` | needs `v < version < 2^63` — **no u64 exists** |
| `emergency_pause` (`config.move:540-552`) | none (bit 6 only) | sets `2^63`, records `before = v` |
| `emergency_unpause` v15 | `version >= before_version && version <= 15` | requires `version >= v` **and** `<= 15` — **empty set** |
| `emergency_unpause` v14 | `version >= before_version` | can only set `>= v` — still frozen |
| any `pool::*` money path | `VERSION >= config.package_version` | `15 >= 2^63-1` false — **aborts `EPackageVersionDeprecate`** |
| a future package (e.g. `VERSION = 16`) | same check | also false — **also dead** |

There is no `set_package_version` that can lower the value, and the new package cannot bypass the check without deleting `checked_package_version` from all 27 money paths. The only theoretical escape is shipping a package that deliberately ignores the version gate — i.e. abandoning the upgrade-safety mechanism that the gate exists to provide.

## 4. Impact

* `add_liquidity` / `add_liquidity_fix_coin` / `repay_add_liquidity`, `remove_liquidity`, `close_position`, `collect_fee`, `collect_reward`, `flash_swap`, `flash_loan`, `collect_protocol_fee*`, `update_emission`, `init_position_snapshot` — all 27 gated entry points abort.
* Every LP position in every pool is permanently unwithdrawable, and the protocol can never be upgraded back into service. Total value locked is frozen, not stolen — but permanently.
* It also destroys the recovery mechanism: after a real incident, the pause/unpause ceremony (the one added *because of* May 2025) can be turned into the incident.

This is the same failure class as the BlueMove cross-version reserve desync (July 2026): *two callable versions of the same protocol, where the newer version's invariant is enforced only in the newer code.* Cetus is structurally exposed to it because Sui never retires old packages and because the emergency functions are intentionally un-gated.

## 5. Why the v15 fix is insufficient (three separate reasons)

1. **Wrong scope.** The cap is compiled into v15 only. The un-capped body remains callable in v14 and every earlier package, forever.
2. **Wrong dimension.** The cap bounds the version but not *who may write it*: v15 still lets the unpause key pick any value in `[before_version, 15]` — including `15` while the deployed code is older, or `14` to re-activate a retired package's `checked_package_version` semantics.
3. **Role split not enforceable.** Bit 5 keeps pause power through legacy packages, so v15's separation of pause (bit 6) from unpause (bit 5) — the actual security property PR #6 was introduced for — is not a property of the deployed system.

## 6. Reproduction

```bash
cd packages/cetus_clmm
sui move test emergency_unpause_legacy_bypass
```

The suite asserts: v15 rejects the write (`EInvalidPackageVersion`); the legacy-equivalent write makes `remove_liquidity` abort with `EPackageVersionDeprecate`; and neither the `AdminCap` path nor the pause/unpause path can restore service. (The v15 toolchain is not installed in this workspace, so the tests are written to the package's existing idioms — `phase1_liquidity_receipt_tests.move`, `phase2_recovery_tests.move` — but were not executed here.)

## 7. Remediation

On-chain (cannot be done by patching v15):

1. **Revoke bit 5 from every address that is not intended to hold full pause power**, then re-grant it only to the dedicated unpause multisig. Until that is done, treat bit 5 as a full-power admin key, not an unpause-only role — and document that the v15 pause/unpause split does not hold.
2. Ship a **recovery hatch in a new package that does not call `checked_package_version`**: an `AdminCap`-gated (ideally timelocked) `restore_package_version(config, version)` that may *lower* `package_version` below `2^63` but only when `config.package_version >= 2^63 - 1`. Without it, any poisoning — malicious or accidental — is terminal.
3. Make the recovery independent of the emergency path: `update_package_version` should accept any value `< EMERGENCY_PAUSE_VERSION` (it currently requires monotonic growth, which is what turns a bad write into a permanent one).

In code (v16+):

4. Bound the write by the *deployed* maximum, not by the caller's constant: compare against a value stored in `GlobalConfig` at upgrade time, and require `version <= max_supported_version` where `max_supported_version` is advanced only by `update_package_version`.
5. Add an event-and-monitor canary on `SetPackageVersion` / `emergency_unpause` for `version >= 2^63 - 1`; alerting on that single condition closes the window to one transaction.
6. Any future hardening of `emergency_*` must be understood as *advisory only*: the deployed system is the union of all callable packages. Harden by making the new package tolerate the old packages' behaviour (e.g. reject/repair out-of-range values on read), not by assuming the old code disappears.

## 8. Secondary observations (reviewed, lower severity)

* **`pool.move:1375,1404`** — `//check_pool_manager_role(...)` is commented out in `initialize_rewarder` and `update_emission`; the only guard left is `check_rewarder_manager_role`. The pool manager's veto over installing/accelerating rewards on a pool is gone. A rewarder manager can therefore create a rewarder on any pool and set an emission schedule; the reward budget still comes from the shared `RewarderGlobalVault`, so this is an ACL-reduction finding (privileged), not an unprivileged drain.
* **`pool.move:1350-1361`** — `collect_protocol_fee_with_cap` authorises against `object::id_address(cap)` rather than `tx_context::sender`. This is **not** a bypass (the cap's own address must still be granted the claim role via `set_roles`, and `mint_protocol_fee_collect_cap` is `AdminCap`-gated at `pool.move:514-521`), but it means (a) revocation must enumerate cap object addresses, not operators, and (b) transferring the cap transfers collection rights with no ACL change.
* **`pool.move:865-903`** — `close_position` omits the `assert_no_pending_add_liquidity` that `remove_liquidity` performs (`pool.move:769`). It cannot be monetised today (`position::close_position` requires an empty position, and the pending counter is per-pool and only ever non-zero inside a transaction that must consume the receipt), but the invariant “no liquidity operation while an add is unpaid” is inconsistently enforced.
