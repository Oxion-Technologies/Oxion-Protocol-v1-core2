// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Pool} from "../../src/libraries/Pool.sol";
import {PoolManager} from "../../src/PoolManager.sol";
import {Position} from "../../src/libraries/Position.sol";
import {TickMath} from "../../src/libraries/TickMath.sol";
import {TickBitmap} from "../../src/libraries/TickBitmap.sol";
import {Tick} from "../../src/libraries/Tick.sol";
import {SafeCast} from "../../src/libraries/SafeCast.sol";
import {LiquidityAmounts} from "../helpers/LiquidityAmounts.sol";
import {FeeLibrary} from "../../src/libraries/FeeLibrary.sol";
import {FullMath} from "../../src/libraries/FullMath.sol";

contract PoolTest is Test {
    using Pool for Pool.State;

    Pool.State state;

    function testPoolInitialize(uint160 sqrtPriceX96, uint16 protocolFee, uint24 swapFee) public {
        protocolFee = uint16(bound(protocolFee, 0, 2 ** 16 - 1));
        swapFee = uint24(bound(swapFee, 0, 999999));

        if (sqrtPriceX96 < TickMath.MIN_SQRT_RATIO || sqrtPriceX96 >= TickMath.MAX_SQRT_RATIO) {
            vm.expectRevert(TickMath.InvalidSqrtRatio.selector);
            state.initialize(sqrtPriceX96, protocolFee, swapFee);
        } else {
            state.initialize(sqrtPriceX96, protocolFee, swapFee);
            assertEq(state.slot0.sqrtPriceX96, sqrtPriceX96);
            assertEq(state.slot0.protocolFee, protocolFee);
            assertEq(state.slot0.tick, TickMath.getTickAtSqrtRatio(sqrtPriceX96));
            assertLt(state.slot0.tick, TickMath.MAX_TICK);
            assertGt(state.slot0.tick, TickMath.MIN_TICK - 1);
            assertEq(state.slot0.swapFee, swapFee);
        }
    }

    function testModifyPosition(uint160 sqrtPriceX96, Pool.ModifyLiquidityParams memory params, uint24 swapFee)
        public
    {
        // Assumptions tested in PoolManager.t.sol
        params.tickSpacing = int24(bound(params.tickSpacing, 1, 32767));
        swapFee = uint24(bound(swapFee, 0, FeeLibrary.ONE_HUNDRED_PERCENT_FEE - 1));

        testPoolInitialize(sqrtPriceX96, 0, swapFee);

        if (params.tickLower >= params.tickUpper) {
            vm.expectRevert(abi.encodeWithSelector(Tick.TicksMisordered.selector, params.tickLower, params.tickUpper));
        } else if (params.tickLower < TickMath.MIN_TICK) {
            vm.expectRevert(abi.encodeWithSelector(Tick.TickLowerOutOfBounds.selector, params.tickLower));
        } else if (params.tickUpper > TickMath.MAX_TICK) {
            vm.expectRevert(abi.encodeWithSelector(Tick.TickUpperOutOfBounds.selector, params.tickUpper));
        } else if (params.liquidityDelta < 0) {
            vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        } else if (params.liquidityDelta == 0) {
            vm.expectRevert(Position.CannotUpdateEmptyPosition.selector);
        } else if (params.liquidityDelta > int128(Tick.tickSpacingToMaxLiquidityPerTick(params.tickSpacing))) {
            vm.expectRevert(abi.encodeWithSelector(Tick.TickLiquidityOverflow.selector, params.tickLower));
        } else if (params.tickLower % params.tickSpacing != 0) {
            vm.expectRevert(
                abi.encodeWithSelector(TickBitmap.TickMisaligned.selector, params.tickLower, params.tickSpacing)
            );
        } else if (params.tickUpper % params.tickSpacing != 0) {
            vm.expectRevert(
                abi.encodeWithSelector(TickBitmap.TickMisaligned.selector, params.tickUpper, params.tickSpacing)
            );
        } else {
            // We need the assumptions above to calculate this
            uint256 maxInt128InTypeU256 = uint256(uint128(type(int128).max));
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(params.tickLower),
                TickMath.getSqrtRatioAtTick(params.tickUpper),
                uint128(params.liquidityDelta)
            );

            if ((amount0 > maxInt128InTypeU256) || (amount1 > maxInt128InTypeU256)) {
                vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflow.selector));
            }
        }

        params.owner = address(this);
        state.modifyLiquidity(params);
    }

    function testSwap(
        uint160 sqrtPriceX96,
        Pool.ModifyLiquidityParams memory modifyLiquidityParams,
        Pool.SwapParams memory swapParams,
        uint24 swapFee
    ) public {
        testModifyPosition(sqrtPriceX96, modifyLiquidityParams, swapFee);

        swapParams.tickSpacing = modifyLiquidityParams.tickSpacing;
        Pool.Slot0 memory slot0 = state.slot0;

        if (swapParams.amountSpecified == 0) {
            vm.expectRevert(Pool.SwapAmountCannotBeZero.selector);
        } else if (swapParams.zeroForOne) {
            if (swapParams.sqrtPriceLimitX96 >= slot0.sqrtPriceX96) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        Pool.InvalidSqrtPriceLimit.selector, slot0.sqrtPriceX96, swapParams.sqrtPriceLimitX96
                    )
                );
            } else if (swapParams.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_RATIO) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        Pool.InvalidSqrtPriceLimit.selector, slot0.sqrtPriceX96, swapParams.sqrtPriceLimitX96
                    )
                );
            }
        } else if (!swapParams.zeroForOne) {
            if (swapParams.sqrtPriceLimitX96 <= slot0.sqrtPriceX96) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        Pool.InvalidSqrtPriceLimit.selector, slot0.sqrtPriceX96, swapParams.sqrtPriceLimitX96
                    )
                );
            } else if (swapParams.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_RATIO) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        Pool.InvalidSqrtPriceLimit.selector, slot0.sqrtPriceX96, swapParams.sqrtPriceLimitX96
                    )
                );
            }
        }

        state.swap(swapParams);

        if (
            modifyLiquidityParams.liquidityDelta == 0
                || (swapParams.zeroForOne && slot0.tick < modifyLiquidityParams.tickLower)
                || (!swapParams.zeroForOne && slot0.tick >= modifyLiquidityParams.tickUpper)
        ) {
            // no liquidity, hence all the way to the limit
            if (swapParams.zeroForOne) {
                assertEq(state.slot0.sqrtPriceX96, swapParams.sqrtPriceLimitX96);
            } else {
                assertEq(state.slot0.sqrtPriceX96, swapParams.sqrtPriceLimitX96);
            }
        } else {
            if (swapParams.zeroForOne) {
                assertGe(state.slot0.sqrtPriceX96, swapParams.sqrtPriceLimitX96);
            } else {
                assertLe(state.slot0.sqrtPriceX96, swapParams.sqrtPriceLimitX96);
            }
        }
    }

    function testDonate(
        uint160 sqrtPriceX96,
        Pool.ModifyLiquidityParams memory params,
        uint24 swapFee,
        uint256 amount0,
        uint256 amount1
    ) public {
        testModifyPosition(sqrtPriceX96, params, swapFee);

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        if (!(params.liquidityDelta > 0 && tick >= params.tickLower && tick < params.tickUpper)) {
            vm.expectRevert(Pool.NoLiquidityToReceiveFees.selector);
        }
        /// @dev due to "delta = toBalanceDelta(amount0.toInt128(), amount1.toInt128());"
        /// amount0 and amount1 must be less than or equal to type(int128).max
        else if (amount0 > uint128(type(int128).max) || amount1 > uint128(type(int128).max)) {
            vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        }

        uint256 feeGrowthGlobal0BeforeDonate = state.feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1BeforeDonate = state.feeGrowthGlobal1X128;
        state.donate(amount0, amount1);
        uint256 feeGrowthGlobal0AfterDonate = state.feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1AftereDonate = state.feeGrowthGlobal1X128;

        if (state.liquidity != 0) {
            assertEq(
                feeGrowthGlobal0AfterDonate - feeGrowthGlobal0BeforeDonate,
                FullMath.mulDiv(amount0, FullMath.Q128, state.liquidity)
            );
            assertEq(
                feeGrowthGlobal1AftereDonate - feeGrowthGlobal1BeforeDonate,
                FullMath.mulDiv(amount1, FullMath.Q128, state.liquidity)
            );
        }
    }
}
