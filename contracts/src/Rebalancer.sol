// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BlueFund} from "./BlueFund.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

/// @title Bluechip rebalancer
/// @notice Keeps the fund on its index: float-adjusted market-cap weights, the S&P 500 method.
///         The index is each company's float shares (listed shares x investable weight factor)
///         together with the token `multiplier` (shares per token) they were counted at. Holding
///         tokens in proportion to floatShares / multiplier stays on target as prices move, so
///         trades are only needed after the index itself changes. Keeping the multiplier with the
///         share count means a stock split (which moves both) never looks like a change in size.
///
///         - The `updater` proposes new float shares; they apply after `INDEX_DELAY` (anyone
///           activates them), giving holders time to redeem if they disagree.
///         - Anyone can call `rebalance` to sell an overweight constituent for an underweight one.
///           Each trade is capped at `maxTradeBps` of NAV, separated by `cooldown`, only runs in
///           the US regular session on fresh Chainlink prices, and must return at least the oracle
///           value minus `maxSlippageBps`.
/// @dev    Never calls the constituent tokens (chain-native precompiles that a local fork cannot
///         execute). It reads the fund and the price feeds, which are ordinary contracts.
contract Rebalancer is Ownable2Step, ReentrancyGuard {
    uint256 public constant BPS = 10_000;
    uint256 public constant INDEX_DELAY = 7 days;
    uint256 public constant MAX_SLIPPAGE_BPS = 200;
    uint256 public constant MAX_TRADE_BPS = 1_000;
    uint256 public constant MIN_COOLDOWN = 5 minutes;
    uint256 public constant MAX_FEED_AGE = 1 days;
    /// @notice The US regular session in UTC, the part that is open under both EST and EDT.
    uint256 public constant SESSION_OPEN = 14 hours + 30 minutes;
    uint256 public constant SESSION_CLOSE = 20 hours;

    BlueFund public immutable fund;
    ISwapper public immutable swapper;

    address[] private _tokens;
    address[] private _feeds;
    /// @dev 10^decimals of each token.
    uint256[] private _tokenScale;
    /// @dev Multiplies a feed answer up to 18 decimals.
    uint256[] private _feedScale;

    uint256[] private _floatShares;
    /// @dev The token multiplier (WAD shares per token) each float share count was taken at.
    uint256[] private _multipliers;
    uint256[] private _pendingFloatShares;
    uint256[] private _pendingMultipliers;
    /// @notice When the pending index can be activated. Zero means nothing is pending.
    uint256 public pendingIndexEta;

    address public updater;
    uint256 public maxSlippageBps;
    uint256 public maxTradeBps;
    uint256 public minTradeBps;
    uint256 public cooldown;
    uint256 public maxFeedAge;
    uint256 public lastTradeAt;

    event IndexProposed(uint256[] floatShares, uint256[] multipliers, uint256 eta);
    event IndexCancelled();
    event IndexActivated(uint256[] floatShares, uint256[] multipliers);
    event UpdaterSet(address updater);
    event ParamsSet(
        uint256 maxSlippageBps, uint256 maxTradeBps, uint256 minTradeBps, uint256 cooldown, uint256 maxFeedAge
    );
    event Traded(
        address indexed caller,
        address indexed sell,
        address indexed buy,
        uint256 valueUsd,
        uint256 amountIn,
        uint256 amountOut
    );

    error LengthMismatch();
    error BadIndex();
    error BadParams();
    error NotUpdater();
    error NothingPending();
    error TooEarly(uint256 eta);
    error MarketClosed();
    error CoolingDown(uint256 until);
    error StalePrice(address feed);
    error BadPrice(address feed);
    error NotOverweight(address token);
    error NotUnderweight(address token);
    error TradeTooSmall(uint256 valueUsd);

    struct Params {
        uint256 maxSlippageBps;
        uint256 maxTradeBps;
        uint256 minTradeBps;
        uint256 cooldown;
        uint256 maxFeedAge;
    }

    /// @param feeds_        Chainlink USD feed per constituent, in `fund.constituents()` order.
    /// @param decimals_     Decimals of each constituent token.
    /// @param floatShares_  The initial index: float shares per constituent.
    /// @param multipliers_  Each token's multiplier when `floatShares_` was counted.
    constructor(
        BlueFund fund_,
        ISwapper swapper_,
        address[] memory feeds_,
        uint8[] memory decimals_,
        uint256[] memory floatShares_,
        uint256[] memory multipliers_,
        address owner_,
        address updater_,
        Params memory params_
    ) Ownable(owner_) {
        address[] memory tokens = fund_.constituents();
        uint256 n = tokens.length;
        if (feeds_.length != n || decimals_.length != n) revert LengthMismatch();
        fund = fund_;
        swapper = swapper_;
        _tokens = tokens;
        _feeds = feeds_;
        for (uint256 i; i < n; ++i) {
            _tokenScale.push(10 ** decimals_[i]);
            _feedScale.push(10 ** (18 - IPriceFeed(feeds_[i]).decimals()));
        }
        _checkIndex(floatShares_, multipliers_);
        _floatShares = floatShares_;
        _multipliers = multipliers_;
        updater = updater_;
        _setParams(params_);
        emit UpdaterSet(updater_);
        emit IndexActivated(floatShares_, multipliers_);
    }

    // ---------------------------------------------------------------- trading

    /// @notice Sell constituent `sellIdx` (overweight) for `buyIdx` (underweight). Callable by anyone;
    ///         `plan` names the pair with the most to do.
    function rebalance(uint256 sellIdx, uint256 buyIdx)
        external
        nonReentrant
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (!marketOpen()) revert MarketClosed();
        if (block.timestamp < lastTradeAt + cooldown) revert CoolingDown(lastTradeAt + cooldown);

        (uint256[] memory prices, uint256[] memory values, uint256[] memory targets, uint256 nav) =
            valuation();
        address sell = _tokens[sellIdx];
        address buy = _tokens[buyIdx];
        if (values[sellIdx] <= targets[sellIdx]) revert NotOverweight(sell);
        if (values[buyIdx] >= targets[buyIdx]) revert NotUnderweight(buy);

        uint256 valueUsd = Math.min(
            Math.min(values[sellIdx] - targets[sellIdx], targets[buyIdx] - values[buyIdx]),
            nav * maxTradeBps / BPS
        );
        if (valueUsd == 0 || valueUsd < nav * minTradeBps / BPS) revert TradeTooSmall(valueUsd);

        amountIn = Math.mulDiv(valueUsd, _tokenScale[sellIdx], prices[sellIdx]);
        uint256 minOut =
            Math.mulDiv(valueUsd * (BPS - maxSlippageBps) / BPS, _tokenScale[buyIdx], prices[buyIdx]);
        lastTradeAt = block.timestamp;
        amountOut = fund.swapHoldings(sell, amountIn, buy, minOut, address(swapper));
        emit Traded(msg.sender, sell, buy, valueUsd, amountIn, amountOut);
    }

    /// @notice The trade `rebalance` would do best right now: the most overweight and the most
    ///         underweight constituent. `ok` also requires an open market and no cooldown.
    ///         Reverts like `rebalance` when a price is stale.
    function plan() external view returns (bool ok, uint256 sellIdx, uint256 buyIdx, uint256 valueUsd) {
        (, uint256[] memory values, uint256[] memory targets, uint256 nav) = valuation();
        uint256 maxExcess;
        uint256 maxDeficit;
        for (uint256 i; i < values.length; ++i) {
            if (values[i] > targets[i] && values[i] - targets[i] > maxExcess) {
                maxExcess = values[i] - targets[i];
                sellIdx = i;
            } else if (targets[i] > values[i] && targets[i] - values[i] > maxDeficit) {
                maxDeficit = targets[i] - values[i];
                buyIdx = i;
            }
        }
        valueUsd = Math.min(Math.min(maxExcess, maxDeficit), nav * maxTradeBps / BPS);
        ok = valueUsd != 0 && valueUsd >= nav * minTradeBps / BPS && marketOpen()
            && block.timestamp >= lastTradeAt + cooldown;
    }

    /// @notice USD prices (18 decimals, per whole token), the USD value of each holding, its target
    ///         value, and NAV (the sum of values). Reverts on a stale or non-positive price.
    function valuation()
        public
        view
        returns (uint256[] memory prices, uint256[] memory values, uint256[] memory targets, uint256 nav)
    {
        uint256 n = _tokens.length;
        prices = new uint256[](n);
        values = new uint256[](n);
        targets = new uint256[](n);
        uint256[] memory caps = new uint256[](n);
        uint256 totalCap;
        for (uint256 i; i < n; ++i) {
            address t = _tokens[i];
            prices[i] = _price(i);
            values[i] = Math.mulDiv(fund.holdings(t), prices[i], _tokenScale[i]);
            nav += values[i];
            // A token was `multiplier` shares when the float was counted: a share is price / multiplier.
            caps[i] = Math.mulDiv(_floatShares[i], prices[i], _multipliers[i]);
            totalCap += caps[i];
        }
        for (uint256 i; i < n; ++i) {
            targets[i] = Math.mulDiv(nav, caps[i], totalCap);
        }
    }

    /// @notice True during the US regular session on a weekday (holidays are caught by stale prices).
    function marketOpen() public view returns (bool) {
        uint256 weekday = (block.timestamp / 1 days + 4) % 7; // 0 = Sunday; 1970-01-01 was a Thursday
        if (weekday == 0 || weekday == 6) return false;
        uint256 t = block.timestamp % 1 days;
        return t >= SESSION_OPEN && t < SESSION_CLOSE;
    }

    function _price(uint256 i) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = IPriceFeed(_feeds[i]).latestRoundData();
        if (answer <= 0) revert BadPrice(_feeds[i]);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxFeedAge) {
            revert StalePrice(_feeds[i]);
        }
        return uint256(answer) * _feedScale[i];
    }

    // ---------------------------------------------------------------- index

    /// @notice Propose new float shares, each with the token multiplier it was counted at; they can
    ///         be activated after `INDEX_DELAY`. Replaces any pending proposal and restarts the delay.
    function proposeIndex(uint256[] calldata floatShares_, uint256[] calldata multipliers_) external {
        if (msg.sender != updater && msg.sender != owner()) revert NotUpdater();
        _checkIndex(floatShares_, multipliers_);
        _pendingFloatShares = floatShares_;
        _pendingMultipliers = multipliers_;
        pendingIndexEta = block.timestamp + INDEX_DELAY;
        emit IndexProposed(floatShares_, multipliers_, pendingIndexEta);
    }

    function cancelIndex() external {
        if (msg.sender != updater && msg.sender != owner()) revert NotUpdater();
        if (pendingIndexEta == 0) revert NothingPending();
        delete _pendingFloatShares;
        delete _pendingMultipliers;
        delete pendingIndexEta;
        emit IndexCancelled();
    }

    /// @notice Anyone can apply a proposed index once its delay has passed.
    function activateIndex() external {
        uint256 eta = pendingIndexEta;
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TooEarly(eta);
        _floatShares = _pendingFloatShares;
        _multipliers = _pendingMultipliers;
        delete _pendingFloatShares;
        delete _pendingMultipliers;
        delete pendingIndexEta;
        emit IndexActivated(_floatShares, _multipliers);
    }

    function _checkIndex(uint256[] memory floatShares_, uint256[] memory multipliers_) private view {
        uint256 n = _tokens.length;
        if (floatShares_.length != n || multipliers_.length != n) revert LengthMismatch();
        for (uint256 i; i < n; ++i) {
            // Bounds keep floatShares * price (18 decimals) far from overflow and a multiplier sane.
            if (floatShares_[i] == 0 || floatShares_[i] > 1e15) revert BadIndex();
            if (multipliers_[i] < 1e12 || multipliers_[i] > 1e24) revert BadIndex();
        }
    }

    // ---------------------------------------------------------------- admin

    function setUpdater(address updater_) external onlyOwner {
        updater = updater_;
        emit UpdaterSet(updater_);
    }

    function setParams(Params calldata params_) external onlyOwner {
        _setParams(params_);
    }

    function _setParams(Params memory p) private {
        if (
            p.maxSlippageBps > MAX_SLIPPAGE_BPS || p.maxTradeBps == 0 || p.maxTradeBps > MAX_TRADE_BPS
                || p.minTradeBps > p.maxTradeBps || p.cooldown < MIN_COOLDOWN || p.maxFeedAge == 0
                || p.maxFeedAge > MAX_FEED_AGE
        ) revert BadParams();
        maxSlippageBps = p.maxSlippageBps;
        maxTradeBps = p.maxTradeBps;
        minTradeBps = p.minTradeBps;
        cooldown = p.cooldown;
        maxFeedAge = p.maxFeedAge;
        emit ParamsSet(p.maxSlippageBps, p.maxTradeBps, p.minTradeBps, p.cooldown, p.maxFeedAge);
    }

    // ---------------------------------------------------------------- views

    function constituents() external view returns (address[] memory) {
        return _tokens;
    }

    function feeds() external view returns (address[] memory) {
        return _feeds;
    }

    function floatShares() external view returns (uint256[] memory) {
        return _floatShares;
    }

    function multipliers() external view returns (uint256[] memory) {
        return _multipliers;
    }

    function pendingFloatShares() external view returns (uint256[] memory) {
        return _pendingFloatShares;
    }

    function pendingMultipliers() external view returns (uint256[] memory) {
        return _pendingMultipliers;
    }
}
