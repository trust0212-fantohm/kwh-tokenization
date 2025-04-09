// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "../library/CommonTypes.sol";

interface IMaisonEnergyOrderBook {
    enum OrderType {
        BUY,
        SELL
    }
    struct OrderMetadata {
        OrderType orderType;
        CommonTypes.ZoneType zone;
        CommonTypes.PhysicalDeliveryType physicalDelivery;
    }
    struct Order {
        uint256 id;
        address trader;
        uint256 tokenId;
        OrderMetadata orderMetadata;
        uint256 desiredPrice; // Only For LimitOrder
        uint256 tokenAmount; // For sell
        uint256 remainTokenAmount; // For sell
        uint256 usdcAmount; // For buy
        uint256 remainUsdcAmount;
        bool isFilled;
        bool isMarketOrder;
        bool isCanceled;
        uint256 validTo; // Only For LimitOrder
        uint256 lastTradeTimestamp;
        uint256 createdAt;
    }

    event TradeExecuted(
        uint256 indexed tokenId,
        uint256 buyOrderId,
        uint256 sellOrderId,
        address indexed buyer,
        address indexed seller,
        uint256 price,
        uint256 tokenAmount
    );
    event SellMarketOrderCreated(address indexed seller, uint256 tokenAmount);
    event LimitOrderCreated(
        address indexed trader,
        uint256 usdcAmount,
        uint256 desiredPrice,
        uint256 tokenAmount,
        uint256 timeInForce,
        OrderMetadata orderMetadata
    );
    event OrderCanceled(uint256 indexed orderId, uint256 cancleTime);
    event NoLiquiditySellOrderCreated(
        address indexed tokenHolder,
        uint256 amount,
        uint256 orderCreatedTime
    );
    event TreasuryUpdated(address indexed newTreasury);
    event FeeUpdated(uint256 buyFeeBips, uint256 sellFeeBips);

    function createBuyMarketOrder(
        uint256 usdcValue,
        uint256 tokenId,
        OrderMetadata memory orderMetadata
    ) external;
    function createSellMarketOrder(
        uint256 tokenAmount,
        uint256 tokenId,
        OrderMetadata memory orderMetadata
    ) external;
    function createLimitOrder(
        uint256 usdcAmount, // For Buy
        uint256 desiredPrice,
        uint256 tokenAmount,
        uint256 validTo,
        uint256 tokenId,
        OrderMetadata memory orderMetadata
    ) external;
    function cancelOrder(uint256 id) external;

    function setFeeBips(uint256 _buyFeeBips, uint256 _sellFeeBips) external;
    function setTreasury(address _treasury) external;
}
