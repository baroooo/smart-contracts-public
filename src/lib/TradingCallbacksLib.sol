// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts/utils/math/SignedMath.sol';
import '../interfaces/IOstiumTradingStorage.sol';
import '../interfaces/IOstiumPairInfos.sol';
import '../interfaces/IOstiumRegistry.sol';
import '../interfaces/IOstiumVault.sol';
import '../interfaces/IOstiumPairsStorage.sol';
import '../interfaces/IOstiumTradingCallbacks.sol';

library TradingCallbacksLib {
    using SafeCast for uint256;
    using SafeCast for uint192;

    uint256 constant PRECISION_27 = 1e27;
    uint64 constant PRECISION_18 = 1e18;
    uint64 constant PRECISION_10 = 1e10;
    uint32 constant PRECISION_6 = 1e6;
    uint16 constant MAX_GAIN_P = 900; // 900% PnL (10x)
    uint256 constant SPREAD_DIVISOR = 2 * PRECISION_18;

    struct PriceImpactResult {
        uint256 priceImpactP;
        uint256 priceAfterImpact;
        bool isDynamic;
    }

    struct TradeValueResult {
        uint256 tradeValue;
        uint256 liqMarginValue;
        int256 rolloverFees;
        int256 fundingFees;
        int256 profitP;
    }

    function _getTradePriceImpact(int192 price, int192 ask, int192 bid, bool isOpen, bool isLong)
        internal
        pure
        returns (uint256 priceImpactP, uint256 priceAfterImpact)
    {
        if (price == 0) {
            return (0, 0);
        }
        bool aboveSpot = (isOpen == isLong);

        int192 usedPrice = aboveSpot ? ask : bid;

        priceImpactP = (SignedMath.abs(price - usedPrice) * PRECISION_18 / uint192(price) * 100);

        return (priceImpactP, uint192(usedPrice));
    }

    function _currentPercentProfit(
        int256 openPrice,
        int256 currentPrice,
        bool buy,
        int32 leverage,
        int32 initialLeverage
    ) internal pure returns (int256 p, int256 maxPnlP) {
        maxPnlP = int16(MAX_GAIN_P) * int32(PRECISION_6) * int256(leverage)
            / (leverage > initialLeverage ? leverage : initialLeverage);

        p = (buy ? currentPrice - openPrice : openPrice - currentPrice) * int32(PRECISION_6) * leverage / openPrice;

        p = p > maxPnlP ? maxPnlP : p;
    }

    function currentPercentProfit(
        int256 openPrice,
        int256 currentPrice,
        bool buy,
        int32 leverage,
        int32 initialLeverage
    ) public pure returns (int256 p, int256 maxPnlP) {
        return _currentPercentProfit(openPrice, currentPrice, buy, leverage, initialLeverage);
    }

    function correctTp(uint192 openPrice, uint192 tp, uint32 leverage, uint32 initialLeverage, bool buy)
        external
        pure
        returns (uint192)
    {
        (int256 p, int256 maxPnlP) =
            _currentPercentProfit(openPrice.toInt256(), tp.toInt256(), buy, int32(leverage), int32(initialLeverage));

        if (tp == 0 || p == maxPnlP) {
            uint256 tpDiff = (openPrice * SignedMath.abs(maxPnlP)) / PRECISION_6 / leverage;
            return (buy ? openPrice + tpDiff : (tpDiff <= openPrice ? openPrice - tpDiff : 0)).toUint192();
        }
        return tp;
    }

    function correctSl(uint192 openPrice, uint192 sl, uint32 leverage, uint32 initialLeverage, bool buy, uint8 maxSl_P)
        external
        pure
        returns (uint192)
    {
        (int256 p,) =
            _currentPercentProfit(openPrice.toInt256(), sl.toInt256(), buy, int32(leverage), int32(initialLeverage));
        if (sl > 0 && p < int8(maxSl_P) * int32(PRECISION_6) * -1) {
            uint256 slDiff = (openPrice * maxSl_P) / leverage;
            return (buy ? openPrice - slDiff : openPrice + slDiff).toUint192();
        }
        return sl;
    }

    function correctToNullSl(
        uint192 openPrice,
        uint192 sl,
        uint32 leverage,
        uint32 initialLeverage,
        bool buy,
        uint8 maxSl_P
    ) external pure returns (uint192) {
        (int256 p,) =
            _currentPercentProfit(openPrice.toInt256(), sl.toInt256(), buy, int32(leverage), int32(initialLeverage));
        if (sl > 0 && p < int8(maxSl_P) * int32(PRECISION_6) * -1) {
            return 0;
        }
        return sl;
    }

    function withinMaxLeverage(uint16 pairIndex, uint256 leverage, IOstiumPairsStorage pairsStorage)
        public
        view
        returns (bool)
    {
        return leverage <= pairsStorage.pairMaxLeverage(pairIndex);
    }

    function withinExposureLimits(
        uint16 pairIndex,
        bool buy,
        uint256 collateral,
        uint32 leverage,
        uint256 price,
        IOstiumPairsStorage pairsStorage,
        IOstiumTradingStorage tradingStorage
    ) public view returns (bool) {
        return tradingStorage.openInterest(pairIndex, buy ? 0 : 1) * price / PRECISION_18 / 1e12
            + collateral * leverage / 100 <= tradingStorage.openInterest(pairIndex, 2)
            && pairsStorage.groupCollateral(pairIndex, buy) + collateral <= pairsStorage.groupMaxCollateral(pairIndex);
    }

    function getTradeAndPriceData(
        IOstiumPriceUpKeep.PriceUpKeepAnswer calldata a,
        IOstiumTradingStorage.Trade calldata t,
        IOstiumPairInfos pairInfos,
        uint32 initialLeverage,
        uint32 maxLeverage,
        uint256 collateral,
        bool isMarketPrice
    ) external returns (TradeValueResult memory, PriceImpactResult memory) {
        PriceImpactResult memory result =
            getDynamicTradePriceImpact(a.price, a.ask, a.bid, false, t, pairInfos, collateral);

        (int256 profitP,) = currentPercentProfit(
            t.openPrice.toInt256(),
            isMarketPrice ? a.price : result.priceAfterImpact.toInt256(),
            t.buy,
            int32(t.leverage),
            int32(initialLeverage)
        );

        (uint256 tradeValue, uint256 liqMarginValue, int256 rolloverFees, int256 fundingFees) =
            pairInfos.getTradeValue(t.trader, t.pairIndex, t.index, t.buy, collateral, t.leverage, profitP, maxLeverage);

        return (
            TradeValueResult({
                tradeValue: tradeValue,
                liqMarginValue: liqMarginValue,
                rolloverFees: rolloverFees,
                fundingFees: fundingFees,
                profitP: profitP
            }),
            result
        );
    }

    function getOpenTradeMarketCancelReason(
        bool isPaused,
        uint256 wantedPrice,
        uint256 slippageP,
        uint192 a_price,
        IOstiumTradingStorage.Trade memory trade,
        uint256 priceImpactP,
        IOstiumPairInfos pairInfos,
        IOstiumPairsStorage pairsStorage,
        IOstiumTradingStorage tradingStorage
    ) external view returns (IOstiumTradingCallbacks.CancelReason) {
        uint256 maxSlippage = (wantedPrice * slippageP) / 100 / 100;

        if (isPaused) return IOstiumTradingCallbacks.CancelReason.PAUSED;

        // Check slippage
        if (trade.buy ? trade.openPrice > wantedPrice + maxSlippage : trade.openPrice < wantedPrice - maxSlippage) {
            return IOstiumTradingCallbacks.CancelReason.SLIPPAGE;
        }

        // Check if TP is reached
        if (trade.tp != 0 && (trade.buy ? trade.openPrice >= trade.tp : trade.openPrice <= trade.tp)) {
            return IOstiumTradingCallbacks.CancelReason.TP_REACHED;
        }

        // Check if SL is reached
        if (trade.sl != 0 && (trade.buy ? trade.openPrice <= trade.sl : trade.openPrice >= trade.sl)) {
            return IOstiumTradingCallbacks.CancelReason.SL_REACHED;
        }

        // Check exposure limits
        if (
            !withinExposureLimits(
                trade.pairIndex, trade.buy, trade.collateral, trade.leverage, a_price, pairsStorage, tradingStorage
            )
        ) {
            return IOstiumTradingCallbacks.CancelReason.EXPOSURE_LIMITS;
        }

        // Check price impact
        if (priceImpactP * trade.leverage / 100 / PRECISION_18 > pairInfos.maxNegativePnlOnOpenP()) {
            return IOstiumTradingCallbacks.CancelReason.PRICE_IMPACT;
        }

        // Check max leverage
        if (!withinMaxLeverage(trade.pairIndex, trade.leverage, pairsStorage)) {
            return IOstiumTradingCallbacks.CancelReason.MAX_LEVERAGE;
        }

        return IOstiumTradingCallbacks.CancelReason.NONE;
    }

    function getAutomationOpenOrderCancelReason(
        IOstiumTradingStorage.OpenLimitOrder memory o,
        uint256 priceAfterImpact,
        uint256 a_price,
        uint256 priceImpactP,
        IOstiumPairInfos pairInfos,
        IOstiumPairsStorage pairsStorage,
        IOstiumTradingStorage tradingStorage
    ) external view returns (IOstiumTradingCallbacks.CancelReason) {
        // Check if price target is hit based on order type
        bool isNotHit = o.orderType == IOstiumTradingStorage.OpenOrderType.LIMIT
            ? (o.buy ? priceAfterImpact > o.targetPrice : priceAfterImpact < o.targetPrice)
            : (o.buy ? uint192(a_price) < o.targetPrice : uint192(a_price) > o.targetPrice);

        if (isNotHit) return IOstiumTradingCallbacks.CancelReason.NOT_HIT;

        // Check if TP is reached
        if (o.tp != 0 && (o.buy ? priceAfterImpact >= o.tp : priceAfterImpact <= o.tp)) {
            return IOstiumTradingCallbacks.CancelReason.TP_REACHED;
        }

        // Check if SL is reached
        if (o.sl != 0 && (o.buy ? priceAfterImpact <= o.sl : priceAfterImpact >= o.sl)) {
            return IOstiumTradingCallbacks.CancelReason.SL_REACHED;
        }

        // Check exposure limits
        if (
            !withinExposureLimits(
                o.pairIndex, o.buy, o.collateral, o.leverage, uint192(a_price), pairsStorage, tradingStorage
            )
        ) {
            return IOstiumTradingCallbacks.CancelReason.EXPOSURE_LIMITS;
        }

        // Check price impact
        if (priceImpactP * o.leverage / 100 / PRECISION_18 > pairInfos.maxNegativePnlOnOpenP()) {
            return IOstiumTradingCallbacks.CancelReason.PRICE_IMPACT;
        }

        // Check max leverage
        if (!withinMaxLeverage(o.pairIndex, o.leverage, pairsStorage)) {
            return IOstiumTradingCallbacks.CancelReason.MAX_LEVERAGE;
        }

        return IOstiumTradingCallbacks.CancelReason.NONE;
    }

    function getAutomationCloseOrderCancelReason(
        IOstiumTradingStorage.LimitOrder orderType,
        IOstiumTradingStorage.Trade memory t,
        uint256 triggerPrice,
        uint256 usdcSentToTrader,
        bool isDayTradeClosed
    ) external pure returns (IOstiumTradingCallbacks.CancelReason) {
        if (orderType == IOstiumTradingStorage.LimitOrder.CLOSE_DAY_TRADE) {
            return isDayTradeClosed
                ? IOstiumTradingCallbacks.CancelReason.NONE
                : IOstiumTradingCallbacks.CancelReason.CLOSE_DAY_TRADE_NOT_ALLOWED;
        } else if (orderType == IOstiumTradingStorage.LimitOrder.LIQ) {
            return usdcSentToTrader == 0
                ? IOstiumTradingCallbacks.CancelReason.NONE
                : IOstiumTradingCallbacks.CancelReason.NOT_HIT;
        } else if (orderType == IOstiumTradingStorage.LimitOrder.TP) {
            return t.tp > 0 && (t.buy ? triggerPrice >= t.tp : triggerPrice <= t.tp)
                ? IOstiumTradingCallbacks.CancelReason.NONE
                : IOstiumTradingCallbacks.CancelReason.NOT_HIT;
        } else if (orderType == IOstiumTradingStorage.LimitOrder.SL) {
            return t.sl > 0 && (t.buy ? triggerPrice <= t.sl : triggerPrice >= t.sl)
                ? IOstiumTradingCallbacks.CancelReason.NONE
                : IOstiumTradingCallbacks.CancelReason.NOT_HIT;
        }
        return IOstiumTradingCallbacks.CancelReason.NOT_HIT;
    }

    function getHandleRemoveCollateralCancelReason(
        IOstiumPriceUpKeep.PriceUpKeepAnswer calldata a,
        IOstiumTradingStorage.Trade memory trade,
        IOstiumPairInfos pairInfos,
        IOstiumPairsStorage pairsStorage,
        uint32 initialLeverage
    ) external returns (IOstiumTradingCallbacks.CancelReason) {
        TradingCallbacksLib.PriceImpactResult memory result =
            getDynamicTradePriceImpact(a.price, a.ask, a.bid, false, trade, pairInfos, trade.collateral);

        (int256 profitP, int256 maxPnlP) = currentPercentProfit(
            trade.openPrice.toInt256(),
            result.priceAfterImpact.toInt256(),
            trade.buy,
            int32(trade.leverage),
            int32(initialLeverage)
        );

        uint32 maxLeverage = pairsStorage.pairMaxLeverage(trade.pairIndex);
        (uint256 tradeValue, uint256 liqMarginValue,,) = pairInfos.getTradeValue(
            trade.trader,
            trade.pairIndex,
            trade.index,
            trade.buy,
            trade.collateral,
            trade.leverage,
            profitP,
            maxLeverage
        );

        bool isLiquidated = tradeValue < liqMarginValue;
        uint256 usdcSentToTrader = isLiquidated ? 0 : tradeValue;

        if (usdcSentToTrader == 0) {
            return IOstiumTradingCallbacks.CancelReason.UNDER_LIQUIDATION;
        }

        if (trade.leverage > maxLeverage) {
            return IOstiumTradingCallbacks.CancelReason.MAX_LEVERAGE;
        }

        if (profitP == maxPnlP) {
            return IOstiumTradingCallbacks.CancelReason.GAIN_LOSS;
        }

        return IOstiumTradingCallbacks.CancelReason.NONE;
    }

    function _decayVolumeWithPade(uint256 volume, uint32 decayInterval, uint128 decayRate)
        internal
        pure
        returns (uint256 decayedVolume)
    {
        if (decayInterval == 0) {
            return volume;
        }

        uint256 decayFactor_half = uint256(decayRate) * decayInterval / 2;
        uint256 numerator = PRECISION_18 > decayFactor_half ? PRECISION_18 - decayFactor_half : 0;
        uint256 denominator = PRECISION_18 + decayFactor_half;
        uint256 decayMultiplier = numerator * PRECISION_18 / denominator;

        return uint128(uint256(volume) * decayMultiplier / PRECISION_18);
    }

    function _priceImpactFunction(
        uint256 netVolThreshold,
        uint256 priceImpactK,
        bool buy,
        bool isOpen,
        uint256 tradeSize,
        int256 initialImbalance,
        uint256 midPrice,
        uint256 askPrice,
        uint256 bidPrice
    ) internal pure returns (uint256 priceImpactP) {
        int256 nextImbalance = initialImbalance + (isOpen == buy ? int256(tradeSize) : -int256(tradeSize));
        uint256 absNextImbalance = nextImbalance >= 0 ? uint256(nextImbalance) : uint256(-nextImbalance);
        uint256 absInitialImbalance = initialImbalance >= 0 ? uint256(initialImbalance) : uint256(-initialImbalance);

        if (absNextImbalance < absInitialImbalance && (initialImbalance * nextImbalance >= 0)) {
            return 0;
        }

        if (absNextImbalance <= netVolThreshold) {
            return 0;
        }

        uint256 spread = (askPrice - bidPrice) * PRECISION_18 / midPrice;
        uint256 excessOverThreshold = absNextImbalance - netVolThreshold;
        uint256 thresholdTradeSize = tradeSize < excessOverThreshold ? tradeSize : excessOverThreshold;
        uint256 spreadComponent = (spread * thresholdTradeSize) / SPREAD_DIVISOR;

        uint256 dynamicComponent = 0;
        if (excessOverThreshold > 0 && thresholdTradeSize > 0) {
            uint256 thresholdRatio = (thresholdTradeSize * PRECISION_18) / excessOverThreshold;
            uint256 excessSquared = (excessOverThreshold * excessOverThreshold) / PRECISION_18;
            dynamicComponent = (
                (thresholdTradeSize * thresholdRatio / PRECISION_18) * (priceImpactK * excessSquared / PRECISION_27)
            ) / PRECISION_18;
        }

        uint256 priceImpactUSD = spreadComponent + dynamicComponent;
        priceImpactP = priceImpactUSD * PRECISION_18 / tradeSize * 100;

        return priceImpactP;
    }

    function getDynamicTradePriceImpact(
        int192 price,
        int192 ask,
        int192 bid,
        bool isOpen,
        IOstiumTradingStorage.Trade memory trade,
        IOstiumPairInfos pairInfos,
        uint256 collateralValue
    ) public returns (PriceImpactResult memory) {
        uint256 priceImpactK = pairInfos.getPairPriceImpactK(trade.pairIndex);

        uint256 priceImpactP;
        uint256 priceAfterImpact;
        if (priceImpactK == 0) {
            (priceImpactP, priceAfterImpact) = _getTradePriceImpact(price, ask, bid, isOpen, trade.buy);
            return PriceImpactResult({priceImpactP: priceImpactP, priceAfterImpact: priceAfterImpact, isDynamic: false});
        }

        (uint256 netVolThreshold, uint128 decayRate,) = pairInfos.pairDynamicSpreadParams(trade.pairIndex);

        (uint256 buyVolume, uint256 sellVolume, uint32 lastUpdateTimestamp) =
            pairInfos.pairDynamicSpreadState(trade.pairIndex);

        uint32 dt = block.timestamp > lastUpdateTimestamp ? uint32(block.timestamp) - lastUpdateTimestamp : 0;

        uint256 decayedBuyVolume = _decayVolumeWithPade(buyVolume, dt, decayRate);
        uint256 decayedSellVolume = _decayVolumeWithPade(sellVolume, dt, decayRate);

        uint256 tradeNotional = collateralValue * trade.leverage * PRECISION_10;

        int256 initialImbalance = int256(decayedBuyVolume) - int256(decayedSellVolume);

        priceAfterImpact = uint192(price);

        priceImpactP = _priceImpactFunction(
            netVolThreshold,
            priceImpactK,
            trade.buy,
            isOpen,
            tradeNotional,
            initialImbalance,
            uint192(price),
            uint192(ask),
            uint192(bid)
        );

        if (priceImpactP > 0) {
            if (isOpen == trade.buy) {
                priceAfterImpact = priceAfterImpact * (PRECISION_18 + (priceImpactP / 100)) / PRECISION_18;
            } else {
                priceAfterImpact =
                    priceImpactP < 100e18 ? priceAfterImpact * (PRECISION_18 - (priceImpactP / 100)) / PRECISION_18 : 0;
            }
        }

        return PriceImpactResult({priceImpactP: priceImpactP, priceAfterImpact: priceAfterImpact, isDynamic: true});
    }

    function calculateDecayedVolumesWithPostFeeCollateral(
        uint16 pairIndex,
        bool isOpen,
        bool isBuy,
        uint256 postFeeCollateral,
        uint32 leverage,
        IOstiumPairInfos pairInfos
    ) external returns (uint256 decayedBuyVolume, uint256 decayedSellVolume) {
        (, uint128 decayRate,) = pairInfos.pairDynamicSpreadParams(pairIndex);

        (uint256 buyVolume, uint256 sellVolume, uint32 lastUpdateTimestamp) =
            pairInfos.pairDynamicSpreadState(pairIndex);

        uint32 dt = block.timestamp > lastUpdateTimestamp ? uint32(block.timestamp) - lastUpdateTimestamp : 0;

        decayedBuyVolume = _decayVolumeWithPade(buyVolume, dt, decayRate);
        decayedSellVolume = _decayVolumeWithPade(sellVolume, dt, decayRate);

        uint256 tradeNotional = postFeeCollateral * leverage * PRECISION_10;

        if (isOpen == isBuy) {
            decayedBuyVolume += tradeNotional;
        } else {
            decayedSellVolume += tradeNotional;
        }
    }
}
