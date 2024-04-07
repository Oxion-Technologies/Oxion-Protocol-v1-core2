// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {stdError} from "forge-std/StdError.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {Test} from "forge-std/Test.sol";
import {Position} from "../../src/libraries/Position.sol";
import {Pool} from "../../src/libraries/Pool.sol";
import {FullMath} from "../../src/libraries/FullMath.sol";

contract PositionTest is Test, GasSnapshot {
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    Pool.State public pool;

    function test_get_emptyPosition() public {
        Position.Info memory info = pool.positions.get(address(this), 1, 2);
        assertEq(info.liquidity, 0);
        assertEq(info.feeGrowthInside0LastX128, 0);
        assertEq(info.feeGrowthInside1LastX128, 0);
    }

    function test_set_updateEmptyPositionFuzz(
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) public {
        Position.Info storage info = pool.positions.get(address(this), 1, 2);

        if (liquidityDelta == 0) {
            vm.expectRevert(Position.CannotUpdateEmptyPosition.selector);
        } else if (liquidityDelta < 0) {
            vm.expectRevert(stdError.arithmeticError);
        }
        (uint256 feesOwed0, uint256 feesOwed1) = info.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        assertEq(feesOwed0, 0);
        assertEq(feesOwed1, 0);
        assertEq(info.liquidity, uint128(liquidityDelta));
        assertEq(info.feeGrowthInside0LastX128, feeGrowthInside0X128);
        assertEq(info.feeGrowthInside1LastX128, feeGrowthInside1X128);
    }

    function test_set_updateNonEmptyPosition() public {
        Position.Info storage info = pool.positions.get(address(this), 1, 2);

        // init
        {
            (uint256 feesOwed0, uint256 feesOwed1) = info.update(3, 5 * FullMath.Q128, 6 * FullMath.Q128);
            assertEq(feesOwed0, 0);
            assertEq(feesOwed1, 0);
        }

        // add
        {
            snapStart("PositionTest#Position_update_add");
            (uint256 feesOwed0, uint256 feesOwed1) = info.update(0, 10 * FullMath.Q128, 12 * FullMath.Q128);
            snapEnd();
            assertEq(feesOwed0, (10 - 5) * 3);
            assertEq(feesOwed1, (12 - 6) * 3);

            assertEq(info.liquidity, 3);
            assertEq(info.feeGrowthInside0LastX128, 10 * FullMath.Q128);
            assertEq(info.feeGrowthInside1LastX128, 12 * FullMath.Q128);
        }

        // remove
        {
            (uint256 feesOwed0, uint256 feesOwed1) = info.update(-1, 10 * FullMath.Q128, 12 * FullMath.Q128);
            assertEq(feesOwed0, 0);
            assertEq(feesOwed1, 0);

            assertEq(info.liquidity, 2);
            assertEq(info.feeGrowthInside0LastX128, 10 * FullMath.Q128);
            assertEq(info.feeGrowthInside1LastX128, 12 * FullMath.Q128);
        }

        // remove all
        {
            snapStart("PositionTest#Position_update_remove");
            (uint256 feesOwed0, uint256 feesOwed1) = info.update(-2, 20 * FullMath.Q128, 15 * FullMath.Q128);
            snapEnd();
            assertEq(feesOwed0, (20 - 10) * 2);
            assertEq(feesOwed1, (15 - 12) * 2);

            assertEq(info.liquidity, 0);
            assertEq(info.feeGrowthInside0LastX128, 20 * FullMath.Q128);
            assertEq(info.feeGrowthInside1LastX128, 15 * FullMath.Q128);
        }
    }
}
