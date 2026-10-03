// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IHauntedRules {
    function corruption() external view returns (uint256);
    function outcomeForRoll(uint256 roll, uint256 level) external pure returns (uint8);
    function feeForOutcome(uint8 outcome, uint256 level) external pure returns (uint24);
}

/// @notice Escrows exact-input game trades before a fixed future beacon draw is available.
/// @dev Testnet beacon randomness, not a VRF. Anyone must capture PREVRANDAO in the exact target
/// block. Missing capture refunds the input less the 5% maximum fee, credited to LPs. A captured
/// ticket cannot be cancelled or rerolled; anyone may execute it. Slippage failures still pay the
/// drawn fee, preventing a min-output limit from selecting only free trades. Withdrawals are pull-based.
/// Settlement refuses to run inside another PoolManager unlock: the manager would reject the
/// game's own unlock as AlreadyUnlocked, and a caller must not be able to turn that into a paid failure.
contract HauntedGame is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    struct Ticket {
        address player;
        uint128 amountIn;
        uint128 minOut;
        uint256 targetBlock;
        uint256 level;
        bool zeroForOne;
        bool resolved;
    }

    uint256 public constant DRAW_DELAY = 128;
    uint256 public constant FEE_DENOMINATOR = 1_000_000;
    uint24 public constant MAX_FEE = 50_000;
    /// @notice Fixed swap budget prevents an executor from forcing a paid failure with too little gas.
    uint256 public constant SWAP_GAS_LIMIT = 2_000_000;
    IPoolManager public immutable manager;
    IERC20 public immutable token;
    address public immutable hook;
    uint256 public ticketCount;
    mapping(uint256 => Ticket) public tickets;
    mapping(uint256 => bytes32) public entropy;
    mapping(uint256 => bool) public captured;
    mapping(uint256 => bool) public requested;
    mapping(address => mapping(address => uint256)) public credit;
    uint256 public lpFees0;
    uint256 public lpFees1;

    bool public executing;
    uint256 public activeRoll;
    uint256 public activeLevel;

    event Committed(
        uint256 indexed ticketId,
        address indexed player,
        uint256 targetBlock,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minOut,
        uint256 level
    );
    event EntropyCaptured(uint256 indexed targetBlock, bytes32 value);
    event Settled(uint256 indexed ticketId, uint256 roll, uint24 fee, uint256 amountOut);
    event TradeFailed(uint256 indexed ticketId, bytes reason);
    event Expired(uint256 indexed ticketId, uint256 feeAmount);
    event FeesDonated(uint256 amount0, uint256 amount1);
    event Withdrawn(address indexed player, address indexed currency, address indexed to, uint256 amount);

    error InvalidInput();
    error NotReady();
    error AlreadyResolved();
    error EntropyUnavailable();
    error UnauthorizedCallback();
    error SlippageOrPartialFill();
    error TransferFailed();
    error InsufficientExecutionGas();
    error ManagerUnlocked();

    /// @dev A call nested inside someone else's PoolManager unlock cannot open the game's own unlock,
    /// so every swap or donation attempt would revert AlreadyUnlocked and be recorded as a failure.
    /// Refuse before any state change; the ticket stays open and can be settled by a top-level call.
    modifier notInsideUnlock() {
        if (manager.isUnlocked()) revert ManagerUnlocked();
        _;
    }

    constructor(address manager_, address token_, address hook_) {
        if (manager_ == address(0) || token_ == address(0) || hook_ == address(0)) revert InvalidInput();
        manager = IPoolManager(manager_);
        token = IERC20(token_);
        hook = hook_;
    }

    receive() external payable {
        if (msg.sender != address(manager)) revert UnauthorizedCallback();
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook)
        );
    }

    /// @notice Commit input, minimum output and beneficiary now. No cancellation or editing is possible.
    function commit(bool zeroForOne, uint128 amountIn, uint128 minOut)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        if (amountIn == 0 || amountIn > uint128(type(int128).max) || minOut == 0) revert InvalidInput();
        if (manager.getLiquidity(poolKey().toId()) == 0) revert InvalidInput();
        if (zeroForOne) {
            if (msg.value != amountIn) revert InvalidInput();
        } else {
            if (msg.value != 0) revert InvalidInput();
            token.safeTransferFrom(msg.sender, address(this), amountIn);
        }
        uint256 target = block.number + DRAW_DELAY;
        uint256 level = IHauntedRules(hook).corruption();
        id = ++ticketCount;
        tickets[id] = Ticket(msg.sender, amountIn, minOut, target, level, zeroForOne, false);
        requested[target] = true;
        emit Committed(id, msg.sender, target, zeroForOne, amountIn, minOut, level);
    }

    /// @notice A keeper or any participant calls in the exact requested block. First capture is final.
    function captureEntropy() external {
        uint256 target = block.number;
        if (!requested[target] || captured[target]) revert InvalidInput();
        captured[target] = true;
        entropy[target] = bytes32(block.prevrandao);
        emit EntropyCaptured(target, entropy[target]);
    }

    function draw(uint256 id) public view returns (uint256 roll, uint24 fee) {
        Ticket memory t = tickets[id];
        if (t.player == address(0)) revert InvalidInput();
        if (block.number <= t.targetBlock) revert NotReady();
        if (!captured[t.targetBlock]) revert EntropyUnavailable();
        roll = uint256(keccak256(abi.encode(entropy[t.targetBlock], block.chainid, address(this), id))) % 1000;
        IHauntedRules rules = IHauntedRules(hook);
        fee = rules.feeForOutcome(rules.outcomeForRoll(roll, t.level), t.level);
    }

    /// @notice Anyone can resolve a committed ticket; outputs/refunds always belong to its player.
    /// @dev Reverts ManagerUnlocked when called from inside a PoolManager unlock (see notInsideUnlock).
    function execute(uint256 id) external nonReentrant notInsideUnlock {
        Ticket storage t = tickets[id];
        if (t.resolved) revert AlreadyResolved();
        (uint256 roll, uint24 fee) = draw(id);
        t.resolved = true;
        uint256 net = _charge(t, fee);
        _flushFees();
        activeRoll = roll;
        activeLevel = t.level;
        executing = true;
        // Include the EIP-150 forwarding margin and enough gas for credit accounting after the call.
        // If the executor underfunds this transaction, all state and prior fee donations roll back.
        if (gasleft() < SWAP_GAS_LIMIT + SWAP_GAS_LIMIT / 63 + 200_000) revert InsufficientExecutionGas();
        uint256 amountOut = 0;
        try manager.unlock{gas: SWAP_GAS_LIMIT}(abi.encode(false, id, net, uint256(0))) returns (bytes memory result) {
            amountOut = abi.decode(result, (uint256));
            credit[t.player][t.zeroForOne ? address(token) : address(0)] += amountOut;
        } catch (bytes memory reason) {
            // The fee was charged before the isolated swap subcall. Failed trades cannot avoid it.
            credit[t.player][t.zeroForOne ? address(0) : address(token)] += net;
            emit TradeFailed(id, reason);
        }
        executing = false;
        emit Settled(id, roll, fee, amountOut);
    }

    /// @notice If nobody captured the exact beacon block, refund less the maximum LP fee; never reroll.
    function expire(uint256 id) external nonReentrant notInsideUnlock {
        Ticket storage t = tickets[id];
        if (t.player == address(0)) revert InvalidInput();
        if (t.resolved) revert AlreadyResolved();
        if (block.number <= t.targetBlock || captured[t.targetBlock]) revert NotReady();
        t.resolved = true;
        uint256 net = _charge(t, MAX_FEE);
        credit[t.player][t.zeroForOne ? address(0) : address(token)] += net;
        _flushFees();
        emit Expired(id, t.amountIn - net);
    }

    function withdraw(address currency, address payable to) external nonReentrant {
        if (to == address(0) || to == address(this)) revert InvalidInput();
        uint256 amount = credit[msg.sender][currency];
        if (amount == 0) revert InvalidInput();
        credit[msg.sender][currency] = 0;
        if (currency == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(currency).safeTransfer(to, amount);
        }
        emit Withdrawn(msg.sender, currency, to, amount);
    }

    /// @notice Retry LP fee delivery when liquidity returns. Reserved fees have no other withdrawal path.
    function flushFees() external nonReentrant notInsideUnlock {
        _flushFees();
    }

    function _charge(Ticket storage t, uint24 fee) private returns (uint256 net) {
        uint256 amount = (uint256(t.amountIn) * fee + FEE_DENOMINATOR - 1) / FEE_DENOMINATOR;
        if (t.zeroForOne) lpFees0 += amount;
        else lpFees1 += amount;
        return t.amountIn - amount;
    }

    function _flushFees() private {
        uint256 amount0 = lpFees0;
        uint256 amount1 = lpFees1;
        if (amount0 == 0 && amount1 == 0) return;
        lpFees0 = 0;
        lpFees1 = 0;
        try manager.unlock(abi.encode(true, uint256(0), amount0, amount1)) {
            emit FeesDonated(amount0, amount1);
        } catch {
            lpFees0 = amount0;
            lpFees1 = amount1;
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert UnauthorizedCallback();
        (bool donating, uint256 id, uint256 amount0, uint256 amount1) =
            abi.decode(data, (bool, uint256, uint256, uint256));
        PoolKey memory key = poolKey();
        if (donating) {
            manager.donate(key, amount0, amount1, "");
            _pay(true, amount0);
            _pay(false, amount1);
            return "";
        }
        if (!executing) revert UnauthorizedCallback();
        Ticket memory t = tickets[id];
        BalanceDelta delta = manager.swap(
            key,
            SwapParams(
                t.zeroForOne, -int256(amount0), t.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            abi.encode(t.player)
        );
        int128 input = t.zeroForOne ? delta.amount0() : delta.amount1();
        int128 output = t.zeroForOne ? delta.amount1() : delta.amount0();
        if (int256(input) != -int256(amount0) || output <= 0 || uint128(output) < t.minOut) {
            revert SlippageOrPartialFill();
        }
        _pay(t.zeroForOne, amount0);
        manager.take(t.zeroForOne ? key.currency1 : key.currency0, address(this), uint128(output));
        return abi.encode(uint256(uint128(output)));
    }

    function _pay(bool nativeCurrency, uint256 amount) private {
        if (amount == 0) return;
        if (nativeCurrency) {
            manager.settle{value: amount}();
        } else {
            manager.sync(Currency.wrap(address(token)));
            token.safeTransfer(address(manager), amount);
            manager.settle();
        }
    }
}
