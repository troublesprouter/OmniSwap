module omniswap::swap {
    use std::vector;

    use aptos_framework::coin::{Self, Coin};

    use liquidswap::router;
    use liquidswap::curves::{Stable, Uncorrelated};

    use omniswap::u256;
    use omniswap::serde;
    use omniswap::cross::{NormalizedSwapData, Self};

    // Swap call data delimiter, represent ","
    const DELIMITER: u8 = 44;

    /// Error Codes
    const EINVALID_LENGTH: u64 = 0x00;

    const EINVALID_SWAP_ROUTER: u64 = 0x01;

    const EINVALID_SWAP_TOKEN: u64 = 0x02;

    const EINVALID_SWAP_CURVE: u64 = 0x03;

    /// Ensuring the origin of tokens
    public fun right_type<X>(token: vector<u8>): bool {
        let data = vector::empty();
        serde::serialize_type<X>(&mut data);
        if (data == token) {
            true
        }else {
            false
        }
    }

    /// Coins are deducted directly from the user's account for swap.
    public fun swap_by_account<X, Y>(account: &signer, data: NormalizedSwapData): Coin<Y> {
        if (@liquidswap == serde::deserialize_address(&cross::swap_call_to(data))) {
            assert!(right_type<X>(cross::swap_sending_asset_id(data)), EINVALID_SWAP_TOKEN);
            assert!(right_type<Y>(cross::swap_receiving_asset_id(data)), EINVALID_SWAP_TOKEN);
            let coin_val = u256::as_u64(cross::swap_from_amount(data));
            let coin_x = coin::withdraw<X>(account, coin_val);

            let raw_call_data = cross::swap_call_data(data);
            let min_amount = 0;
            let (flag, index) = vector::index_of(&raw_call_data, &DELIMITER);
            let call_data;
            if (flag) {
                call_data = serde::vector_slice(&raw_call_data, 0, index);
                let len = vector::length(&raw_call_data);
                if (index + 1 < len) {
                    min_amount = ascii_to_u64(serde::vector_slice(&raw_call_data, index + 1, len));
                }
            }else {
                call_data = raw_call_data;
            };

            if (right_type<Stable>(call_data)) {
                router::swap_exact_coin_for_coin<X, Y, Stable>(
                    coin_x,
                    min_amount,
                )
            }else if (right_type<Uncorrelated>(call_data)) {
                router::swap_exact_coin_for_coin<X, Y, Uncorrelated>(
                    coin_x,
                    min_amount,
                )
            }else {
                abort EINVALID_SWAP_CURVE
            }
        }else {
            abort EINVALID_SWAP_ROUTER
        }
    }

    /// Coins need to be removed from the account first and then swap using the coins.
    public fun swap_by_coin<X, Y>(coin_x: Coin<X>, data: NormalizedSwapData): Coin<Y> {
        if (@liquidswap == serde::deserialize_address(&cross::swap_call_to(data))) {
            assert!(right_type<X>(cross::swap_sending_asset_id(data)), EINVALID_SWAP_TOKEN);
            assert!(right_type<Y>(cross::swap_receiving_asset_id(data)), EINVALID_SWAP_TOKEN);

            let raw_call_data = cross::swap_call_data(data);
            let min_amount = 0;
            let (flag, index) = vector::index_of(&raw_call_data, &DELIMITER);
            let call_data;
            if (flag) {
                call_data = serde::vector_slice(&raw_call_data, 0, index);
                let len = vector::length(&raw_call_data);
                if (index + 1 < len) {
                    min_amount = ascii_to_u64(serde::vector_slice(&raw_call_data, index + 1, len));
                }
            }else {
                call_data = raw_call_data;
            };

            if (right_type<Stable>(call_data)) {
                router::swap_exact_coin_for_coin<X, Y, Stable>(
                    coin_x,
                    min_amount,
                )
            }else if (right_type<Uncorrelated>(call_data)) {
                router::swap_exact_coin_for_coin<X, Y, Uncorrelated>(
                    coin_x,
                    min_amount,
                )
            }else {
                abort EINVALID_SWAP_CURVE
            }
        }else {
            abort EINVALID_SWAP_ROUTER
        }
    }

    public fun swap_two_by_account<X, Y>(account: &signer, swap_data: vector<NormalizedSwapData>): Coin<Y> {
        assert!(vector::length(&swap_data) == 1, EINVALID_LENGTH);
        swap_by_account<X, Y>(account, *vector::borrow(&mut swap_data, 0))
    }

    public fun swap_two_by_coin<X, Y>(coins: Coin<X>, swap_data: vector<NormalizedSwapData>): Coin<Y> {
        assert!(vector::length(&swap_data) == 1, EINVALID_LENGTH);
        swap_by_coin<X, Y>(coins, *vector::borrow(&mut swap_data, 0))
    }

    public fun swap_three_by_account<X, Y, Z>(account: &signer, swap_data: vector<NormalizedSwapData>): Coin<Z> {
        assert!(vector::length(&swap_data) == 2, EINVALID_LENGTH);
        let coin_y = swap_by_account<X, Y>(account, *vector::borrow(&mut swap_data, 0));
        swap_by_coin<Y, Z>(coin_y, *vector::borrow(&mut swap_data, 1))
    }

    public fun swap_three_by_coin<X, Y, Z>(coins: Coin<X>, swap_data: vector<NormalizedSwapData>): Coin<Z> {
        assert!(vector::length(&swap_data) == 2, EINVALID_LENGTH);
        let coin_y = swap_by_coin<X, Y>(coins, *vector::borrow(&mut swap_data, 0));
        swap_by_coin<Y, Z>(coin_y, *vector::borrow(&mut swap_data, 1))
    }

    public fun swap_four_by_account<X, Y, Z, M>(account: &signer, swap_data: vector<NormalizedSwapData>): Coin<M> {
        assert!(vector::length(&swap_data) == 3, EINVALID_LENGTH);
        let coin_y = swap_by_account<X, Y>(account, *vector::borrow(&mut swap_data, 0));
        let coin_z = swap_by_coin<Y, Z>(coin_y, *vector::borrow(&mut swap_data, 1));
        swap_by_coin<Z, M>(coin_z, *vector::borrow(&mut swap_data, 2))
    }

    public fun swap_four_by_coin<X, Y, Z, M>(coins: Coin<X>, swap_data: vector<NormalizedSwapData>): Coin<M> {
        assert!(vector::length(&swap_data) == 3, EINVALID_LENGTH);
        let coin_y = swap_by_coin<X, Y>(coins, *vector::borrow(&mut swap_data, 0));
        let coin_z = swap_by_coin<Y, Z>(coin_y, *vector::borrow(&mut swap_data, 1));
        swap_by_coin<Z, M>(coin_z, *vector::borrow(&mut swap_data, 2))
    }

    public fun ascii_to_u64(data: vector<u8>): u64 {
        let len = vector::length(&data);
        let amount = 0;
        let i = 0;
        while (i < len) {
            let m = *vector::borrow(&data, i);
            if ((m < 48) || (m > 57)) {
                return 0
            };
            let d = ((m - 48) as u64);
            amount = amount * 10 + d;
            i = i + 1;
        };
        amount
    }
}
