// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interface/IERCOTPriceOracle.sol";

/**
 * @title ERCOTPriceOracle
 * @dev A smart contract that stores and provides real-time and historical
 *      electricity prices for different ERCOT zones.
 */
contract ERCOTPriceOracle is IERCOTPriceOracle, AccessControl {
    // Mapping to store electricity prices per zone and timestamp
    mapping(CommonTypes.ZoneType => mapping(CommonTypes.PhysicalDeliveryType => mapping(uint256 => uint256)))
        private zonePrices;

    bytes32 public constant WRITER_ROLE = keccak256("WRITER_ROLE");

    /**
     * @dev Constructor sets the contract deployer as the owner.
     */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(WRITER_ROLE, msg.sender);
    }

    /**
     * @notice Fetches the latest price for a given ERCOT zone.
     * @dev Retrieves the price stored for the current block timestamp.
     * @param zone The ERCOT zone to get the real-time price for.
     * @return The latest recorded price for the specified zone.
     */
    function getRealTimePrice(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery
    ) external view returns (uint256, uint256) {
        return (
            zonePrices[zone][physicalDelivery][block.timestamp],
            block.timestamp
        );
    }

    /**
     * @notice Fetches the historical price of a given zone at a specific timestamp.
     * @param zone The ERCOT zone to get the historical price for.
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
     * @notice Updates the electricity price for a specific ERCOT zone at a given timestamp.
     * @dev Only the contract owner can call this function to update the price.
     * @param zone The ERCOT zone where the price is being updated.
     * @param price The new price to be recorded for the given zone and timestamp.
     */
    function updatePrice(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery,
        uint256 price
    ) external onlyRole(WRITER_ROLE) {
        // Store the price for the given zone and timestamp
        zonePrices[zone][physicalDelivery][block.timestamp] = price;

        // Emit an event for external tracking
        emit PriceUpdated(zone, physicalDelivery, price, block.timestamp);
    }
}
