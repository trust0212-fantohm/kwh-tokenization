// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./interface/IERCOTPriceOracle.sol";

/**
 * @title ERCOTPriceOracle
 * @dev A smart contract that stores and provides real-time and historical
 *      electricity prices for different ERCOT zones.
 */
contract ERCOTPriceOracle is IERCOTPriceOracle, AccessControlUpgradeable {
    // Mapping to store electricity prices per zone and timestamp
    mapping(CommonTypes.ZoneType => mapping(CommonTypes.PhysicalDeliveryType => mapping(uint256 => uint256)))
        private zonePrices;

    // Mapping to store the latest timestamp for each zone and delivery type
    mapping(CommonTypes.ZoneType => mapping(CommonTypes.PhysicalDeliveryType => uint256))
        private latestTimestamp;

    bytes32 public constant WRITER_ROLE = keccak256("WRITER_ROLE");

    error ZeroPriceNotAllowed();

    /**
     * @dev Constructor sets the contract deployer as the owner.
     */
    function initialize() public initializer {
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(WRITER_ROLE, msg.sender);
    }

    /**
     * @notice Fetches the latest price for a given ERCOT zone.
     * @dev Retrieves the most recent price stored for the zone and delivery type.
     * @param zone The ERCOT zone to get the real-time price for.
     * @param physicalDelivery The physical delivery type to get the price for.
     * @return The latest recorded price and its timestamp for the specified zone and delivery type.
     */
    function getRealTimePrice(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery
    ) external view returns (uint256, uint256) {
        uint256 timestamp = latestTimestamp[zone][physicalDelivery];
        if (timestamp == 0) {
            return (0, 0);
        }
        return (zonePrices[zone][physicalDelivery][timestamp], timestamp);
    }

    /**
     * @notice Fetches the historical price of a given zone at a specific timestamp.
     * @dev If no price exists for the exact timestamp, returns 0.
     * @param zone The ERCOT zone to get the historical price for.
     * @param physicalDelivery The physical delivery type to get the price for.
     * @param timestamp The specific timestamp to retrieve the price for.
     * @return The price recorded at the given timestamp and the timestamp itself.
     */
    function historicalPrice(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery,
        uint256 timestamp
    ) external view returns (uint256, uint256) {
        return (zonePrices[zone][physicalDelivery][timestamp], timestamp);
    }

    /**
     * @notice Updates the electricity price for a specific ERCOT zone.
     * @dev Only accounts with WRITER_ROLE can call this function.
     * @param zone The ERCOT zone where the price is being updated.
     * @param physicalDelivery The physical delivery type for which the price is being updated.
     * @param price The new price to be recorded.
     */
    function updatePrice(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery,
        uint256 price
    ) external onlyRole(WRITER_ROLE) {
        if (price == 0) revert ZeroPriceNotAllowed();

        // Store the price for the current timestamp
        uint256 currentTimestamp = block.timestamp;
        zonePrices[zone][physicalDelivery][currentTimestamp] = price;
        latestTimestamp[zone][physicalDelivery] = currentTimestamp;

        // Emit an event for external tracking
        emit PriceUpdated(zone, physicalDelivery, price, currentTimestamp);
    }

    /**
     * @notice Gets the latest timestamp for which a price was recorded.
     * @param zone The ERCOT zone to query.
     * @param physicalDelivery The physical delivery type to query.
     * @return The latest timestamp for which a price exists.
     */
    function getLatestTimestamp(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery
    ) external view returns (uint256) {
        return latestTimestamp[zone][physicalDelivery];
    }
}
