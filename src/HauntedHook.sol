// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {JackpotVault} from "./JackpotVault.sol";
import {CharityVault} from "./CharityVault.sol";
import {HookSaltMiner} from "./HookSaltMiner.sol";

/// @title HauntedHook
/// @notice Uniswap v4 hook of the Haunted Liquidity Pool. It haunts dynamic-fee ETH/VOID pools:
/// every swap is resolved into exactly one of eight outcomes, each with its own event.
///
/// | Outcome          | LP fee for the swap                      | Side effect                                  |
/// |------------------|------------------------------------------|----------------------------------------------|
/// | NormalTrade      | 0.30%                                    | corruption +1                                |
/// | FreeSwap         | 0%                                       | corruption +1                                |
/// | CorruptedFee     | 0.30% + 0.05% x corruption, max 5%       | corruption +5                                |
/// | VoidBurn         | 0.30%                                    | burns VOID from the hoard to the dead address |
/// | LoreSignal       | 0.30%                                    | unlocks the next lore fragment               |
/// | MiniJackpot      | 0.30%                                    | JackpotVault pays <= 3% of its reserve       |
/// | CharitySignal    | 0.30%                                    | CharityVault donates <= 1% of its reserve    |
/// | RealityCollapse  | 5%                                       | corruption resets to 0                       |
///
/// Hook callbacks: afterInitialize (admits the pool and sets the 0.30% opening fee), beforeSwap
/// (draws the outcome and overrides the fee), afterSwap (applies the side effects and emits).
///
/// @dev Randomness is NOT secure: the draw mixes a rolling seed, block.prevrandao, the swap
/// parameters and the swap index. A searcher can simulate it. Exposure is bounded by the vaults'
/// caps and cooldowns and by the burn caps; see the README. Vault calls are wrapped in try/catch so
/// a paused, empty or cooling-down vault never blocks a swap.
contract HauntedHook is IHooks, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using SafeERC20 for IERC20;

    enum Outcome {
        NormalTrade,
        FreeSwap,
        CorruptedFee,
        VoidBurn,
        LoreSignal,
        MiniJackpot,
        CharitySignal,
        RealityCollapse
    }

    struct Pending {
        bool active;
        bool forced;
        Outcome outcome;
        uint24 fee;
        address beneficiary;
        uint256 roll;
    }

    /// @notice Permission bits the hook address must carry: afterInitialize | beforeSwap | afterSwap = 0x10C0.
    uint160 public constant REQUIRED_FLAGS = HookSaltMiner.HAUNTED_HOOK_FLAGS;

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Fee of a normal trade: 0.30% (pips, 1e6 = 100%).
    uint24 public constant BASE_FEE = 3000;
    /// @notice Ceiling of the corrupted fee and the fee charged on a reality collapse: 5%.
    uint24 public constant MAX_FEE = 50_000;
    /// @notice Corrupted fee grows by 0.05% per corruption level.
    uint24 public constant CORRUPTION_FEE_STEP = 500;
    /// @notice Corruption level is bounded.
    uint256 public constant MAX_CORRUPTION = 100;
    /// @notice Corruption gained by an ordinary swap and by a corrupted-fee swap.
    uint256 public constant CORRUPTION_PER_SWAP = 1;
    uint256 public constant CORRUPTION_PER_CORRUPTED_SWAP = 5;
    /// @notice Hard cap of `burnBps`: 5% of the VOID moved by the swap.
    uint256 public constant MAX_BURN_BPS = 500;
    /// @notice Opening `burnBps`: 1% of the VOID moved by the swap.
    uint256 public constant DEFAULT_BURN_BPS = 100;
    /// @notice A single burn never exceeds 1% of the hoard.
    uint256 public constant MAX_BURN_SHARE_BPS = 100;
    /// @notice Number of lore fragments the game cycles through.
    uint256 public constant LORE_FRAGMENTS = 13;
    /// @notice Rolls are drawn in [0, ROLL_RANGE).
    uint256 public constant ROLL_RANGE = 1000;
    /// @notice Collapse band at corruption 0, in rolls out of 1000; it widens by 1 per 10 corruption.
    uint256 public constant COLLAPSE_BASE_BAND = 5;
    /// @notice Burned VOID goes here; the token has no burn function and total supply never changes.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    IERC20 public immutable voidToken;
    JackpotVault public immutable jackpotVault;
    CharityVault public immutable charityVault;

    /// @notice Pools admitted by afterInitialize (dynamic-fee ETH/VOID pools using this hook).
    mapping(PoolId => bool) public haunted;
    uint256 public hauntedPools;

    /// @notice Game state, shared by every haunted pool.
    uint256 public corruption;
    uint256 public swapCount;
    uint256 public collapseCount;
    uint256 public loreSignals;
    /// @notice Bit i set when lore fragment i has been unlocked at least once.
    uint256 public loreUnlockedMask;
    uint256 public totalBurned;
    uint256 public burnCount;
    uint256 public burnBps = DEFAULT_BURN_BPS;
    bytes32 public seed;

    /// @notice Sepolia test control: when active, every swap resolves to `forcedOutcome`.
    bool public forcedOutcomeActive;
    Outcome public forcedOutcome;

    Pending private _pending;

    event PoolHaunted(PoolId indexed poolId, address indexed initializer, uint160 sqrtPriceX96, int24 tick);
    event SwapResolved(
        PoolId indexed poolId,
        address indexed swapper,
        Outcome indexed outcome,
        uint24 fee,
        uint256 roll,
        bool forced,
        uint256 corruption,
        uint256 swapIndex
    );
    event NormalTrade(PoolId indexed poolId, address indexed swapper, uint24 fee);
    event FreeSwap(PoolId indexed poolId, address indexed swapper);
    event CorruptedFee(PoolId indexed poolId, address indexed swapper, uint24 fee, uint256 corruption);
    event VoidBurned(PoolId indexed poolId, address indexed swapper, uint256 amount, uint256 totalBurned);
    event BurnSkipped(PoolId indexed poolId, address indexed swapper, uint256 hoard);
    event LoreSignal(
        PoolId indexed poolId, address indexed swapper, uint256 indexed fragment, bytes32 sigil, uint256 unlockedMask
    );
    event MiniJackpot(PoolId indexed poolId, address indexed winner, uint256 amount);
    event JackpotSkipped(PoolId indexed poolId, address indexed winner, bytes reason);
    event CharitySignal(PoolId indexed poolId, address indexed swapper, address indexed charity, uint256 amount);
    event CharitySkipped(PoolId indexed poolId, address indexed swapper, bytes reason);
    event RealityCollapse(
        PoolId indexed poolId, address indexed swapper, uint256 previousCorruption, uint256 collapseCount
    );
    event OutcomeForced(Outcome outcome, bool active);
    event CorruptionForced(uint256 previousCorruption, uint256 newCorruption);
    event BurnBpsUpdated(uint256 previousBps, uint256 newBps);
    event HoardFunded(address indexed from, uint256 amount, uint256 hoard);

    error NotPoolManager();
    error HookNotImplemented();
    error HookAddressNotValid(address hook);
    error ZeroAddress();
    error PoolFeeNotDynamic();
    error UnsupportedPair();
    error PoolNotHaunted();
    error SwapAlreadyPending();
    error NoPendingSwap();
    error InvalidBurnBps(uint256 bps, uint256 max);
    error InvalidCorruption(uint256 corruption, uint256 max);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param poolManager_ The chain's Uniswap v4 PoolManager.
    /// @param voidToken_ The VOID launch token (currency1 of every haunted pool).
    /// @param initialOwner Holder of the admin test controls (the project owner, `$owner` in the manifest).
    /// @param jackpotVault_ JackpotVault whose PAYER_ROLE the owner grants to this hook.
    /// @param charityVault_ CharityVault whose SIGNALER_ROLE the owner grants to this hook.
    constructor(
        address poolManager_,
        address voidToken_,
        address initialOwner,
        address jackpotVault_,
        address charityVault_
    ) Ownable(initialOwner) {
        if (poolManager_ == address(0) || voidToken_ == address(0)) revert ZeroAddress();
        if (jackpotVault_ == address(0) || charityVault_ == address(0)) revert ZeroAddress();
        // Same check BaseHook performs: the address bits must match the declared permissions exactly,
        // otherwise the PoolManager would call callbacks this contract does not implement, or skip ours.
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != REQUIRED_FLAGS) revert HookAddressNotValid(address(this));
        poolManager = IPoolManager(poolManager_);
        voidToken = IERC20(voidToken_);
        jackpotVault = JackpotVault(payable(jackpotVault_));
        charityVault = CharityVault(payable(charityVault_));
        seed = keccak256(abi.encode("HauntedLiquidityPool", block.chainid, address(this)));
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------------

    /// @notice Declared permissions, matching REQUIRED_FLAGS.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert PoolFeeNotDynamic();
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != address(voidToken)) {
            revert UnsupportedPair();
        }
        PoolId id = key.toId();
        haunted[id] = true;
        ++hauntedPools;
        poolManager.updateDynamicLPFee(key, BASE_FEE);
        emit PoolHaunted(id, sender, sqrtPriceX96, tick);
        return IHooks.afterInitialize.selector;
    }

    /// @inheritdoc IHooks
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_pending.active) revert SwapAlreadyPending();
        if (!haunted[key.toId()]) revert PoolNotHaunted();

        address beneficiary = _beneficiary(sender, hookData);
        bytes32 next = keccak256(
            abi.encode(
                seed, block.prevrandao, sender, beneficiary, params.amountSpecified, params.zeroForOne, swapCount
            )
        );
        seed = next;
        uint256 roll = uint256(next) % ROLL_RANGE;
        bool forced = forcedOutcomeActive;
        Outcome outcome = forced ? forcedOutcome : outcomeForRoll(roll, corruption);
        uint24 fee = feeForOutcome(outcome, corruption);

        _pending =
            Pending({active: true, forced: forced, outcome: outcome, fee: fee, beneficiary: beneficiary, roll: roll});
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        Pending memory p = _pending;
        if (!p.active) revert NoPendingSwap();

        PoolId id = key.toId();
        uint256 swapIndex = ++swapCount;
        // currency1 is always VOID for a haunted pool; the delta sign only tells the direction.
        int128 amount1 = delta.amount1();
        uint256 voidMoved = amount1 < 0 ? uint256(uint128(-amount1)) : uint256(uint128(amount1));

        // The pending flag stays set while side effects run, so a payout recipient that re-enters
        // the PoolManager and swaps on a haunted pool is refused by beforeSwap.
        _applyOutcome(id, p, voidMoved);
        emit SwapResolved(id, p.beneficiary, p.outcome, p.fee, p.roll, p.forced, corruption, swapIndex);
        delete _pending;
        return (IHooks.afterSwap.selector, 0);
    }

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------------------------------
    // Hoard (VOID reserve the burn outcome draws from)
    // ---------------------------------------------------------------------------------------------

    /// @notice VOID held by the hook, available to burn. Anyone may also transfer VOID here directly.
    function hoard() public view returns (uint256) {
        return voidToken.balanceOf(address(this));
    }

    /// @notice Permissionless funding of the hoard (needs a prior VOID approval).
    function fundHoard(uint256 amount) external {
        voidToken.safeTransferFrom(msg.sender, address(this), amount);
        emit HoardFunded(msg.sender, amount, hoard());
    }

    // ---------------------------------------------------------------------------------------------
    // Admin test controls (owner only; intended for Sepolia)
    // ---------------------------------------------------------------------------------------------

    /// @notice Force every subsequent swap to resolve to `outcome` until cleared.
    function forceOutcome(Outcome outcome) external onlyOwner {
        forcedOutcomeActive = true;
        forcedOutcome = outcome;
        emit OutcomeForced(outcome, true);
    }

    /// @notice Return to random outcomes.
    function clearForcedOutcome() external onlyOwner {
        forcedOutcomeActive = false;
        emit OutcomeForced(forcedOutcome, false);
    }

    /// @notice Set the corruption level directly (0..100), e.g. to demonstrate the fee ceiling.
    function forceCorruption(uint256 newCorruption) external onlyOwner {
        if (newCorruption > MAX_CORRUPTION) revert InvalidCorruption(newCorruption, MAX_CORRUPTION);
        emit CorruptionForced(corruption, newCorruption);
        corruption = newCorruption;
    }

    /// @notice Set the burn share of swap volume, 0..500 bps (0 disables burns; they are then skipped).
    function setBurnBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_BURN_BPS) revert InvalidBurnBps(newBps, MAX_BURN_BPS);
        emit BurnBpsUpdated(burnBps, newBps);
        burnBps = newBps;
    }

    // ---------------------------------------------------------------------------------------------
    // Pure game rules (exposed for tests and the frontend)
    // ---------------------------------------------------------------------------------------------

    /// @notice Maps a roll in [0, 1000) to an outcome at a given corruption level.
    /// @dev Bands: collapse [0, 5 + corruption/10), normal up to 600, free up to 700, corrupted up to
    /// 800, burn up to 880, lore up to 940, jackpot up to 970, charity the rest.
    function outcomeForRoll(uint256 roll, uint256 corruptionLevel) public pure returns (Outcome) {
        if (roll < COLLAPSE_BASE_BAND + corruptionLevel / 10) return Outcome.RealityCollapse;
        if (roll < 600) return Outcome.NormalTrade;
        if (roll < 700) return Outcome.FreeSwap;
        if (roll < 800) return Outcome.CorruptedFee;
        if (roll < 880) return Outcome.VoidBurn;
        if (roll < 940) return Outcome.LoreSignal;
        if (roll < 970) return Outcome.MiniJackpot;
        return Outcome.CharitySignal;
    }

    /// @notice The LP fee (pips) charged for an outcome at a corruption level.
    function feeForOutcome(Outcome outcome, uint256 corruptionLevel) public pure returns (uint24) {
        if (outcome == Outcome.FreeSwap) return 0;
        if (outcome == Outcome.RealityCollapse) return MAX_FEE;
        if (outcome == Outcome.CorruptedFee) {
            uint256 fee = uint256(BASE_FEE) + corruptionLevel * CORRUPTION_FEE_STEP;
            return fee > MAX_FEE ? MAX_FEE : uint24(fee);
        }
        return BASE_FEE;
    }

    /// @notice The VOID a burn outcome would burn for `voidMoved` at the current hoard and burnBps.
    function burnAmountFor(uint256 voidMoved) public view returns (uint256) {
        uint256 amount = voidMoved * burnBps / BPS;
        uint256 cap = hoard() * MAX_BURN_SHARE_BPS / BPS;
        return amount > cap ? cap : amount;
    }

    /// @notice True between beforeSwap and afterSwap of a haunted swap.
    function swapPending() external view returns (bool) {
        return _pending.active;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev The swapper is whatever `hookData` names (abi-encoded address), else the router `sender`.
    function _beneficiary(address sender, bytes calldata hookData) private pure returns (address) {
        if (hookData.length == 32) {
            address named = abi.decode(hookData, (address));
            if (named != address(0)) return named;
        }
        return sender;
    }

    function _applyOutcome(PoolId id, Pending memory p, uint256 voidMoved) private {
        Outcome outcome = p.outcome;
        address swapper = p.beneficiary;

        if (outcome == Outcome.RealityCollapse) {
            uint256 previous = corruption;
            corruption = 0;
            uint256 count = ++collapseCount;
            emit RealityCollapse(id, swapper, previous, count);
            return;
        }

        // Every non-collapse outcome corrupts the pool a little; a corrupted fee corrupts it more.
        _corrupt(outcome == Outcome.CorruptedFee ? CORRUPTION_PER_CORRUPTED_SWAP : CORRUPTION_PER_SWAP);

        if (outcome == Outcome.NormalTrade) {
            emit NormalTrade(id, swapper, p.fee);
        } else if (outcome == Outcome.FreeSwap) {
            emit FreeSwap(id, swapper);
        } else if (outcome == Outcome.CorruptedFee) {
            emit CorruptedFee(id, swapper, p.fee, corruption);
        } else if (outcome == Outcome.VoidBurn) {
            uint256 amount = burnAmountFor(voidMoved);
            if (amount == 0) {
                emit BurnSkipped(id, swapper, hoard());
            } else {
                totalBurned += amount;
                ++burnCount;
                voidToken.safeTransfer(DEAD, amount);
                emit VoidBurned(id, swapper, amount, totalBurned);
            }
        } else if (outcome == Outcome.LoreSignal) {
            uint256 fragment = loreSignals % LORE_FRAGMENTS;
            ++loreSignals;
            loreUnlockedMask |= 1 << fragment;
            emit LoreSignal(id, swapper, fragment, keccak256(abi.encode("VOID_LORE", fragment)), loreUnlockedMask);
        } else if (outcome == Outcome.MiniJackpot) {
            try jackpotVault.payout(swapper) returns (uint256 amount) {
                emit MiniJackpot(id, swapper, amount);
            } catch (bytes memory reason) {
                emit JackpotSkipped(id, swapper, reason);
            }
        } else {
            try charityVault.donate() returns (uint256 amount) {
                emit CharitySignal(id, swapper, charityVault.charity(), amount);
            } catch (bytes memory reason) {
                emit CharitySkipped(id, swapper, reason);
            }
        }
    }

    function _corrupt(uint256 by) private {
        uint256 next = corruption + by;
        corruption = next > MAX_CORRUPTION ? MAX_CORRUPTION : next;
    }
}
