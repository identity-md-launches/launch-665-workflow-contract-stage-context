// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {JackpotVault} from "../../src/JackpotVault.sol";
import {CharityVault} from "../../src/CharityVault.sol";
import {HauntedHook} from "../../src/HauntedHook.sol";
import {HookSaltMiner} from "../../src/HookSaltMiner.sol";

/// @notice Shared setup: a local PoolManager, the token, both vaults, the hook at a mined CREATE2
/// address, the two v4 test routers, and one haunted ETH/VOID pool with full-range liquidity.
abstract contract HauntedFixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant FULL_RANGE_LOWER = -887_220;
    int24 internal constant FULL_RANGE_UPPER = 887_220;
    uint128 internal constant LIQUIDITY = 1e21;
    uint256 internal constant JACKPOT_BPS = 300;
    uint256 internal constant JACKPOT_COOLDOWN = 10 minutes;
    uint256 internal constant CHARITY_BPS = 100;
    uint256 internal constant CHARITY_COOLDOWN = 1 hours;

    IPoolManager internal manager;
    LaunchToken internal token;
    JackpotVault internal jackpot;
    CharityVault internal charity;
    HauntedHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    PoolKey internal key;
    PoolId internal poolId;

    address internal owner = makeAddr("owner");
    address internal charityWallet = makeAddr("charityWallet");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    receive() external payable {}

    function setUp() public virtual {
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new LaunchToken();
        jackpot = new JackpotVault(owner, JACKPOT_BPS, JACKPOT_COOLDOWN);
        charity = new CharityVault(owner, charityWallet, CHARITY_BPS, CHARITY_COOLDOWN);
        hook = deployHook(address(manager), address(token), owner, address(jackpot), address(charity));

        vm.startPrank(owner);
        jackpot.grantRole(jackpot.PAYER_ROLE(), address(hook));
        charity.grantRole(charity.SIGNALER_ROLE(), address(hook));
        vm.stopPrank();

        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        key = hauntedKey(TICK_SPACING);
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        vm.deal(address(this), 1e25);
        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: 2000 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: FULL_RANGE_LOWER,
                tickUpper: FULL_RANGE_UPPER,
                liquidityDelta: int256(uint256(LIQUIDITY)),
                salt: 0
            }),
            ""
        );
    }

    /// @dev Mines a salt from this contract's address and deploys the hook with CREATE2.
    function deployHook(address poolManager_, address token_, address owner_, address jackpot_, address charity_)
        internal
        returns (HauntedHook deployed)
    {
        bytes memory initCode = abi.encodePacked(
            type(HauntedHook).creationCode, abi.encode(poolManager_, token_, owner_, jackpot_, charity_)
        );
        (bytes32 salt, address predicted) =
            HookSaltMiner.mine(address(this), keccak256(initCode), HookSaltMiner.HAUNTED_HOOK_FLAGS, 0, 1_000_000);
        deployed = new HauntedHook{salt: salt}(poolManager_, token_, owner_, jackpot_, charity_);
        require(address(deployed) == predicted, "fixture: hook address mismatch");
    }

    function hauntedKey(int24 tickSpacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
    }

    function swapParams(bool zeroForOne, int256 amountSpecified) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    /// @dev Swaps through the test router from this contract; ETH legs are paid from msg.value and refunded.
    function swap(bool zeroForOne, int256 amountSpecified, bytes memory hookData) internal returns (BalanceDelta) {
        return swapAs(address(this), key, zeroForOne, amountSpecified, hookData);
    }

    function swapAs(address who, PoolKey memory k, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta delta)
    {
        uint256 value = zeroForOne ? 100 ether : 0;
        if (who != address(this)) vm.prank(who);
        delta = swapRouter.swap{value: value}(
            k,
            swapParams(zeroForOne, amountSpecified),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @dev Exact output of an exact-input single-step swap at the current pool state for a given fee.
    function expectedOut(bool zeroForOne, uint256 amountIn, uint24 fee) internal view returns (uint256 out) {
        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        uint128 liquidity = manager.getLiquidity(poolId);
        uint160 target = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (,, out,) = SwapMath.computeSwapStep(sqrtP, target, liquidity, -int256(amountIn), fee);
    }

    function lpFee() internal view returns (uint24 fee) {
        (,,, fee) = manager.getSlot0(poolId);
    }

    /// @dev Replicates the hook's draw and sets block.prevrandao so the next swap from `sender`
    /// with these parameters resolves (unforced) to `target`.
    function steer(
        HauntedHook.Outcome target,
        address sender,
        address beneficiary,
        int256 amountSpecified,
        bool zeroForOne
    ) internal {
        bytes32 current = hook.seed();
        uint256 count = hook.swapCount();
        uint256 corruption = hook.corruption();
        for (uint256 i = 1; i < 200_000; ++i) {
            bytes32 next = keccak256(abi.encode(current, i, sender, beneficiary, amountSpecified, zeroForOne, count));
            if (hook.outcomeForRoll(uint256(next) % hook.ROLL_RANGE(), corruption) == target) {
                vm.prevrandao(bytes32(i));
                return;
            }
        }
        revert("steer: no prevrandao found");
    }

    function abs1(BalanceDelta delta) internal pure returns (uint256) {
        int128 a = delta.amount1();
        return a < 0 ? uint256(uint128(-a)) : uint256(uint128(a));
    }

    function abs0(BalanceDelta delta) internal pure returns (uint256) {
        int128 a = delta.amount0();
        return a < 0 ? uint256(uint128(-a)) : uint256(uint128(a));
    }
}
