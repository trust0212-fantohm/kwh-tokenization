// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interface/IMaisonEnergyOrderBook.sol";
import "./MaisonEnergyToken.sol";
import "./library/CommonTypes.sol";

/**
 * @title MaisonEnergyOrderBook
 * @dev A decentralized order book for trading energy tokens with USDC
 * This contract implements an order book system for trading energy tokens with USDC,
 * supporting both market and limit orders with time-weighted matching.
 */
contract MaisonEnergyOrderBook is
    Initializable,
    ERC1155HolderUpgradeable,
    IMaisonEnergyOrderBook,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    AutomationCompatibleInterface
{
    using SafeERC20 for IERC20;

    uint256 private constant BASE_BIPS = 10000;
    uint256 private constant TOEKN_DECIMALS = 18;

    uint256 public nonce;
    uint256 public buyFeeBips;
    uint256 public sellFeeBips;
    uint256[] public fulfilledOrderIds;

    address public treasury;

    mapping(OrderType => mapping(CommonTypes.ZoneType => mapping(CommonTypes.PhysicalDeliveryType => uint256[])))
        public activeOrderIds;
    mapping(uint256 => Order) public ordersById;
    mapping(address => uint256[]) public ordersByUser; // Tracks order IDs by user

    // Promise-to-pay commitments
    struct PromiseToPay {
        address tokenHolder;
        uint256 tokenId;
        uint256 tokenAmount;
        uint256 usdcAmount;
        uint256 promiseTimestamp;
        bool isFulfilled;
    }
    mapping(uint256 => PromiseToPay) public promiseToPayCommitments;
    uint256 public promiseNonce;

    IERC20 public usdc;
    MaisonEnergyToken public maisonEnergyToken;

    /**
     * @dev Initializes the contract with necessary addresses and parameters
     * @param _treasury Address where fees will be sent
     * @param _usdcAddress Address of the USDC token contract
     * @param _maisonEnergyTokenAddress Address of the energy token contract
     */
    function initialize(
        address _treasury,
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
        usdc = IERC20(_usdcAddress);
        maisonEnergyToken = MaisonEnergyToken(_maisonEnergyTokenAddress);

        buyFeeBips = 500;
        sellFeeBips = 500;
        nonce = 0;
    }

    /**
     * @dev Creates a new buy market order that executes instantly
     * @param usdcAmount Amount of USDC to spend
     * @param tokenId ID of the energy token to buy
     * @param orderMetadata Metadata containing order type, zone, and delivery type
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
        require(usdcAmount > 0, "No USDC amount");

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        Order memory buyMarketOrder = Order({
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

        ordersById[nonce] = buyMarketOrder;
        ordersByUser[msg.sender].push(nonce);

        OrderMetadata memory sellMetadata = OrderMetadata({
            orderType: OrderType.SELL,
            zone: orderMetadata.zone,
            physicalDelivery: orderMetadata.physicalDelivery
        });

        Order[] memory activeSellOrders = getActiveOrders(sellMetadata);
        require(activeSellOrders.length > 0, "No active sell orders");

        uint256 totalTokens = 0;
        uint256 nowTime = block.timestamp;

        for (
            uint256 i = activeSellOrders.length;
            i > 0 && buyMarketOrder.remainUsdcAmount > 0;

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
                Order memory activeSellOrder = activeSellOrders[k];
                if (!isInvalidOrder(activeSellOrder.id)) {
                    uint256 w = nowTime - activeSellOrder.createdAt;
                    if (w == 0) w = 1;
                    totalWeight += w;
                }
            }

            // Apply time-weighted matching
            (
                uint256 tokenFilled,
                uint256 usdcUsed
            ) = distributeBuyOrderAcrossPriceLevel(
                    buyMarketOrder,
                    currentPrice,
                    start,
                    end,
                    totalWeight,
                    nowTime
                );

            totalTokens += tokenFilled;
            buyMarketOrder.remainUsdcAmount -= usdcUsed;

            i = start; // move to next price level
        }

        if (buyMarketOrder.remainUsdcAmount > 0) {
            // revert("Insufficient Token Supply");

            // If there are still USDC left, refund it back to the trader
            usdc.safeTransfer(
                buyMarketOrder.trader,
                buyMarketOrder.remainUsdcAmount
            );
        }

        fulfilledOrderIds.push(nonce);
        cleanLimitOrders(sellMetadata);

        (uint256 _realAmount, uint256 _feeAmount) = getAmountDeductFee(
            totalTokens,
            OrderType.BUY
        );
        maisonEnergyToken.safeTransferFrom(
            address(this),
            buyMarketOrder.trader,
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

        buyMarketOrder.lastTradeTimestamp = block.timestamp;

        nonce++;
    }

    /**
     * @dev Distributes a buy order across multiple sell orders at the same price level
     * @param buyOrder The buy order to distribute
     * @param currentPrice Current price level being processed
     * @param start Starting index in the sell orders array
     * @param end Ending index in the sell orders array
     * @param totalWeight Total time weight for this price level
     * @param nowTime Current block timestamp
     * @return tokenFilled Amount of tokens filled
     * @return usdcUsed Amount of USDC used
     */
    function distributeBuyOrderAcrossPriceLevel(
        Order memory buyOrder,
        uint256 currentPrice,
        uint256 start,
        uint256 end,
        uint256 totalWeight,
        uint256 nowTime
    ) internal returns (uint256 tokenFilled, uint256 usdcUsed) {
        OrderMetadata memory sellMetadata = OrderMetadata({
            orderType: OrderType.SELL,
            zone: buyOrder.orderMetadata.zone,
            physicalDelivery: buyOrder.orderMetadata.physicalDelivery
        });

        Order[] memory activeSellOrders = getActiveOrders(sellMetadata);

        uint256 remainUsdcAmount = buyOrder.remainUsdcAmount;
        uint256 remainTotalWeight = totalWeight;

        for (uint256 k = start; k < end && remainUsdcAmount > 0; k++) {
            Order memory activeSellOrder = activeSellOrders[k];
            if (isInvalidOrder(activeSellOrder.id)) continue;

            uint256 weight = nowTime - activeSellOrder.createdAt;
            if (weight == 0) weight = 1;

            uint256 usdcShare = (remainUsdcAmount * weight) / remainTotalWeight;
            uint256 tokenQty = (usdcShare * 10 ** TOEKN_DECIMALS) /
                currentPrice;

            if (tokenQty > activeSellOrder.remainTokenAmount) {
                tokenQty = activeSellOrder.remainTokenAmount;
                usdcShare = (tokenQty * currentPrice) / 10 ** TOEKN_DECIMALS;
            }

            (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                usdcShare,
                OrderType.SELL
            );
            usdc.safeTransfer(activeSellOrder.trader, realAmount);
            usdc.safeTransfer(treasury, feeAmount);

            activeSellOrder.remainTokenAmount -= tokenQty;
            activeSellOrder.lastTradeTimestamp = block.timestamp;

            if (activeSellOrder.remainTokenAmount == 0) {
                activeSellOrder.isFilled = true;
            }

            tokenFilled += tokenQty;
            usdcUsed += usdcShare;
            remainTotalWeight -= weight;
            remainUsdcAmount -= usdcShare;
        }
    }

    /**
     * @dev Creates a new sell market order that executes instantly
     * @param tokenAmount Amount of tokens to sell
     * @param tokenId ID of the energy token to sell
     * @param orderMetadata Metadata containing order type, zone, and delivery type
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
        require(tokenAmount > 0, "No Token Amount");

        maisonEnergyToken.safeTransferFrom(
            msg.sender,
            address(this),
            tokenId,
            tokenAmount,
            ""
        );

        Order memory sellMarketOrder = Order({
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

        ordersById[nonce] = sellMarketOrder;
        ordersByUser[msg.sender].push(nonce);

        OrderMetadata memory buyMetadata = OrderMetadata({
            orderType: OrderType.SELL,
            zone: orderMetadata.zone,
            physicalDelivery: orderMetadata.physicalDelivery
        });

        Order[] memory activeBuyOrders = getActiveOrders(buyMetadata);

        // If there are no active buy orders, create a promise-to-pay commitment
        if (activeBuyOrders.length == 0) {
            // Calculate the issuer address based on tokenId and other parameters
            address tokenIssuer = getTokenIssuerAddress(tokenId);

            // Create promise-to-pay commitment
            PromiseToPay memory commitment = PromiseToPay({
                tokenHolder: msg.sender,
                tokenId: tokenId,
                tokenAmount: tokenAmount,
                usdcAmount: 0, // Will be set when promise is fulfilled
                promiseTimestamp: block.timestamp,
                isFulfilled: false
            });

            promiseToPayCommitments[promiseNonce] = commitment;

            // Transfer tokens to the token issuer
            maisonEnergyToken.safeTransferFrom(
                address(this),
                tokenIssuer,
                tokenId,
                tokenAmount,
                ""
            );

            emit NoLiquiditySellOrderCreated(
                msg.sender,
                tokenAmount,
                block.timestamp
            );

            promiseNonce++;
            return;
        }

        uint256 totalUsdc = 0;
        uint256 nowTime = block.timestamp;

        for (
            uint256 i = activeBuyOrders.length;
            i > 0 && sellMarketOrder.remainTokenAmount > 0;

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
                uint256 tokenAmountUsed
            ) = distributeSellOrderAcrossPriceLevel(
                    sellMarketOrder,
                    currentPrice,
                    start,
                    end,
                    totalWeight,
                    nowTime
                );

            totalUsdc += usdcFilled;
            sellMarketOrder.remainTokenAmount -= tokenAmountUsed;

            i = start;
        }

        if (sellMarketOrder.remainTokenAmount > 0) {
            // Calculate the issuer address based on tokenId and other parameters
            address tokenIssuer = getTokenIssuerAddress(tokenId);

            // Create promise-to-pay commitment for remaining tokens
            PromiseToPay memory commitment = PromiseToPay({
                tokenHolder: sellMarketOrder.trader,
                tokenId: tokenId,
                tokenAmount: sellMarketOrder.remainTokenAmount,
                usdcAmount: 0, // Will be set when promise is fulfilled
                promiseTimestamp: block.timestamp,
                isFulfilled: false
            });

            promiseToPayCommitments[promiseNonce] = commitment;

            maisonEnergyToken.safeTransferFrom(
                address(this),
                tokenIssuer,
                tokenId,
                sellMarketOrder.remainTokenAmount,
                ""
            );

            emit NoLiquiditySellOrderCreated(
                sellMarketOrder.trader,
                sellMarketOrder.remainTokenAmount,
                block.timestamp
            );

            promiseNonce++;
        }

        fulfilledOrderIds.push(sellMarketOrder.id);
        cleanLimitOrders(buyMetadata);

        // Transfer USDC to seller
        (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
            totalUsdc,
            OrderType.SELL
        );
        usdc.safeTransfer(sellMarketOrder.trader, realAmount);
        usdc.safeTransfer(treasury, feeAmount);

        sellMarketOrder.lastTradeTimestamp = block.timestamp;

        nonce++;
    }

    /**
     * @dev Distributes a sell order across multiple buy orders at the same price level
     * @param sellOrder The sell order to distribute
     * @param currentPrice Current price level being processed
     * @param start Starting index in the buy orders array
     * @param end Ending index in the buy orders array
     * @param totalWeight Total time weight for this price level
     * @param nowTime Current block timestamp
     * @return usdcFilled Amount of USDC filled
     * @return tokenAmountUsed Amount of tokens used
     */
    function distributeSellOrderAcrossPriceLevel(
        Order memory sellOrder,
        uint256 currentPrice,
        uint256 start,
        uint256 end,
        uint256 totalWeight,
        uint256 nowTime
    ) internal returns (uint256 usdcFilled, uint256 tokenAmountUsed) {
        OrderMetadata memory buyMetadata = OrderMetadata({
            orderType: OrderType.BUY,
            zone: sellOrder.orderMetadata.zone,
            physicalDelivery: sellOrder.orderMetadata.physicalDelivery
        });

        Order[] memory activeBuyOrders = getActiveOrders(buyMetadata);

        uint256 remainTokenAmount = sellOrder.remainTokenAmount;
        uint256 remainTotalWeight = totalWeight;

        for (uint256 k = start; k < end && remainTokenAmount > 0; k++) {
            Order memory activeBuyOrder = activeBuyOrders[k];
            if (isInvalidOrder(activeBuyOrder.id)) continue;

            uint256 weight = nowTime - activeBuyOrder.createdAt;
            if (weight == 0) weight = 1;

            uint256 share = (remainTokenAmount * weight) / remainTotalWeight;
            if (share > activeBuyOrder.remainTokenAmount) {
                share = activeBuyOrder.remainTokenAmount;
            }

            uint256 usdcAmount = (share * currentPrice) / 10 ** TOEKN_DECIMALS;
            if (usdcAmount > activeBuyOrder.remainUsdcAmount) {
                usdcAmount = activeBuyOrder.remainUsdcAmount;
                share = (usdcAmount * 10 ** TOEKN_DECIMALS) / currentPrice;
            }

            (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                share,
                OrderType.BUY
            );
            maisonEnergyToken.safeTransferFrom(
                address(this),
                activeBuyOrder.trader,
                sellOrder.tokenId,
                realAmount,
                ""
            );
            maisonEnergyToken.safeTransferFrom(
                address(this),
                treasury,
                sellOrder.tokenId,
                feeAmount,
                ""
            );

            activeBuyOrder.remainUsdcAmount -= usdcAmount;
            activeBuyOrder.lastTradeTimestamp = block.timestamp;

            if (activeBuyOrder.remainTokenAmount == 0) {
                activeBuyOrder.isFilled = true;
            }

            usdcFilled += usdcAmount;
            tokenAmountUsed += share;
            remainTotalWeight -= weight;
            remainTokenAmount -= share;
        }
    }

    /**
     * @dev Creates a new limit order that may execute immediately or be placed in the order book
     * @param desiredPrice Price per token in USDC
     * @param tokenAmount Amount of tokens to trade
     * @param validTo Timestamp when the order expires
     * @param tokenId ID of the energy token
     * @param orderMetadata Metadata containing order type, zone, and delivery type
     */
    function createLimitOrder(
        uint256 desiredPrice,
        uint256 tokenAmount,
        uint256 validTo,
        uint256 tokenId,
        OrderMetadata memory orderMetadata
    ) external {
        require(validTo > block.timestamp, "Invalid time limit");

        uint256 usdcAmount;
        if (orderMetadata.orderType == OrderType.BUY) {
            usdcAmount = (desiredPrice * tokenAmount) / 10 ** TOEKN_DECIMALS;
            usdc.safeTransferFrom(
                msg.sender,
                address(this),
                (desiredPrice * tokenAmount) / 10 ** TOEKN_DECIMALS
            );
        } else {
            maisonEnergyToken.safeTransferFrom(
                msg.sender,
                address(this),
                tokenId,
                tokenAmount,
                ""
            );
        }

        Order memory newOrder = Order({
            id: nonce,
            trader: msg.sender,
            tokenId: tokenId,
            orderMetadata: orderMetadata,
            desiredPrice: desiredPrice,
            tokenAmount: tokenAmount,
            remainTokenAmount: tokenAmount,
            usdcAmount: usdcAmount,
            remainUsdcAmount: usdcAmount,
            isFilled: false,
            isMarketOrder: false,
            isCanceled: false,
            validTo: validTo,
            lastTradeTimestamp: 0,
            createdAt: block.timestamp
        });

        ordersById[nonce] = newOrder;
        ordersByUser[msg.sender].push(nonce);

        uint256 nowTime = block.timestamp;

        OrderMetadata memory buyMetadata = OrderMetadata({
            orderType: OrderType.BUY,
            zone: orderMetadata.zone,
            physicalDelivery: orderMetadata.physicalDelivery
        });

        OrderMetadata memory sellMetadata = OrderMetadata({
            orderType: OrderType.SELL,
            zone: orderMetadata.zone,
            physicalDelivery: orderMetadata.physicalDelivery
        });

        // Try to match with opposite orders at the same or better price
        if (orderMetadata.orderType == OrderType.BUY) {
            Order[] memory activeSellOrders = getActiveOrders(sellMetadata);

            // match with lowest priced sells ≤ desiredPrice
            for (
                uint256 i = activeSellOrders.length;
                i > 0 && newOrder.remainTokenAmount > 0;

            ) {
                Order memory sellOrder = activeSellOrders[i - 1];
                if (
                    isInvalidOrder(sellOrder.id) ||
                    sellOrder.desiredPrice > newOrder.desiredPrice
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
                        newOrder,
                        currentPrice,
                        j,
                        i,
                        totalWeight,
                        nowTime
                    );

                // Apply fees for the matched tokens
                (
                    uint256 realTokenAmount,
                    uint256 feeTokenAmount
                ) = getAmountDeductFee(tokenFilled, OrderType.BUY);

                maisonEnergyToken.safeTransferFrom(
                    address(this),
                    newOrder.trader,
                    tokenId,
                    realTokenAmount,
                    ""
                );
                maisonEnergyToken.safeTransferFrom(
                    address(this),
                    treasury,
                    tokenId,
                    feeTokenAmount,
                    ""
                );

                newOrder.remainUsdcAmount -= usdcUsed;

                i = j;
            }

            // If partially filled, insert the rest
            if (newOrder.remainTokenAmount > 0) {
                insertLimitOrder(newOrder.id);
                ordersById[nonce] = newOrder;
            } else {
                newOrder.isFilled = true;
                ordersById[nonce] = newOrder;
                fulfilledOrderIds.push(nonce);
            }
        } else {
            Order[] memory activeBuyOrders = getActiveOrders(buyMetadata);

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
                    uint256 usdcFilled,
                    uint256 tokenAmountUsed
                ) = distributeSellOrderAcrossPriceLevel(
                        newOrder,
                        currentPrice,
                        j,
                        i,
                        totalWeight,
                        nowTime
                    );

                // Apply fees for the matched USDC
                (
                    uint256 realUsdcAmount,
                    uint256 feeUsdcAmount
                ) = getAmountDeductFee(usdcFilled, OrderType.SELL);
                maisonEnergyToken.safeTransferFrom(
                    address(this),
                    newOrder.trader,
                    tokenId,
                    realUsdcAmount,
                    ""
                );
                maisonEnergyToken.safeTransferFrom(
                    address(this),
                    treasury,
                    tokenId,
                    feeUsdcAmount,
                    ""
                );

                newOrder.remainTokenAmount -= tokenAmountUsed;

                i = j;
            }

            // If partially filled, insert the rest
            if (newOrder.remainTokenAmount > 0) {
                insertLimitOrder(newOrder.id);
                ordersById[nonce] = newOrder;
            } else {
                newOrder.isFilled = true;
                ordersById[nonce] = newOrder;
                fulfilledOrderIds.push(newOrder.id);
            }
        }

        cleanLimitOrders(buyMetadata);
        cleanLimitOrders(sellMetadata);

        nonce++;
    }

    /**
     * @dev Cleans up invalid orders from the active order list
     * @param orderMetadata Metadata to identify which orders to clean
     */
    function cleanLimitOrders(OrderMetadata memory orderMetadata) internal {
        uint256[] storage orderIds = activeOrderIds[orderMetadata.orderType][
            orderMetadata.zone
        ][orderMetadata.physicalDelivery];
        uint256 writeIndex = 0;

        for (uint256 readIndex = 0; readIndex < orderIds.length; readIndex++) {
            if (!isInvalidOrder(ordersById[orderIds[readIndex]].id)) {
                if (writeIndex != readIndex) {
                    orderIds[writeIndex] = orderIds[readIndex];
                }
                writeIndex++;
            } else {
                fulfilledOrderIds.push(orderIds[readIndex]);
            }
        }

        while (orderIds.length > writeIndex) {
            orderIds.pop();
        }
    }

    /**
     * @dev Inserts a limit order into the correct position in the order book
     * @param orderId ID of the order to insert
     */
    function insertLimitOrder(uint256 orderId) internal {
        Order storage order = ordersById[orderId]; // Fetch order from storage

        uint256[] storage orderIds = activeOrderIds[
            order.orderMetadata.orderType
        ][order.orderMetadata.zone][order.orderMetadata.physicalDelivery];

        // Find the correct position to insert
        uint256 insertPosition = orderIds.length;

        if (order.orderMetadata.orderType == OrderType.BUY) {
            // For buy orders, find position where price is higher
            for (uint256 i = 0; i < orderIds.length; i++) {
                if (ordersById[orderIds[i]].desiredPrice > order.desiredPrice) {
                    insertPosition = i;
                    break;
                }
            }
        } else {
            // For sell orders, find position where price is lower
            for (uint256 i = 0; i < orderIds.length; i++) {
                if (ordersById[orderIds[i]].desiredPrice < order.desiredPrice) {
                    insertPosition = i;
                    break;
                }
            }
        }

        // Insert at the found position
        if (insertPosition == orderIds.length) {
            orderIds.push(orderId);
        } else {
            // Shift elements to make room
            orderIds.push(orderIds[orderIds.length - 1]);
            for (uint256 i = orderIds.length - 1; i > insertPosition; i--) {
                orderIds[i] = orderIds[i - 1];
            }
            orderIds[insertPosition] = orderId;
        }
    }

    /**
     * @dev Checks if an order is invalid (canceled, filled, or empty)
     * @param orderId ID of the order to check
     * @return bool True if the order is invalid
     */
    function isInvalidOrder(uint256 orderId) internal view returns (bool) {
        Order memory order = ordersById[orderId]; // Fetch order from storage
        return
            order.isCanceled || order.isFilled || order.remainTokenAmount == 0;
    }

    /**
     * @dev Chainlink Automation function to check if any orders need to be processed
     * @param checkData Additional data for the check (unused)
     * @return upkeepNeeded Whether upkeep is needed
     * @return performData Data to be used in performUpkeep if needed
     */
    function checkUpkeep(
        bytes calldata checkData
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

    /**
     * @dev Chainlink Automation function to process expired orders
     * @param performData Data containing the order ID to process
     */
    function performUpkeep(bytes calldata performData) external override {
        uint256 orderId = abi.decode(performData, (uint256));

        Order storage order = ordersById[orderId];
        order.isFilled = true;

        emit NoLiquiditySellOrderCreated(
            order.trader,
            order.remainTokenAmount,
            block.timestamp
        );
    }

    /**
     * @dev Modifier to ensure only the order maker can perform certain actions
     * @param orderId ID of the order to check
     */
    modifier onlyOrderMaker(uint256 orderId) {
        require(orderId < nonce, "Invalid order id");
        Order memory order = ordersById[orderId];
        require(
            order.trader == msg.sender,
            "You are not an maker of this order"
        );
        _;
    }

    /**
     * @dev Cancels an existing order
     * @param orderId ID of the order to cancel
     */
    function cancelOrder(uint256 orderId) external onlyOrderMaker(orderId) {
        Order storage order = ordersById[orderId];

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

    /**
     * @dev Sets the fee rates for buy and sell orders
     * @param _buyFeeBips Fee rate for buy orders in basis points
     * @param _sellFeeBips Fee rate for sell orders in basis points
     */
    function setFeeBips(
        uint256 _buyFeeBips,
        uint256 _sellFeeBips
    ) external onlyOwner {
        require(_buyFeeBips > 0 && _sellFeeBips > 0, "Invalid Fee");

        buyFeeBips = _buyFeeBips;
        sellFeeBips = _sellFeeBips;

        emit FeeUpdated(buyFeeBips, sellFeeBips);
    }

    /**
     * @dev Updates the treasury address
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid address");
        treasury = _treasury;

        emit TreasuryUpdated(treasury);
    }

    /**
     * @dev Calculates the real amount and fee amount after deducting fees
     * @param amount Original amount
     * @param orderType Type of order (BUY or SELL)
     * @return realAmount Amount after fee deduction
     * @return feeAmount Fee amount
     */
    function getAmountDeductFee(
        uint256 amount,
        OrderType orderType
    ) internal view returns (uint256 realAmount, uint256 feeAmount) {
        uint256 feeBips = orderType == OrderType.BUY ? buyFeeBips : sellFeeBips;

        realAmount = (amount * (BASE_BIPS - feeBips)) / BASE_BIPS;
        feeAmount = amount - realAmount;
    }

    /**
     * @dev Gets all active orders of a specific type
     * @param orderType Type of orders to retrieve (BUY or SELL)
     * @return Order[] Array of active orders
     */
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
                OrderMetadata memory orderMetadata = OrderMetadata({
                    orderType: orderType,
                    zone: CommonTypes.ZoneType(i),
                    physicalDelivery: CommonTypes.PhysicalDeliveryType(j)
                });
                Order[] memory orders = getActiveOrders(orderMetadata);

                // Copy results into the activeOrders array
                for (uint256 k = 0; k < orders.length; k++) {
                    activeOrders[index++] = orders[k];
                }
            }
        }

        return activeOrders;
    }

    /**
     * @dev Gets active orders matching specific metadata
     * @param orderMetadata Metadata to filter orders
     * @return Order[] Array of matching active orders
     */
    function getActiveOrders(
        OrderMetadata memory orderMetadata
    ) public view returns (Order[] memory) {
        uint256[] memory orderIds = activeOrderIds[orderMetadata.orderType][
            orderMetadata.zone
        ][orderMetadata.physicalDelivery];
        uint256 totalOrders = orderIds.length;

        Order[] memory orders = new Order[](totalOrders);
        for (uint256 i = 0; i < totalOrders; i++) {
            orders[i] = ordersById[orderIds[i]];
        }

        return orders;
    }

    /**
     * @dev Calculates the issuer address based on token ID
     * @param tokenId The token ID
     * @return The issuer address from the token details
     */
    function getTokenIssuerAddress(
        uint256 tokenId
    ) internal view returns (address) {
        address tokenIssuer = maisonEnergyToken.tokenIssuers(tokenId);
        return tokenIssuer;
    }

    /**
     * @dev Fulfills a promise-to-pay commitment by transferring USDC to the token holder
     * @param commitmentId ID of the promise-to-pay commitment
     * @param usdcAmount Amount of USDC to transfer
     */
    function fulfillPromiseToPay(
        uint256 commitmentId,
        uint256 usdcAmount
    ) external nonReentrant {
        PromiseToPay storage commitment = promiseToPayCommitments[commitmentId];
        require(commitment.tokenHolder != address(0), "Invalid commitment ID");
        require(!commitment.isFulfilled, "Commitment already fulfilled");
        require(
            block.timestamp >= commitment.promiseTimestamp + 24 hours,
            "24 hours not elapsed"
        );

        address tokenIssuer = getTokenIssuerAddress(commitment.tokenId);
        require(
            msg.sender == tokenIssuer,
            "Only issuer can fulfill commitment"
        );

        // Transfer USDC to token holder
        usdc.safeTransferFrom(msg.sender, commitment.tokenHolder, usdcAmount);

        // Update commitment
        commitment.usdcAmount = usdcAmount;
        commitment.isFulfilled = true;

        emit PromiseToPayFulfilled(
            commitmentId,
            commitment.tokenHolder,
            commitment.tokenId,
            commitment.tokenAmount,
            usdcAmount,
            block.timestamp
        );
    }
}
