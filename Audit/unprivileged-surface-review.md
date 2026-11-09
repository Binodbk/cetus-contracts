# Unprivileged (bounty-eligible) surface — systematic review

| | |
|---|---|
| **Scope** | everything in `packages/cetus_clmm/sources` reachable by a signer with **no ACL role** (v15, commit `b7c3a5a`) |
| **Question** | is there a *previously unknown*, unprivileged path to fund loss / permanent DoS — i.e. something a bounty programme would actually pay for? |
| **Result** | **no High/Critical unprivileged finding.** The money core is equivalent to Uniswap v3 and the v15 additions are sound. Four Low/Info items remain, none bounty-eligible. |
| **Companion** | `Audit/finding-F1-legacy-emergency-unpause-brick.md` (High impact, but **privileged** — see §6) |

---

## 1. Entry-point matrix (what an anonymous signer can actually call)

| Function(s) | Value moved | Guard | Verdict |
|---|---|---|---|
| `open_position` | none | version + `is_allow_add_liquidity` | creates an owned NFT + a dynamic-field `PositionInfo`; no capital required, no pool-size impact (§3-I11) |
| `add_liquidity`, `add_liquidity_fix_coin`, `repay_add_liquidity` | in | version, pending counter | receipt has no abilities → repayment is atomic |
| `remove_liquidity`, `remove_liquidity_with_slippage`, `close_position` | out | version, `is_allow_remove_liquidity`, pending counter (except `close_position`) | amounts recomputed from the current price; rounding floors |
| `collect_fee`, `collect_reward` | out | version, pause flags, **`&Position` (ownership)** | third parties cannot harvest or destroy another position's accrual |
| `calculate_and_update_fee` / `_reward(s)` / `_points` | none (accrual only) | version, pause flags | take a bare `position_id` → **anyone** can poke any position, but the mutators are non-destructive (`update_fee`/`update_rewards`/`update_points`, never `*_and_reset_*`) |
| `flash_swap`, `flash_swap_with_partner`, `repay_flash_swap*` | both | version, `is_allow_swap`, price-limit bound | receipt bound to `pool_id`; exact repay |
| `flash_loan`, `flash_loan_with_partner`, `repay_flash_loan*` | one side | version, `is_allow_flash_loan` | exact `amount + ceil(fee)` repayment |
| `rewarder::deposit_reward` | in | none (permissionless donation) | no payout path from it without LP position |
| `factory::create_pool_v3` | none | `PoolCreationCap`, fee-tier, price bounds | pool is the creator's own |

## 2. Invariants verified (the audit value of this pass)

* **I1 — fee-growth-inside is exactly Uniswap v3.** `tick::get_fee_in_range` (`tick.move:330-393`) uses `below = cur < lower ? global - outside : outside`, `above = cur < upper ? outside : global - outside`, `inside = global - below - above`, with `below = global` / `above = 0` when the tick does not exist. Byte-for-byte the reference semantics, including the `-1` crossing convention used by `swap_in_pool`.
* **I2 — settle-before-mutate.** `position::increase_liquidity` / `decrease_liquidity` (`position.move:318-375`) run `update_fee_internal`, `update_points_internal`, `update_rewards_internal` **before** touching `position_info.liquidity`. A brand-new position therefore initialises `growth_inside` to the current value and is credited `mul_shr(0, growth) = 0` — no retroactive fee/reward harvest. Reversing those two lines would have been a critical theft primitive; it is not reversed.
* **I3 — tick first-initialisation** uses `cur < tick ? 0 : global` (`tick.move:610-650`), i.e. Uniswap's `tick <= tickCurrent`, and `liquidity_gross == 0` returns early so the caller drops the node — tick set cannot be grown for free.
* **I4 — sentinel tick.** a2b crossings set `current_tick_index = next - 1`, b2a set `next` (`pool.move:2905-2925`). I re-derived the branch agreement between the *price*-based selector in `get_liquidity_by_amount` and the *tick*-based selector in `get_amount_by_liquidity` for the crossing state (`price == p_T`, `tick == T-1`): both select the same branch for every position boundary (`lower == T`, `upper == T`, `upper == T-1`). No mispriced deposit/withdrawal.
* **I5 — receipt linearity.** `AddLiquidityReceipt` (`pool.move:220`), `FlashSwapReceipt` (`:208`), `FlashLoanReceipt` (`:233`) declare **no abilities**. They cannot be dropped, stored or transferred, so the paired repay call is mandatory in the same transaction.
* **I6 — pending is a counter, not a flag.** `mark_pending_add_liquidity` increments, `clear` decrements and removes at zero, `remove_liquidity` asserts absence (`pool.move:3069-3092`, `:769`). N outstanding adds require N repays; a second add cannot be used to unblock a removal.
* **I7 — the deferred-payment window is economically neutral.** During `add_liquidity → repay_add_liquidity` the pool's `liquidity` is inflated without capital, which dilutes fee growth and suppresses slippage. This is *not* exploitable: the position's claim absorbs exactly the swap flows. Worked example (price 1, symmetric range, `L = 10^8`, swap `Δa = 10^5`): the attacker repays `(a0, b0)`, receives `b0` back as swap output and `b0 − 10^5` on removal, and pays `a0 + 10^5` for `a0 + 10^5` received — net A = 0, net B = 0, minus fees they largely pay to themselves. Being your own counterparty yields nothing, and the payer is the same account that is owed.
* **I8 — price limits are bounded and one-sided.** `flash_swap_internal` (`pool.move:2690-2700`): a2b requires `current > limit >= min_sqrt_price()`, b2a requires `current < limit <= max_sqrt_price()`. `current_sqrt_price` can never leave `[min, max]`, so no out-of-range tick computation.
* **I9 — flash-loan fee** is `ceil(amount * fee_rate / 1e6)` and repayment is asserted equal to `amount + fee_amount` from the receipt (`pool.move:1548-1628`, `2767-2800`); the receipt carries `fee_amount`, so it cannot be recomputed by the borrower.
* **I10 — rounding favours the pool everywhere.** deposit amounts `ceil`, withdrawal amounts `floor`, liquidity from amount `floor`, fee growth `floor`, protocol fee `ceil`, flash-loan fee `ceil`. Round trips always lose, never gain.
* **I11 — no shared-object growth DoS.** I specifically tested the hypothesis "`open_position` spam inflates the `Pool` past Sui's per-object limit". Two facts kill it: (a) `move_stl::linked_table` stores every node via `sui::dynamic_field::add(&mut table.id, k, node)` (`CetusProtocol/move-stl@mainnet-v1.3.0`, `sources/linked_table.move:7-45`), so `PositionInfo` and tick nodes are **child objects**, not bytes in `Pool`; (b) the limit itself is real (`max_move_object_size: Some(250 * 1024)` in `sui-protocol-config`, enforced as `ExecutionErrorKind::MoveObjectTooBig` in `sui-types/src/object.rs:118-137`) but unreachable from positions/ticks. Position spam costs the attacker gas and buys nothing.
* **I12 — rewarder.** `settle` early-returns on `liquidity == 0` (`rewarder.move:246-251`, no division by zero), `update_emission` requires a one-day top-up in the vault before *raising* a rate (`:293-322`), and there is no `remove_rewarder`, so position `rewards` vectors cannot be re-indexed against the wrong rewarder.
* **I13 — ID-based updaters are non-destructive.** `calculate_and_update_fee/_reward/_points` take a bare `position_id` and are therefore callable by anyone, but they call `update_fee` / `update_rewards` / `update_points` (`position.move:414-460, 777-880`), never the `*_and_reset_*` variants — a hostile poke can only accelerate an accrual, never zero it.
* **I14 — every payout needs the NFT.** `collect_fee`, `collect_reward`, `remove_liquidity*`, `close_position` take `&Position` / `Position`, so Sui's input-ownership rule restricts them to the owner. Nothing pays out on a bare `ID`.

## 3. Residual findings (all Low / Informational, none bounty-eligible)

| # | Finding | Why it is not payable |
|---|---|---|
| N1 | `collect_fee(..., recalculate = false)` and `collect_reward(..., false)` zero the stored `fee_owned` / `amount_owned` without first folding in the growth accrued since the last settle (`pool.move:908-957`, `:960-1010`; `position.move` `reset_fee` / `reset_rewarder`). A caller who passes `false` while the position has unsettled accrual permanently forfeits it — the tokens stay in the pool as surplus. | Requires the position NFT; the only victim is the caller (or whoever the caller's integration is). Documented footgun, not an exploit. |
| N2 | `close_position` does not call `assert_no_pending_add_liquidity`, while `remove_liquidity` does (`pool.move:865-903` vs `:769`). The "no liquidity op while an add is unpaid" invariant is enforced inconsistently. | Cannot be monetised: `position::close_position` requires an empty position, and the counter is only non-zero inside a transaction that must consume the receipt. |
| N3 | `position::is_empty` checks liquidity, both `fee_owned` fields and every `rewards[i].amount_owned`, but **not `points_owned`** (`position.move:734-750`). Closing a position silently destroys unclaimed points. | Self-inflicted (needs the NFT); points have no on-chain value. |
| N4 | `remove_liquidity_with_slippage` (`pool.move:844-863`) has zero test coverage; it is a thin wrapper that settles after paying out and asserts `>= min_amount`. Reading shows it is safe (assert reverts the whole tx). | No defect — listed only so the coverage gap is visible. |

## 4. Where a bounty-eligible bug could still be hiding

Ranked by expected value, given that the source-level money core came back clean:

1. **Deployed bytecode ≠ this source.** The repo mirrors published modules (`Audit/sync-provenance.json`, `Publication` ids in `Published.toml`). The May 2025 exploit also lived in a *dependency*, not in the audited file set. Diff the on-chain modules against this tree before concluding anything about the deployed system.
2. **Older published packages.** Every historical package stays callable (§F1). v1…v13 are not published in this repository; the ACL bit each one uses for `emergency_*` is the one open question that would convert F1 from "privileged DoS" to "any operational key can freeze the protocol".
3. **Dependency revisions.** `IntegerMate` / `MoveSTL` at `mainnet-v1.3.0`; the vendored copies were verified numerically here (tick tables, `mul_div`, `mul_shr`), but the *published* revisions must be matched byte-for-byte — `integer-mate` is where the last $223M lived.
4. **SDK / router / frontend.** `collect_fee(recalculate = false)` (N1) becomes a real user-facing loss the moment an integration gets the ordering wrong. Out of scope for this package, in scope for most programmes.
5. **Sui-framework behaviours** (Clock skew, dynamic-field enumeration, object ownership edge cases) — no defect found, but they are the layer where source review stops.

## 5. Eligibility summary

| Finding | Severity | Unprivileged | Previously known | Bounty-eligible |
|---|---|---|---|---|
| F1 legacy `emergency_unpause` freeze | High/Critical impact | **no** (ACL bit 5) | no | unlikely as Critical; defensible as a broken shipped control |
| N1 `recalculate = false` forfeits accrual | Low | no (needs NFT) | documented in-source | no |
| N2 `close_position` pending check | Info | yes, but no effect | no | no |
| N3 `points_owned` not in `is_empty` | Info | no (needs NFT) | no | no |
| N4 slippage wrapper coverage | Info | — | — | no |

Nothing in this pass meets the usual bar ("unprivileged third party, no preconditions, direct loss of funds"). That is the finding: on the evidence available in this repository, the v15 unprivileged surface is clean, and the strongest remaining lead for a payable bug is not in `pool.move` at all — it is the deployed-bytecode and legacy-package comparison of §4.1-4.2.
