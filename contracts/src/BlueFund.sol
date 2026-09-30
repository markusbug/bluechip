// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";

/// @title Bluechip Index ($BLUE)
/// @notice An ERC-20 backed in kind by a basket of tokens (tokenized stocks).
///         Mint by depositing the basket pro rata, redeem to get it back. Mint and redeem never read
///         an oracle: every amount is a ratio of `holdings[token]` to `totalSupply()`.
///         The basket's mix is kept on its index by the `rebalancer`, the only address that can trade
///         holdings (`swapHoldings`). Replacing it takes `REBALANCER_DELAY`, so holders can redeem
///         first; the owner can switch it off at once.
/// @dev    Holdings are tracked internally, so tokens sent to the contract directly never change
///         mint or redeem amounts. The constructor never calls the constituent tokens (some are
///         chain-native precompiles that a local fork cannot execute).
contract BlueFund is ERC20Permit, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @notice Hard cap on the mint fee: 1%.
    uint256 public constant MAX_FEE_BPS = 100;
    /// @notice Shares minted to `DEAD` at seeding so supply (and every holding) can never reach zero.
    uint256 public constant DEAD_SHARES = 1e15;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_CONSTITUENTS = 32;
    /// @notice Wait between proposing a new rebalancer and it taking over.
    uint256 public constant REBALANCER_DELAY = 7 days;

    /// @notice An EIP-2612 permit for one constituent. `deadline == 0` means "no permit, use the
    ///         existing allowance".
    struct Permit {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    address[] private _tokens;
    /// @dev Token base units per 1e18 shares, used only for the seeding mint.
    uint256[] private _seedUnits;

    /// @notice Amount of each constituent owned by the fund (excludes anything sent in directly).
    mapping(address token => uint256) public holdings;
    mapping(address token => bool) public isConstituent;

    uint256 public mintFeeBps;
    /// @notice Maximum total supply. Zero pauses minting; redeeming can never be paused.
    uint256 public supplyCap;
    /// @notice Receives the mint fee, as freshly minted shares (the $CHIP burner).
    address public feeRecipient;
    bool public seeded;

    /// @notice The only address that may trade holdings. Zero disables rebalancing.
    address public rebalancer;
    address public pendingRebalancer;
    /// @notice When `pendingRebalancer` can be accepted. Zero means nothing is pending.
    uint256 public pendingRebalancerEta;

    event Seeded(address indexed by, uint256 shares, uint256[] deposited);
    event Minted(
        address indexed by, address indexed to, uint256 shares, uint256 feeShares, uint256[] deposited
    );
    event Redeemed(address indexed by, address indexed to, uint256 shares, uint256[] paidOut);
    event Forfeited(address indexed by, address indexed token);
    event MintFeeSet(uint256 bps);
    event SupplyCapSet(uint256 cap);
    event FeeRecipientSet(address recipient);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event RebalancerProposed(address indexed rebalancer, uint256 eta);
    event RebalancerCancelled(address indexed rebalancer);
    event RebalancerSet(address indexed rebalancer);
    event Rebalanced(address indexed sell, uint256 amountIn, address indexed buy, uint256 amountOut);

    error BadBasket();
    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh();
    error AlreadySeeded();
    error NotSeeded();
    error CapExceeded();
    error TransferMismatch(address token);
    error NotConstituent(address token);
    error LengthMismatch();
    error NotRebalancer();
    error SameToken();
    error ExceedsHoldings();
    error Slippage(uint256 out, uint256 minOut);
    error NothingPending();
    error TooEarly(uint256 eta);

    constructor(
        string memory name_,
        string memory symbol_,
        address[] memory tokens_,
        uint256[] memory seedUnits_,
        address owner_,
        address feeRecipient_,
        uint256 mintFeeBps_,
        uint256 supplyCap_,
        address rebalancer_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(owner_) {
        uint256 n = tokens_.length;
        if (n == 0 || n > MAX_CONSTITUENTS || seedUnits_.length != n) revert BadBasket();
        for (uint256 i; i < n; ++i) {
            address t = tokens_[i];
            if (t == address(0) || t == address(this) || isConstituent[t] || seedUnits_[i] == 0) {
                revert BadBasket();
            }
            isConstituent[t] = true;
        }
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (mintFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();

        _tokens = tokens_;
        _seedUnits = seedUnits_;
        feeRecipient = feeRecipient_;
        mintFeeBps = mintFeeBps_;
        supplyCap = supplyCap_;
        rebalancer = rebalancer_;
        emit RebalancerSet(rebalancer_);
    }

    // ---------------------------------------------------------------- mint / redeem

    /// @notice First mint, at the fixed seed ratio. `DEAD_SHARES` of it go to `DEAD` forever.
    function seed(uint256 shares) external onlyOwner nonReentrant returns (uint256[] memory deposited) {
        if (seeded) revert AlreadySeeded();
        if (shares <= DEAD_SHARES) revert ZeroAmount();
        if (shares > supplyCap) revert CapExceeded();
        seeded = true;

        uint256 n = _tokens.length;
        deposited = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            deposited[i] = Math.mulDiv(_seedUnits[i], shares, 1e18, Math.Rounding.Ceil);
            _pull(_tokens[i], deposited[i]);
        }
        _mint(DEAD, DEAD_SHARES);
        _mint(msg.sender, shares - DEAD_SHARES);
        emit Seeded(msg.sender, shares, deposited);
    }

    /// @notice Deposit the basket for `shares` and receive `shares` minus the mint fee.
    /// @dev    Each deposit rounds up, so the holdings-per-share ratio can only grow.
    function mint(uint256 shares, address to) external nonReentrant returns (uint256[] memory deposited) {
        return _mintShares(shares, to);
    }

    /// @notice `mint` in one transaction for wallets that can't batch approvals: `permits[i]` is an
    ///         EIP-2612 signature for `constituents()[i]`. A failed permit is ignored (it may have been
    ///         front-run); the pull still needs the allowance to be there.
    function mintWithPermits(uint256 shares, address to, Permit[] calldata permits)
        external
        nonReentrant
        returns (uint256[] memory deposited)
    {
        uint256 n = _tokens.length;
        if (permits.length != n) revert LengthMismatch();
        for (uint256 i; i < n; ++i) {
            Permit calldata p = permits[i];
            if (p.deadline == 0) continue;
            try IERC20Permit(_tokens[i]).permit(msg.sender, address(this), p.value, p.deadline, p.v, p.r, p.s)
            {} catch {}
        }
        return _mintShares(shares, to);
    }

    function _mintShares(uint256 shares, address to) private returns (uint256[] memory deposited) {
        if (!seeded) revert NotSeeded();
        if (shares == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 supply = totalSupply();
        if (supply + shares > supplyCap) revert CapExceeded();

        uint256 n = _tokens.length;
        deposited = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address t = _tokens[i];
            deposited[i] = Math.mulDiv(holdings[t], shares, supply, Math.Rounding.Ceil);
            _pull(t, deposited[i]);
        }

        uint256 fee = shares * mintFeeBps / BPS;
        _mint(to, shares - fee);
        if (fee != 0) _mint(feeRecipient, fee);
        emit Minted(msg.sender, to, shares, fee, deposited);
    }

    /// @notice Burn `shares` and receive the pro-rata share of every holding. Free, never paused.
    function redeem(uint256 shares, address to) external nonReentrant returns (uint256[] memory paidOut) {
        return _redeem(shares, to, new address[](0));
    }

    /// @notice Emergency exit: like `redeem`, but forfeits the tokens in `skip` (e.g. a constituent
    ///         whose transfers are frozen). The forfeited part stays in the fund for everyone else.
    function redeemExcept(uint256 shares, address to, address[] calldata skip)
        external
        nonReentrant
        returns (uint256[] memory paidOut)
    {
        for (uint256 j; j < skip.length; ++j) {
            if (!isConstituent[skip[j]]) revert NotConstituent(skip[j]);
        }
        return _redeem(shares, to, skip);
    }

    function _redeem(uint256 shares, address to, address[] memory skip)
        private
        returns (uint256[] memory paidOut)
    {
        if (shares == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 supply = totalSupply();
        _burn(msg.sender, shares);

        uint256 n = _tokens.length;
        paidOut = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address t = _tokens[i];
            if (_contains(skip, t)) {
                emit Forfeited(msg.sender, t);
                continue;
            }
            uint256 amount = Math.mulDiv(holdings[t], shares, supply);
            paidOut[i] = amount;
            if (amount != 0) {
                holdings[t] -= amount;
                IERC20(t).safeTransfer(to, amount);
            }
        }
        emit Redeemed(msg.sender, to, shares, paidOut);
    }

    // ---------------------------------------------------------------- rebalancing

    /// @notice Trade `amountIn` of `sell` for at least `minOut` of `buy` through `swapper`.
    ///         Only the rebalancer can call this; it decides what to trade and how much it must get.
    /// @dev    The swapper gets exactly `amountIn` (no allowance), and `buy` is credited by what
    ///         actually arrived. A holding can shrink but never reach zero.
    function swapHoldings(address sell, uint256 amountIn, address buy, uint256 minOut, address swapper)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (msg.sender != rebalancer) revert NotRebalancer();
        if (!isConstituent[sell]) revert NotConstituent(sell);
        if (!isConstituent[buy]) revert NotConstituent(buy);
        if (sell == buy) revert SameToken();
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn >= holdings[sell]) revert ExceedsHoldings();

        holdings[sell] -= amountIn;
        uint256 before = IERC20(buy).balanceOf(address(this));
        IERC20(sell).safeTransfer(swapper, amountIn);
        ISwapper(swapper).swap(sell, buy, amountIn, address(this));
        amountOut = IERC20(buy).balanceOf(address(this)) - before;
        if (amountOut < minOut) revert Slippage(amountOut, minOut);
        holdings[buy] += amountOut;
        emit Rebalanced(sell, amountIn, buy, amountOut);
    }

    function _pull(address token, uint256 amount) private {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - before != amount) revert TransferMismatch(token);
        holdings[token] += amount;
    }

    function _contains(address[] memory list, address item) private pure returns (bool) {
        for (uint256 j; j < list.length; ++j) {
            if (list[j] == item) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- views

    function constituents() external view returns (address[] memory) {
        return _tokens;
    }

    function seedUnits() external view returns (uint256[] memory) {
        return _seedUnits;
    }

    /// @notice Tokens a mint of `shares` pulls. Before seeding this is the seed ratio.
    function previewMint(uint256 shares)
        public
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = _tokens;
        amounts = new uint256[](tokens.length);
        uint256 supply = totalSupply();
        for (uint256 i; i < tokens.length; ++i) {
            amounts[i] = supply == 0
                ? Math.mulDiv(_seedUnits[i], shares, 1e18, Math.Rounding.Ceil)
                : Math.mulDiv(holdings[tokens[i]], shares, supply, Math.Rounding.Ceil);
        }
    }

    /// @notice Tokens a redeem of `shares` pays out.
    function previewRedeem(uint256 shares)
        public
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        tokens = _tokens;
        amounts = new uint256[](tokens.length);
        uint256 supply = totalSupply();
        if (supply == 0) return (tokens, amounts);
        for (uint256 i; i < tokens.length; ++i) {
            amounts[i] = Math.mulDiv(holdings[tokens[i]], shares, supply);
        }
    }

    /// @notice Holdings behind one whole share (1e18), rounded down. For display.
    function unitsPerShare() external view returns (address[] memory tokens, uint256[] memory units) {
        return previewRedeem(1e18);
    }

    /// @notice Shares credited to the minter and to the fee recipient for a mint of `shares`.
    function previewMintFee(uint256 shares) external view returns (uint256 toMinter, uint256 fee) {
        fee = shares * mintFeeBps / BPS;
        toMinter = shares - fee;
    }

    // ---------------------------------------------------------------- admin (cannot move holdings out)

    function setMintFee(uint256 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh();
        mintFeeBps = bps;
        emit MintFeeSet(bps);
    }

    function setSupplyCap(uint256 cap) external onlyOwner {
        supplyCap = cap;
        emit SupplyCapSet(cap);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @notice Start the `REBALANCER_DELAY` countdown to hand trading to `newRebalancer`
    ///         (zero proposes switching rebalancing off, which `disableRebalancer` does at once).
    function proposeRebalancer(address newRebalancer) external onlyOwner {
        pendingRebalancer = newRebalancer;
        pendingRebalancerEta = block.timestamp + REBALANCER_DELAY;
        emit RebalancerProposed(newRebalancer, pendingRebalancerEta);
    }

    function cancelRebalancer() external onlyOwner {
        if (pendingRebalancerEta == 0) revert NothingPending();
        emit RebalancerCancelled(pendingRebalancer);
        delete pendingRebalancer;
        delete pendingRebalancerEta;
    }

    /// @notice Anyone can make a proposed rebalancer take over once its delay has passed.
    function acceptRebalancer() external {
        uint256 eta = pendingRebalancerEta;
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TooEarly(eta);
        rebalancer = pendingRebalancer;
        delete pendingRebalancer;
        delete pendingRebalancerEta;
        emit RebalancerSet(rebalancer);
    }

    /// @notice Emergency brake: stop all trading of holdings immediately. Mint and redeem keep working.
    function disableRebalancer() external onlyOwner {
        rebalancer = address(0);
        emit RebalancerSet(address(0));
    }

    /// @notice Recover tokens sent here by mistake. Only the excess over `holdings` can leave,
    ///         so the basket backing $BLUE is untouchable.
    function sweep(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this)) - holdings[token];
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }
}
