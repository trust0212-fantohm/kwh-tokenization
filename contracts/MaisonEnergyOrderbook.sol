// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interface/IMaisonEnergyOrderBook.sol";
// import "./interface/IERCOTPriceOracle.sol";
import "./MaisonEnergyToken.sol";
import "./library/CommonTypes.sol";

contract MaisonEnergyOrderBook is
    Initializable,
    IMaisonEnergyOrderBook,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    AutomationCompatibleInterface
{
    using SafeERC20 for IERC20;

    uint256 public nonce;
    uint256 private constant BASE_BIPS = 10000;
    uint256 public buyFeeBips;
    uint256 public sellFeeBips;
    uint256[] public fullfilledOrderIds;

    address public treasury;
    address public insuranceAddress;

    mapping(OrderType => mapping(CommonTypes.ZoneType => mapping(CommonTypes.PhysicalDeliveryType => uint256[])))
        public activeOrderIds;
    mapping(uint256 => Order) private ordersById;
    mapping(address => uint256[]) private ordersByUser; // Tracks order IDs by user

    // IERCOTPriceOracle public priceOracle;
    IERC20 public usdc;
    MaisonEnergyToken public maisonEnergyToken;

    function initialize(
        address _treasury,
        address _insuranceAddress,
        // address _priceOracle,
        address _usdcAddress,
        address _maisonEnergyTokenAddress
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        require(_usdcAddress != address(0), "Invalid usdc address");
        require(
            _maisonEnergyTokenAddress != address(0),
            "Invalid token address"
        );
        require(_treasury != address(0), "Invalid treasury address");
        // require(_priceOracle != address(0), "Invalid priceoracle address");

        treasury = _treasury;
        insuranceAddress = _insuranceAddress;

        buyFeeBips = 500;
        sellFeeBips = 500;
        nonce = 0;

        // priceOracle = IERCOTPriceOracle(_priceOracle);
        usdc = IERC20(_usdcAddress);
        maisonEnergyToken = MaisonEnergyToken(_maisonEnergyTokenAddress);
    }

    /**
     * @dev Create new buy market order which will be executed instantly
     */
    struct BuyOrderExecution {
        uint256 tokenAmount;
        uint256 realAmount;
        uint256 feeAmount;
        uint256 desiredUsdcValue;
        uint256 purchasedTokenAmount;
    }

    function createBuyMarketOrder(
        uint256 usdcValue,
        uint256 tokenId,
        OrderMetadata memory orderMetadata
    ) external nonReentrant {
        require(
            orderMetadata.orderType == OrderType.BUY,
            "Should be Buy Order"
        );
        require(
            usdc.balanceOf(msg.sender) >= usdcValue,
            "You don't have enough USDC"
        );

        Order[] memory activeSellOrders = getActiveOrders(
            OrderType.SELL,
            orderMetadata.zone,
            orderMetadata.physicalDelivery
        );
        require(activeSellOrders.length > 0, "Insufficient Sell Orders");

        usdc.safeTransferFrom(msg.sender, address(this), usdcValue);

        Order memory marketOrder = Order({
            id: nonce,
            trader: msg.sender,
            tokenId: tokenId,
            orderMetadata: orderMetadata,
            desiredPrice: 0,
            quantity: 0,
            remainQuantity: 0,
            usdcAmount: usdcValue,
            remainUsdcValue: usdcValue,
            isCanceled: false,
            isFilled: false,
            validTo: 0,
            lastTradeTimestamp: 0
        });

        ordersById[nonce] = marketOrder;
        ordersByUser[msg.sender].push(nonce);
        nonce++;

        BuyOrderExecution memory data;
        data.tokenAmount = 0;

        for (uint256 i = activeSellOrders.length; i > 0; i--) {
            Order storage sellOrder = ordersById[activeSellOrders[i - 1].id]; // Fetch from storage

            if (isInvalidOrder(sellOrder.id)) continue;

            data.desiredUsdcValue =
                sellOrder.desiredPrice *
                sellOrder.remainQuantity;

            if (marketOrder.remainUsdcValue >= data.desiredUsdcValue) {
                (data.realAmount, data.feeAmount) = getAmountDeductFee(
                    data.desiredUsdcValue,
                    OrderType.SELL
                );
                usdc.safeTransfer(sellOrder.trader, data.realAmount);
                if (data.feeAmount > 0)
                    usdc.safeTransfer(treasury, data.feeAmount);

                marketOrder.remainUsdcValue -= data.desiredUsdcValue;
                data.tokenAmount += sellOrder.remainQuantity;

                sellOrder.isFilled = true;
                sellOrder.remainQuantity = 0;
                sellOrder.lastTradeTimestamp = block.timestamp;

                emit TradeExecuted(
                    tokenId,
                    marketOrder.id,
                    sellOrder.id,
                    marketOrder.trader,
                    sellOrder.trader,
                    sellOrder.desiredPrice,
                    sellOrder.remainQuantity
                );
            } else {
                (data.realAmount, data.feeAmount) = getAmountDeductFee(
                    marketOrder.remainUsdcValue,
                    OrderType.SELL
                );
                usdc.safeTransfer(sellOrder.trader, data.realAmount);
                if (data.feeAmount > 0)
                    usdc.safeTransfer(treasury, data.feeAmount);

                data.purchasedTokenAmount =
                    marketOrder.remainUsdcValue /
                    sellOrder.desiredPrice;
                marketOrder.remainUsdcValue = 0;

                sellOrder.remainQuantity -= data.purchasedTokenAmount;
                data.tokenAmount += data.purchasedTokenAmount;
                sellOrder.lastTradeTimestamp = block.timestamp;

                emit TradeExecuted(
                    tokenId,
                    marketOrder.id,
                    sellOrder.id,
                    marketOrder.trader,
                    sellOrder.trader,
                    sellOrder.desiredPrice,
                    data.purchasedTokenAmount
                );
                break;
            }
        }

        if (usdcValue == marketOrder.remainUsdcValue)
            revert("No sell orders whose price meets your condition.");
        if (marketOrder.remainUsdcValue > 0)
            usdc.safeTransfer(msg.sender, marketOrder.remainUsdcValue);

        fullfilledOrderIds.push(marketOrder.id);
        removeInvalidOrdersFromLast(marketOrder.orderMetadata);

        (data.realAmount, data.feeAmount) = getAmountDeductFee(
            data.tokenAmount,
            OrderType.BUY
        );
        maisonEnergyToken.safeTransferFrom(
            address(this),
            msg.sender,
            tokenId,
            data.realAmount,
            ""
        );
        if (data.feeAmount > 0)
            maisonEnergyToken.safeTransferFrom(
                address(this),
                treasury,
                tokenId,
                data.feeAmount,
                ""
            );

        marketOrder.lastTradeTimestamp = block.timestamp;
    }

    /**
     * @dev Create new sell market order which will be executed instantly
     */
    struct SellOrderExecution {
        uint256 usdcAmount;
        uint256 desiredTokenAmount;
        uint256 realAmount;
        uint256 feeAmount;
        uint256 usedUsdcAmount;
    }

    function createSellMarketOrder(
        uint256 quantity,
        uint256 tokenId,
        OrderMetadata memory orderMetadata
    ) external nonReentrant {
        require(
            orderMetadata.orderType == OrderType.SELL,
            "Should be Sell Order"
        );
        require(
            maisonEnergyToken.balanceOf(msg.sender, tokenId) > 0,
            "You don't have enough token"
        );

        Order[] memory activeBuyOrders = getActiveOrders(
            OrderType.BUY,
            orderMetadata.zone,
            orderMetadata.physicalDelivery
        );

        // If there are no active buy orders, send tokens to insurance address
        if (activeBuyOrders.length == 0) {
            maisonEnergyToken.safeTransferFrom(
                msg.sender,
                insuranceAddress,
                tokenId,
                quantity,
                ""
            );
            emit NoLiquiditySellOrderCreated(
                msg.sender,
                quantity,
                block.timestamp
            );
            return;
        }

        maisonEnergyToken.safeTransferFrom(
            msg.sender,
            address(this),
            tokenId,
            quantity,
            ""
        );

        Order memory marketOrder = Order({
            id: nonce,
            trader: msg.sender,
            tokenId: tokenId,
            orderMetadata: orderMetadata,
            desiredPrice: 0,
            quantity: quantity,
            remainQuantity: quantity,
            usdcAmount: 0,
            remainUsdcValue: 0,
            isCanceled: false,
            isFilled: false,
            validTo: 0,
            lastTradeTimestamp: 0
        });

        ordersById[nonce] = marketOrder;
        ordersByUser[msg.sender].push(nonce);
        nonce++;

        SellOrderExecution memory data;
        data.usdcAmount = 0;

        for (uint256 i = activeBuyOrders.length; i > 0; i--) {
            Order storage buyOrder = ordersById[activeBuyOrders[i - 1].id]; // Fetch from storage

            if (isInvalidOrder(buyOrder.id)) continue;

            data.desiredTokenAmount = buyOrder.remainQuantity;

            if (marketOrder.remainQuantity >= data.desiredTokenAmount) {
                (data.realAmount, data.feeAmount) = getAmountDeductFee(
                    data.desiredTokenAmount,
                    OrderType.BUY
                );
                maisonEnergyToken.safeTransferFrom(
                    address(this),
                    buyOrder.trader,
                    tokenId,
                    data.realAmount,
                    ""
                );

                if (data.feeAmount > 0) {
                    maisonEnergyToken.safeTransferFrom(
                        address(this),
                        treasury,
                        tokenId,
                        data.feeAmount,
                        ""
                    );
                }

                marketOrder.remainQuantity -= data.desiredTokenAmount;
                data.usdcAmount += buyOrder.remainUsdcValue;

                buyOrder.isFilled = true;
                buyOrder.remainUsdcValue = 0;
                buyOrder.remainQuantity = 0;
                buyOrder.lastTradeTimestamp = block.timestamp;

                emit TradeExecuted(
                    tokenId,
                    buyOrder.id,
                    marketOrder.id,
                    buyOrder.trader,
                    marketOrder.trader,
                    buyOrder.desiredPrice,
                    buyOrder.remainQuantity
                );
            } else {
                (data.realAmount, data.feeAmount) = getAmountDeductFee(
                    marketOrder.remainQuantity,
                    OrderType.BUY
                );
                maisonEnergyToken.safeTransferFrom(
                    address(this),
                    buyOrder.trader,
                    tokenId,
                    data.realAmount,
                    ""
                );

                if (data.feeAmount > 0) {
                    maisonEnergyToken.safeTransferFrom(
                        address(this),
                        treasury,
                        tokenId,
                        data.feeAmount,
                        ""
                    );
                }

                data.usedUsdcAmount =
                    marketOrder.remainQuantity *
                    buyOrder.desiredPrice;
                marketOrder.remainQuantity = 0;

                buyOrder.remainUsdcValue -= data.usedUsdcAmount;
                buyOrder.remainQuantity -= marketOrder.remainQuantity;
                data.usdcAmount += data.usedUsdcAmount;
                buyOrder.lastTradeTimestamp = block.timestamp;

                emit TradeExecuted(
                    tokenId,
                    buyOrder.id,
                    marketOrder.id,
                    buyOrder.trader,
                    marketOrder.trader,
                    buyOrder.desiredPrice,
                    marketOrder.remainQuantity
                );
                break;
            }
        }

        if (marketOrder.remainQuantity > 0) {
            maisonEnergyToken.safeTransferFrom(
                address(this),
                insuranceAddress,
                tokenId,
                marketOrder.remainQuantity,
                ""
            );
            emit NoLiquiditySellOrderCreated(
                msg.sender,
                marketOrder.remainQuantity,
                block.timestamp
            );
        }

        fullfilledOrderIds.push(marketOrder.id);
        removeInvalidOrdersFromLast(marketOrder.orderMetadata);

        // Transfer USDC to seller
        (data.realAmount, data.feeAmount) = getAmountDeductFee(
            data.usdcAmount,
            OrderType.SELL
        );
        usdc.safeTransfer(msg.sender, data.realAmount);

        if (data.feeAmount > 0) {
            usdc.safeTransfer(treasury, data.feeAmount);
        }

        marketOrder.lastTradeTimestamp = block.timestamp;
    }

    /**
     * @dev Create new limit order
     */
    function createLimitOrder(
        uint256 usdcAmount,
        uint256 desiredPrice,
        uint256 quantity,
        uint256 validTo,
        uint256 tokenId,
        OrderMetadata memory orderMetadata
    ) external {
        require(validTo > block.timestamp, "Invalid time limit");

        if (orderMetadata.orderType == OrderType.BUY) {
            usdc.safeTransferFrom(
                msg.sender,
                address(this),
                desiredPrice * quantity
            );
        } else {
            maisonEnergyToken.safeTransferFrom(
                msg.sender,
                address(this),
                tokenId,
                quantity,
                ""
            );
        }

        Order memory newOrder = Order({
            id: nonce,
            trader: msg.sender,
            tokenId: tokenId,
            orderMetadata: orderMetadata,
            desiredPrice: desiredPrice,
            quantity: quantity,
            remainQuantity: quantity,
            usdcAmount: usdcAmount,
            remainUsdcValue: usdcAmount,
            isCanceled: false,
            isFilled: false,
            validTo: validTo,
            lastTradeTimestamp: 0
        });

        ordersById[nonce] = newOrder;
        activeOrderIds[orderMetadata.orderType][orderMetadata.zone][
            orderMetadata.physicalDelivery
        ].push(nonce);
        ordersByUser[msg.sender].push(nonce);
        nonce++;

        // Insert newOrder into active sell/buy limit order list. It should be sorted by desiredPrice
        // In this way, we iterate order list from end, and pop the last order from active order list

        insertLimitOrder(newOrder.id);

        executeLimitOrders(tokenId, orderMetadata);

        emit LimitOrderCreated(
            msg.sender,
            usdcAmount,
            desiredPrice,
            quantity,
            validTo,
            orderMetadata
        );
    }

    function insertLimitOrder(uint256 orderId) internal {
        Order storage order = ordersById[orderId]; // Fetch order from storage

        uint256[] storage orderIds = activeOrderIds[
            order.orderMetadata.orderType
        ][order.orderMetadata.zone][order.orderMetadata.physicalDelivery];

        // Insert orderId at the end
        orderIds.push(orderId);

        uint256 i = orderIds.length;

        if (order.orderMetadata.orderType == OrderType.BUY) {
            // Sort orders in ascending order (lower price first)
            while (
                i > 1 &&
                ordersById[orderIds[i - 1]].desiredPrice >
                order.desiredPrice
            ) {
                orderIds[i] = orderIds[i - 1];
                i--;
            }
        } else {
            // Sort orders in descending order (higher price first)
            while (
                i > 1 &&
                ordersById[orderIds[i - 1]].desiredPrice <
                order.desiredPrice
            ) {
                orderIds[i] = orderIds[i - 1];
                i--;
            }
        }

        // Place the new order in the correct position
        orderIds[i] = orderId;
    }

    // We execute matched buy and sell orders one by one
    // This is called whenever new limit order is created, or can be called from backend intervally
    function executeLimitOrders(
        uint256 tokenId,
        OrderMetadata memory orderMetadata
    ) internal nonReentrant {
        // Clean invalid orders first
        removeInvalidOrdersFromLast(orderMetadata);

        // Fetch active buy and sell orders using order IDs
        uint256[] storage buyOrderIds = activeOrderIds[OrderType.BUY][
            orderMetadata.zone
        ][orderMetadata.physicalDelivery];
        uint256[] storage sellOrderIds = activeOrderIds[OrderType.SELL][
            orderMetadata.zone
        ][orderMetadata.physicalDelivery];

        // Ensure there are valid buy and sell orders
        if (buyOrderIds.length == 0 || sellOrderIds.length == 0) {
            return;
        }

        uint256 buyOrderId = buyOrderIds[buyOrderIds.length - 1]; // Get last buy order ID
        uint256 sellOrderId = sellOrderIds[sellOrderIds.length - 1]; // Get last sell order ID

        Order storage lastBuyOrder = ordersById[buyOrderId];
        Order storage lastSellOrder = ordersById[sellOrderId];

        if (lastBuyOrder.desiredPrice >= lastSellOrder.desiredPrice) {
            // Execute order if buy price >= sell price
            uint256 tokenAmount = lastBuyOrder.remainQuantity <=
                lastSellOrder.remainQuantity
                ? lastBuyOrder.remainQuantity
                : lastSellOrder.remainQuantity;

            uint256 sellerDesiredUsdcAmount = lastSellOrder.desiredPrice *
                tokenAmount;

            // Transfer USDC to seller
            (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                sellerDesiredUsdcAmount,
                OrderType.SELL
            );

            usdc.safeTransfer(lastSellOrder.trader, realAmount);

            if (feeAmount > 0) {
                usdc.safeTransfer(treasury, feeAmount);
            }

            // Deduct remaining USDC from buyer
            lastBuyOrder.remainUsdcValue -= sellerDesiredUsdcAmount;
            lastBuyOrder.remainQuantity -= tokenAmount;
            lastBuyOrder.lastTradeTimestamp = block.timestamp;

            // Transfer tokens to buyer
            (uint256 _realAmount, uint256 _feeAmount) = getAmountDeductFee(
                tokenAmount,
                OrderType.BUY
            );
            maisonEnergyToken.safeTransferFrom(
                address(this),
                lastBuyOrder.trader,
                tokenId,
                _realAmount,
                ""
            );
            if (_feeAmount > 0) {
                maisonEnergyToken.safeTransferFrom(
                    address(this),
                    treasury,
                    tokenId,
                    _feeAmount,
                    ""
                );
            }

            // Deduct remaining quantity from seller
            lastSellOrder.remainQuantity -= tokenAmount;
            lastSellOrder.lastTradeTimestamp = block.timestamp;

            emit TradeExecuted(
                tokenId,
                lastBuyOrder.id,
                lastSellOrder.id,
                lastBuyOrder.trader,
                lastSellOrder.trader,
                lastSellOrder.desiredPrice,
                tokenAmount
            );

            // Handle order fulfillment
            if (lastBuyOrder.remainQuantity == 0) {
                lastBuyOrder.isFilled = true;
                if (lastBuyOrder.remainUsdcValue > 0) {
                    usdc.safeTransfer(
                        lastBuyOrder.trader,
                        lastBuyOrder.remainUsdcValue
                    );
                    lastBuyOrder.remainUsdcValue = 0;
                }
                buyOrderIds.pop(); // Remove from active orders
            }

            if (lastSellOrder.remainQuantity == 0) {
                lastSellOrder.isFilled = true;
                sellOrderIds.pop(); // Remove from active orders
            }
        }
    }

    function isInvalidOrder(uint256 orderId) internal view returns (bool) {
        Order memory order = ordersById[orderId]; // Fetch order from storage
        return order.isCanceled || order.isFilled || order.remainQuantity == 0;
    }

    function removeInvalidOrdersFromLast(OrderMetadata memory orderMetadata) internal {
        uint256[] storage orderIds = activeOrderIds[orderMetadata.orderType][
            orderMetadata.zone
        ][orderMetadata.physicalDelivery];

        while (orderIds.length > 0) {
            uint256 lastOrderId = orderIds[orderIds.length - 1];

            if (!isInvalidOrder(lastOrderId)) {
                break; // Stop if the last order is valid
            }

            // Remove the last invalid order
            orderIds.pop();
            fullfilledOrderIds.push(lastOrderId);
        }
    }

    // Chainlink Automation checks this regularly
    function checkUpkeep(
        bytes calldata
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        Order[] memory activeSellOrders = getActiveOrdersByType(OrderType.SELL);

        for (uint256 i = 0; i < activeSellOrders.length; i++) {
            Order memory activeOrder = activeSellOrders[i];
            if (block.timestamp >= activeOrder.validTo) {
                return (true, abi.encode(activeOrder.id));
            }
        }
    }

    // Chainlink Automation executes this when checkUpkeep returns true
    function performUpkeep(bytes calldata performData) external override {
        uint256 orderId = abi.decode(performData, (uint256));

        _requestNoLiquiditySellOrder(orderId);
    }

    function _requestNoLiquiditySellOrder(uint256 orderId) internal {
        Order storage order = _getOrderById(orderId);
        order.isFilled = true;

        emit NoLiquiditySellOrderCreated(
            order.trader,
            order.remainQuantity,
            block.timestamp
        );
    }

    // function getLatestRate(
    //     CommonTypes.ZoneType zone,
    //     CommonTypes.PhysicalDeliveryType physicalDelivery
    // )
    //     external
    //     view
    //     returns (
    //         RecentOrder memory bestBidOrder,
    //         RecentOrder memory bestAskOrder
    //     )
    // {
    //     (uint256 realtimePrice, ) = priceOracle.getRealTimePrice(
    //         zone,
    //         physicalDelivery
    //     );

    //     Order[] memory activeBuyOrders = activeOrders[OrderType.BUY][zone][
    //         physicalDelivery
    //     ];
    //     Order[] memory activeSellOrders = activeOrders[OrderType.Sell][zone][
    //         physicalDelivery
    //     ];

    //     if (activeBuyOrders.length > 0) {
    //         Order memory order = activeBuyOrders[activeBuyOrders.length - 1];
    //         bestBidOrder = RecentOrder(
    //             realtimePrice * order.desiredPrice,
    //             order.desiredPrice,
    //             order.remainQuantity
    //         );
    //     }

    //     if (activeSellOrders.length > 0) {
    //         Order memory order = activeSellOrders[activeSellOrders.length - 1];
    //         bestAskOrder = RecentOrder(
    //             realtimePrice * order.desiredPrice,
    //             order.desiredPrice,
    //             order.remainQuantity
    //         );
    //     }
    // }

    // function orderBook(
    //     uint256 depth,
    //     OrderType orderType,
    //     CommonTypes.ZoneType zone,
    //     CommonTypes.PhysicalDeliveryType physicalDelivery
    // ) external view returns (uint256, Order[] memory) {
    //     (uint256 realtimePrice, ) = priceOracle.getRealTimePrice(
    //         zone,
    //         physicalDelivery
    //     );

    //     uint returnLength = depth;

    //     Order[] memory bestActiveOrders = new Order[](depth);
    //     Order[] memory totalActiveOrders = activeOrders[orderType][zone][
    //         physicalDelivery
    //     ];

    //     if (depth >= totalActiveOrders.length) {
    //         return (realtimePrice, totalActiveOrders);
    //     }

    //     for (
    //         uint256 i = totalActiveOrders.length - 1;
    //         i >= totalActiveOrders.length - depth;
    //         i--
    //     ) {
    //         bestActiveOrders[returnLength - 1] = totalActiveOrders[i];
    //         returnLength--;
    //     }

    //     return (realtimePrice, bestActiveOrders);
    // }

    // function _getOrderById(
    //     uint256 orderId
    // ) private view returns (Order storage) {
    //     require(orderId < nonce, "Invalid order id");

    //     for (uint256 orderType = 0; orderType < 2; orderType++) {
    //         for (uint256 zone = 0; zone < 4; zone++) {
    //             for (
    //                 uint256 physicalDelivery = 0;
    //                 physicalDelivery < 3;
    //                 physicalDelivery++
    //             ) {
    //                 Order[] storage totalActiveOrders = activeOrders[
    //                     OrderType(orderType)
    //                 ][CommonTypes.ZoneType(zone)][
    //                     CommonTypes.PhysicalDeliveryType(physicalDelivery)
    //                 ];
    //                 for (uint256 id = 0; id < totalActiveOrders.length; id++) {
    //                     Order storage order = totalActiveOrders[id];
    //                     if (orderId == order.id) {
    //                         return order;
    //                     }
    //                 }
    //             }
    //         }
    //     }

    //     for (uint256 i = 0; i < fullfilledOrders.length; i++) {
    //         Order storage order = fullfilledOrders[i];
    //         if (orderId == order.id) {
    //             return order;
    //         }
    //     }

    //     revert("Order not found");
    // }

    function _getOrderById(
        uint256 orderId
    ) private view returns (Order storage) {
        require(orderId < nonce, "Invalid order id");

        Order storage order = ordersById[orderId];
        require(order.id == orderId, "Order not found"); // Ensure order exists

        return order;
    }

    function getOrderById(
        uint256 orderId
    ) external view returns (Order memory) {
        return _getOrderById(orderId);
    }

    function getOrdersByUser(
        address user,
        bool status
    ) public view returns (Order[] memory) {
        uint256 totalOrders = ordersByUser[user].length;
        require(totalOrders > 0, "User did not make any order");

        Order[] memory userOrders = new Order[](totalOrders);
        uint256 count = 0;

        for (uint256 i = 0; i < totalOrders; i++) {
            Order memory order = ordersById[ordersByUser[user][i]];
            if (
                (status && !order.isFilled && !order.isCanceled) ||
                (!status && (order.isFilled || order.isCanceled))
            ) {
                userOrders[count] = order;
                count++;
            }
        }

        // Resize the array to the actual count
        assembly {
            mstore(userOrders, count)
        }

        return userOrders;
    }

    modifier onlyOrderMaker(uint256 orderId) {
        require(orderId < nonce, "Invalid order id");
        Order memory order = _getOrderById(orderId);
        require(
            order.trader == msg.sender,
            "You are not an maker of this order"
        );
        _;
    }

    function cancelOrder(uint256 orderId) external onlyOrderMaker(orderId) {
        Order storage order = _getOrderById(orderId);

        require(
            order.quantity > 0 && order.usdcAmount > 0,
            "Not a limit order"
        );
        require(!order.isCanceled, "Already canceled");
        require(!order.isFilled, "Order already filled");

        order.isCanceled = true;

        if (order.orderMetadata.orderType == OrderType.BUY) {
            usdc.safeTransfer(msg.sender, order.remainUsdcValue);
        } else {
            maisonEnergyToken.safeTransferFrom(
                address(this),
                msg.sender,
                order.tokenId,
                order.remainQuantity,
                ""
            );
        }

        emit OrderCanceled(order.id, block.timestamp);
    }

    function setFeeBips(
        uint256 _buyFeeBips,
        uint256 _sellFeeBips
    ) external onlyOwner {
        require(_buyFeeBips > 0 && _sellFeeBips > 0, "Invalid Fee");

        buyFeeBips = _buyFeeBips;
        sellFeeBips = _sellFeeBips;

        emit FeeUpdated(buyFeeBips, sellFeeBips);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid address");
        treasury = _treasury;

        emit TreasuryUpdated(treasury);
    }

    function getAmountDeductFee(
        uint256 amount,
        OrderType orderType
    ) internal view returns (uint256 realAmount, uint256 feeAmount) {
        uint256 feeBips = orderType == OrderType.BUY ? buyFeeBips : sellFeeBips;

        realAmount = (amount * (BASE_BIPS - feeBips)) / BASE_BIPS;
        feeAmount = amount - realAmount;
    }

    function getActiveOrdersByType(
        OrderType orderType
    ) public view returns (Order[] memory) {
        uint256 totalOrdersNum;

        // Count total valid orders first
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = 0; j < 3; j++) {
                // 3+1 to include all PhysicalDeliveryTypes
                totalOrdersNum += activeOrderIds[orderType][
                    CommonTypes.ZoneType(i)
                ][CommonTypes.PhysicalDeliveryType(j)].length;
            }
        }

        // Allocate memory for the result array
        Order[] memory activeOrders = new Order[](totalOrdersNum);
        uint256 index = 0;

        // Iterate and collect valid orders
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = 0; j < 3; j++) {
                Order[] memory orders = getActiveOrders(
                    orderType,
                    CommonTypes.ZoneType(i),
                    CommonTypes.PhysicalDeliveryType(j)
                );

                // Copy results into the activeOrders array
                for (uint256 k = 0; k < orders.length; k++) {
                    activeOrders[index++] = orders[k];
                }
            }
        }

        return activeOrders;
    }

    function getActiveOrders(
        OrderType orderType,
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery
    ) public view returns (Order[] memory) {
        uint256[] memory orderIds = activeOrderIds[orderType][zone][
            physicalDelivery
        ];
        uint256 totalOrders = orderIds.length;

        Order[] memory orders = new Order[](totalOrders);
        for (uint256 i = 0; i < totalOrders; i++) {
            orders[i] = ordersById[orderIds[i]];
        }

        return orders;
    }
}
