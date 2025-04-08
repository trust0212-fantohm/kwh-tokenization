// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interface/IMaisonEnergyOrderBook.sol";
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

    uint256 private constant BASE_BIPS = 10000;
    uint256 private constant price_decimals = 18;

    uint256 public nonce;
    uint256 public buyFeeBips;
    uint256 public sellFeeBips;
    uint256[] public fullfilledOrderIds;

    address public treasury;
    address public insuranceAddress;

    mapping(OrderType => mapping(CommonTypes.ZoneType => mapping(CommonTypes.PhysicalDeliveryType => uint256[])))
        public activeOrderIds;
    mapping(uint256 => Order) private ordersById;
    mapping(address => uint256[]) private ordersByUser; // Tracks order IDs by user

    IERC20 public usdc;
    MaisonEnergyToken public maisonEnergyToken;

    function initialize(
        address _treasury,
        address _insuranceAddress,
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

        treasury = _treasury;
        insuranceAddress = _insuranceAddress;
        usdc = IERC20(_usdcAddress);
        maisonEnergyToken = MaisonEnergyToken(_maisonEnergyTokenAddress);

        buyFeeBips = 500;
        sellFeeBips = 500;
        nonce = 0;
    }

    /**
     * @dev Create new buy market order which will be executed instantly
     */

    function createBuyMarketOrder(
        uint256 usdcAmount,
        uint256 tokenId,
        OrderMetadata memory orderMetadata
    ) external nonReentrant {
        require(
            orderMetadata.orderType == OrderType.BUY,
            "Should be Buy Order"
        );
        require(usdcAmount > 0, "Insufficient USDC amount");

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        Order memory marketOrder = Order({
            id: nonce,
            trader: msg.sender,
            tokenId: tokenId,
            orderMetadata: orderMetadata,
            desiredPrice: 0,
            tokenAmount: 0,
            remainTokenAmount: 0,
            usdcAmount: usdcAmount,
            remainUsdcAmount: usdcAmount,
            isFilled: false,
            isCanceled: false,
            isMarketOrder: true,
            validTo: 0,
            lastTradeTimestamp: 0,
            createdAt: block.timestamp
        });

        nonce++;

        ordersById[nonce] = marketOrder;
        ordersByUser[msg.sender].push(nonce);

        Order[] memory activeSellOrders = getActiveOrders(
            OrderType.SELL,
            orderMetadata.zone,
            orderMetadata.physicalDelivery
        );
        require(activeSellOrders.length > 0, "No active sell orders");

        uint256 totalTokens = 0;
        uint256 nowTime = block.timestamp;

        for (
            uint256 i = activeSellOrders.length;
            i > 0 && marketOrder.remainUsdcAmount > 0;

        ) {
            uint256 currentPrice = activeSellOrders[i - 1].desiredPrice;
            uint256 j = i;

            while (
                j > 0 && activeSellOrders[j - 1].desiredPrice == currentPrice
            ) {
                j--;
            }

            uint256 start = j;
            uint256 end = i;

            // Compute total time weight for this price group
            uint256 totalWeight = 0;
            for (uint256 k = start; k < end; k++) {
                Order memory o = activeSellOrders[k];
                if (!isInvalidOrder(o.id)) {
                    uint256 w = nowTime - o.createdAt;
                    if (w == 0) w = 1;
                    totalWeight += w;
                }
            }

            // Apply time-weighted matching
            (
                uint256 tokenFilled,
                uint256 usdcUsed
            ) = distributeBuyOrderAcrossPriceLevel(
                    orderMetadata.zone,
                    orderMetadata.physicalDelivery,
                    marketOrder,
                    currentPrice,
                    start,
                    end,
                    totalWeight,
                    nowTime
                );

            totalTokens += tokenFilled;
            marketOrder.remainUsdcAmount -= usdcUsed;

            i = start; // move to next price level
        }

        if (marketOrder.remainUsdcAmount > 0) {
            revert("Insufficient Token Supply");
        }

        fullfilledOrderIds.push(marketOrder.id);
        cleanLimitOrders(orderMetadata.zone, orderMetadata.physicalDelivery);

        (uint256 _realAmount, uint256 _feeAmount) = getAmountDeductFee(
            totalTokens,
            OrderType.BUY
        );
        maisonEnergyToken.safeTransferFrom(
            address(this),
            msg.sender,
            tokenId,
            _realAmount,
            ""
        );
        maisonEnergyToken.safeTransferFrom(
            address(this),
            treasury,
            tokenId,
            _feeAmount,
            ""
        );
    }

    function distributeBuyOrderAcrossPriceLevel(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery,
        Order memory marketOrderMem,
        uint256 currentPrice,
        uint256 start,
        uint256 end,
        uint256 totalWeight,
        uint256 nowTime
    ) internal returns (uint256 tokenFilled, uint256 usdcUsed) {
        Order[] memory activeSellOrders = getActiveOrders(
            OrderType.SELL,
            zone,
            physicalDelivery
        );

        uint256 remainUsdcAmount = marketOrderMem.remainUsdcAmount;
        uint256 remainTotalWeight = totalWeight;

        for (uint256 k = start; k < end && remainUsdcAmount > 0; k++) {
            Order memory sellOrder = activeSellOrders[k];
            if (isInvalidOrder(sellOrder.id)) continue;

            uint256 weight = nowTime - sellOrder.createdAt;
            if (weight == 0) weight = 1;

            uint256 usdcShare = (remainUsdcAmount * weight) / remainTotalWeight;
            uint256 tokenQty = (usdcShare * 10 ** price_decimals) /
                currentPrice;

            if (tokenQty > sellOrder.remainTokenAmount) {
                tokenQty = sellOrder.remainTokenAmount;
                usdcShare = (tokenQty * currentPrice) / 10 ** price_decimals;
            }

            (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                usdcShare,
                OrderType.SELL
            );
            usdc.safeTransfer(sellOrder.trader, realAmount);
            usdc.safeTransfer(treasury, feeAmount);

            sellOrder.remainTokenAmount -= tokenQty;
            sellOrder.lastTradeTimestamp = block.timestamp;

            if (sellOrder.remainTokenAmount == 0) {
                sellOrder.isFilled = true;
            }

            tokenFilled += tokenQty;
            usdcUsed += usdcShare;
            remainTotalWeight -= weight;
            remainUsdcAmount -= usdcShare;
        }
    }

    /**
     * @dev Create new sell market order which will be executed instantly
     */

    function createSellMarketOrder(
        uint256 tokenAmount,
        uint256 tokenId,
        OrderMetadata memory orderMetadata
    ) external nonReentrant {
        require(
            orderMetadata.orderType == OrderType.SELL,
            "Should be Sell Order"
        );
        require(tokenAmount > 0, "Invalid Token Amount");

        maisonEnergyToken.safeTransferFrom(
            msg.sender,
            address(this),
            tokenId,
            tokenAmount,
            ""
        );

        Order memory marketOrder = Order({
            id: nonce,
            trader: msg.sender,
            tokenId: tokenId,
            orderMetadata: orderMetadata,
            desiredPrice: 0,
            tokenAmount: tokenAmount,
            remainTokenAmount: tokenAmount,
            usdcAmount: 0,
            remainUsdcAmount: 0,
            isMarketOrder: true,
            isCanceled: false,
            isFilled: false,
            validTo: 0,
            lastTradeTimestamp: 0,
            createdAt: block.timestamp
        });

        nonce++;

        ordersById[nonce] = marketOrder;
        ordersByUser[msg.sender].push(nonce);

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
                tokenAmount,
                ""
            );
            emit NoLiquiditySellOrderCreated(
                msg.sender,
                tokenAmount,
                block.timestamp
            );
            return;
        }

        uint256 totalUsdc = 0;
        uint256 nowTime = block.timestamp;

        for (
            uint256 i = activeBuyOrders.length;
            i > 0 && marketOrder.remainTokenAmount > 0;

        ) {
            uint256 currentPrice = activeBuyOrders[i - 1].desiredPrice;
            uint256 j = i;

            while (
                j > 0 && activeBuyOrders[j - 1].desiredPrice == currentPrice
            ) {
                j--;
            }

            uint256 start = j;
            uint256 end = i;

            // Compute total time weight for this price group
            uint256 totalWeight = 0;
            for (uint256 k = start; k < end; k++) {
                Order memory o = activeBuyOrders[k];
                if (!isInvalidOrder(o.id)) {
                    uint256 w = nowTime - o.createdAt;
                    if (w == 0) w = 1;
                    totalWeight += w;
                }
            }

            // Apply time-weighted matching
            (
                uint256 usdcFilled,
                uint256 quantityFilled
            ) = distributeSellOrderAcrossPriceLevel(
                    orderMetadata.zone,
                    orderMetadata.physicalDelivery,
                    marketOrder,
                    currentPrice,
                    start,
                    end,
                    totalWeight,
                    nowTime
                );

            totalUsdc += usdcFilled;
            marketOrder.remainTokenAmount -= quantityFilled;

            i = start;
        }

        if (marketOrder.remainTokenAmount > 0) {
            maisonEnergyToken.safeTransferFrom(
                address(this),
                insuranceAddress,
                tokenId,
                marketOrder.remainTokenAmount,
                ""
            );
            emit NoLiquiditySellOrderCreated(
                msg.sender,
                marketOrder.remainTokenAmount,
                block.timestamp
            );
        }

        fullfilledOrderIds.push(marketOrder.id);
        cleanLimitOrders(orderMetadata.zone, orderMetadata.physicalDelivery);

        // Transfer USDC to seller
        (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
            totalUsdc,
            OrderType.SELL
        );
        usdc.safeTransfer(marketOrder.trader, realAmount);
        usdc.safeTransfer(treasury, feeAmount);

        marketOrder.lastTradeTimestamp = block.timestamp;
    }

    function distributeSellOrderAcrossPriceLevel(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery,
        Order memory marketOrderMem,
        uint256 currentPrice,
        uint256 start,
        uint256 end,
        uint256 totalWeight,
        uint256 nowTime
    ) internal returns (uint256 usdcFilled, uint256 tokenAmountFilled) {
        Order[] memory activeBuyOrders = getActiveOrders(
            OrderType.BUY,
            zone,
            physicalDelivery
        );

        uint256 remainTokenAmount = marketOrderMem.remainTokenAmount;
        uint256 remainTotalWeight = totalWeight;

        for (uint256 k = start; k < end && remainTokenAmount > 0; k++) {
            Order memory buyOrder = activeBuyOrders[k];
            if (isInvalidOrder(buyOrder.id)) continue;

            uint256 weight = nowTime - buyOrder.createdAt;
            if (weight == 0) weight = 1;

            uint256 share = (remainTokenAmount * weight) / remainTotalWeight;
            if (share > buyOrder.remainTokenAmount) {
                share = buyOrder.remainTokenAmount;
            }

            uint256 usdcAmount = (share * currentPrice) / 10 ** price_decimals;
            if (usdcAmount > buyOrder.remainUsdcAmount) {
                usdcAmount = buyOrder.remainUsdcAmount;
                share = (usdcAmount * 10 ** price_decimals) / currentPrice;
            }

            (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                share,
                OrderType.BUY
            );
            maisonEnergyToken.safeTransferFrom(
                address(this),
                buyOrder.trader,
                marketOrderMem.tokenId,
                realAmount,
                ""
            );
            maisonEnergyToken.safeTransferFrom(
                address(this),
                treasury,
                marketOrderMem.tokenId,
                feeAmount,
                ""
            );

            buyOrder.remainTokenAmount -= share;
            buyOrder.remainUsdcAmount -= usdcAmount;
            buyOrder.lastTradeTimestamp = block.timestamp;

            if (buyOrder.remainTokenAmount == 0) {
                buyOrder.isFilled = true;
            }

            usdcFilled += usdcAmount;
            tokenAmountFilled += share;

            remainTotalWeight -= weight;
            remainTokenAmount -= share;
        }
    }

    function cleanLimitOrders(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery
    ) internal {
        Order[] memory activeBuyOrders = getActiveOrders(
            OrderType.BUY,
            zone,
            physicalDelivery
        );
        Order[] memory activeSellOrders = getActiveOrders(
            OrderType.SELL,
            zone,
            physicalDelivery
        );

        while (
            activeBuyOrders.length > 0 &&
            isInvalidOrder(activeBuyOrders[activeBuyOrders.length - 1].id)
        ) {
            removeLastFromBuyLimitOrder(zone, physicalDelivery);
        }
        while (
            activeSellOrders.length > 0 &&
            isInvalidOrder(activeSellOrders[activeSellOrders.length - 1].id)
        ) {
            removeLastFromSellLimitOrder(zone, physicalDelivery);
        }
    }

    function removeLastFromBuyLimitOrder(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery
    ) internal {
        Order[] memory activeBuyOrders = getActiveOrders(
            OrderType.BUY,
            zone,
            physicalDelivery
        );

        Order memory lastOrder = activeBuyOrders[activeBuyOrders.length - 1];

        (activeOrderIds[OrderType.BUY][zone][physicalDelivery]).pop();
        fullfilledOrderIds.push(lastOrder.id);
    }

    function removeLastFromSellLimitOrder(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery
    ) internal {
        Order[] memory activeSellOrders = getActiveOrders(
            OrderType.SELL,
            zone,
            physicalDelivery
        );

        Order memory lastOrder = activeSellOrders[activeSellOrders.length - 1];
        (activeOrderIds[OrderType.SELL][zone][physicalDelivery]).pop();
        fullfilledOrderIds.push(lastOrder.id);
    }

    /**
     * @dev Create new limit order
     */
    function createLimitOrder(
        uint256 desiredPrice,
        uint256 tokenAmount,
        uint256 validTo,
        uint256 tokenId,
        OrderMetadata memory orderMetadata
    ) external {
        uint256 usdcAmount = (desiredPrice * tokenAmount) /
            10 ** price_decimals;
        Order memory newOrder;

        require(validTo > block.timestamp, "Invalid time limit");

        if (orderMetadata.orderType == OrderType.BUY) {
            usdc.safeTransferFrom(
                msg.sender,
                address(this),
                desiredPrice * tokenAmount
            );
            newOrder = Order({
                id: nonce,
                trader: msg.sender,
                tokenId: tokenId,
                orderMetadata: orderMetadata,
                desiredPrice: desiredPrice,
                tokenAmount: tokenAmount,
                remainTokenAmount: tokenAmount,
                usdcAmount: usdcAmount,
                remainUsdcAmount: usdcAmount,
                isCanceled: false,
                isFilled: false,
                isMarketOrder: false,
                validTo: validTo,
                lastTradeTimestamp: 0,
                createdAt: block.timestamp
            });
        } else {
            maisonEnergyToken.safeTransferFrom(
                msg.sender,
                address(this),
                tokenId,
                tokenAmount,
                ""
            );
            newOrder = Order({
                id: nonce,
                trader: msg.sender,
                tokenId: tokenId,
                orderMetadata: orderMetadata,
                desiredPrice: desiredPrice,
                tokenAmount: tokenAmount,
                remainTokenAmount: tokenAmount,
                usdcAmount: 0,
                remainUsdcAmount: 0,
                isCanceled: false,
                isFilled: false,
                isMarketOrder: false,
                validTo: validTo,
                lastTradeTimestamp: 0,
                createdAt: block.timestamp
            });
        }

        nonce++;
        ordersById[nonce] = newOrder;
        ordersByUser[msg.sender].push(nonce);

        uint256 nowTime = block.timestamp;

        // Try to match with opposite orders at the same or better price
        if (orderMetadata.orderType == OrderType.BUY) {
            Order[] memory activeSellOrders = getActiveOrders(
                OrderType.SELL,
                orderMetadata.zone,
                orderMetadata.physicalDelivery
            );

            // match with lowest priced sells ≤ desiredPrice
            for (
                uint256 i = activeSellOrders.length;
                i > 0 && newOrder.remainTokenAmount > 0;

            ) {
                Order memory sellOrder = activeSellOrders[i - 1];
                if (
                    isInvalidOrder(sellOrder.id) ||
                    sellOrder.desiredPrice > desiredPrice
                ) {
                    i--;
                    continue;
                }

                // Find price group
                uint256 currentPrice = sellOrder.desiredPrice;
                uint256 j = i;
                while (
                    j > 0 &&
                    activeSellOrders[j - 1].desiredPrice == currentPrice
                ) {
                    j--;
                }

                // Weight calc
                uint256 totalWeight = 0;
                for (uint256 k = j; k < i; k++) {
                    Order memory o = activeSellOrders[k];
                    if (!isInvalidOrder(o.id)) {
                        uint256 w = nowTime - o.createdAt;
                        if (w == 0) w = 1;
                        totalWeight += w;
                    }
                }

                // Time-weighted distribution
                (
                    uint256 tokenFilled,
                    uint256 usdcUsed
                ) = distributeBuyOrderAcrossPriceLevel(
                        orderMetadata.zone,
                        orderMetadata.physicalDelivery,
                        newOrder,
                        currentPrice,
                        j,
                        i,
                        totalWeight,
                        nowTime
                    );

                newOrder.remainTokenAmount -= tokenFilled;
                newOrder.remainUsdcAmount -= usdcUsed;

                i = j;
            }

            // If partially filled, insert the rest
            if (newOrder.remainTokenAmount > 0) {
                insertLimitOrder(newOrder.id);
            } else {
                ordersById[nonce] = newOrder;
                fullfilledOrderIds.push(newOrder.id);
            }
        } else {
            Order[] memory activeBuyOrders = getActiveOrders(
                OrderType.BUY,
                orderMetadata.zone,
                orderMetadata.physicalDelivery
            );

            // SELL order — match with highest priced buys ≥ desiredPrice
            for (
                uint256 i = activeBuyOrders.length;
                i > 0 && newOrder.remainTokenAmount > 0;

            ) {
                Order memory buyOrder = activeBuyOrders[i - 1];

                if (
                    isInvalidOrder(buyOrder.id) ||
                    buyOrder.desiredPrice < desiredPrice
                ) {
                    i--;
                    continue;
                }

                uint256 currentPrice = buyOrder.desiredPrice;
                uint256 j = i;
                while (
                    j > 0 && activeBuyOrders[j - 1].desiredPrice == currentPrice
                ) {
                    j--;
                }

                uint256 totalWeight = 0;
                for (uint256 k = j; k < i; k++) {
                    Order memory o = activeBuyOrders[k];
                    if (!isInvalidOrder(o.id)) {
                        uint256 w = nowTime - o.createdAt;
                        if (w == 0) w = 1;
                        totalWeight += w;
                    }
                }

                // Time-weighted distribution
                (
                    ,
                    uint256 tokenAmountFilled
                ) = distributeSellOrderAcrossPriceLevel(
                        orderMetadata.zone,
                        orderMetadata.physicalDelivery,
                        newOrder,
                        currentPrice,
                        j,
                        i,
                        totalWeight,
                        nowTime
                    );

                newOrder.remainTokenAmount -= tokenAmountFilled;
                // newOrder.remainUsdcAmount -= usdcFilled;

                i = j;
            }

            // If partially filled, insert the rest
            if (newOrder.remainTokenAmount > 0) {
                insertLimitOrder(newOrder.id);
            } else {
                ordersById[nonce] = newOrder;
                fullfilledOrderIds.push(newOrder.id);
            }
        }

        cleanLimitOrders(orderMetadata.zone, orderMetadata.physicalDelivery);
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
                ordersById[orderIds[i - 1]].desiredPrice > order.desiredPrice
            ) {
                orderIds[i] = orderIds[i - 1];
                i--;
            }
        } else {
            // Sort orders in descending order (higher price first)
            while (
                i > 1 &&
                ordersById[orderIds[i - 1]].desiredPrice < order.desiredPrice
            ) {
                orderIds[i] = orderIds[i - 1];
                i--;
            }
        }

        // Place the new order in the correct position
        orderIds[i] = orderId;
    }

    function isInvalidOrder(uint256 orderId) internal view returns (bool) {
        Order memory order = ordersById[orderId]; // Fetch order from storage
        return
            order.isCanceled || order.isFilled || order.remainTokenAmount == 0;
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

        Order storage order = _getOrderById(orderId);
        order.isFilled = true;

        emit NoLiquiditySellOrderCreated(
            order.trader,
            order.remainTokenAmount,
            block.timestamp
        );
    }

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
            order.tokenAmount > 0 && order.usdcAmount > 0,
            "Not a limit order"
        );
        require(!order.isCanceled, "Already canceled");
        require(!order.isFilled, "Order already filled");

        order.isCanceled = true;

        if (order.orderMetadata.orderType == OrderType.BUY) {
            usdc.safeTransfer(msg.sender, order.remainUsdcAmount);
        } else {
            maisonEnergyToken.safeTransferFrom(
                address(this),
                msg.sender,
                order.tokenId,
                order.remainTokenAmount,
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
