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
        uint256 quantity; // For sell
        uint256 remainQuantity;
        uint256 usdcAmount; // For buy
        uint256 remainUsdcValue;
        bool isCanceled;
        bool isFilled;
        uint256 validTo; // Only For LimitOrder
        uint256 lastTradeTimestamp;
    }
    // struct RecentOrder {
    //     uint256 totalValue;
    //     uint256 desiredPrice;
    //     uint256 remainQuantity;
    // }

    event TradeExecuted(
        uint256 indexed tokenId,
        uint256 buyOrderId,
        uint256 sellOrderId,
        address indexed buyer,
        address indexed seller,
        uint256 price,
        uint256 quantity
    );
    event SellMarketOrderCreated(address indexed seller, uint256 quantity);
    event LimitOrderCreated(
        address indexed trader,
        uint256 usdcAmount,
        uint256 desiredPrice,
        uint256 quantity,
        uint256 timeInForce,
        OrderMetadata orderMetadata
    );
    event OrderCanceled(
        uint256 indexed orderId,
        address indexed trader,
        uint256 cancleTime
    );
    event NoLiquiditySellOrderCreated(
        address indexed tokenHolder,
        uint256 amount,
        uint256 orderCreatedTime
    );
    event TreasuryUpdated(address indexed newTreasury);
    event BuyFeeUpdated(uint256 newBuyFee);
    event SellFeeUpdated(uint256 newSellFee);

    function createBuyMarketOrder(
        uint256 usdcValue,
        uint256 tokenId,
        OrderMetadata memory orderMetadata
    ) external;
    function createSellMarketOrder(
        uint256 quantity,
        uint256 tokenId,
        OrderMetadata memory orderMetadata
    ) external;
    function createLimitOrder(
        uint256 usdcAmount,
        uint256 desiredPrice,
        uint256 quantity,
        uint256 validTo,
        uint256 tokenId,
        OrderMetadata memory orderMetadata
    ) external;
    function cancelOrder(uint256 id) external;
    // function getLatestRate(
    //     CommonTypes.ZoneType zone,
    //     CommonTypes.PhysicalDeliveryType physicalDelivery
    // )
    //     external
    //     view
    //     returns (
    //         RecentOrder memory bestBidOrder,
    //         RecentOrder memory bestAskOrder
    //     );
    // function orderBook(
    //     uint256 depth,
    //     OrderType orderType
    // ) external view returns (uint256, Order[] memory);
    function getOrderById(uint256 id) external view returns (Order memory);
    function getOrdersByUser(
        address user,
        bool status
    ) external view returns (Order[] memory);
    function setbuyFeeBips(uint256 _buyFeeBips) external;
    function setsellFeeBips(uint256 _sellFeeBips) external;
    function setTreasury(address _treasury) external;
    // function setPriceOracle(address _newPriceOracleAddress) external;
}
