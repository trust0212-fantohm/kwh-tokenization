// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MaisonEnergyToken
 * @notice A sophisticated ERC1155 token contract for managing energy tokens in the ERCOT market
 * 
 * This contract implements a comprehensive system for:
 * - Minting and managing energy tokens with specific attributes (zone, delivery type, fuel type)
 * - Tracking token expiration and settlement
 * - Managing issuer collateral and defaults
 * - Handling physical delivery settlements
 * - Providing detailed metrics for both issuers and token holders
 * 
 * Key Features:
 * - Role-based access control (ISSUER_ROLE, BACKEND_ROLE)
 * - Automated token expiration through Chainlink Automation
 * - Collateral management with USDC
 * - Default handling and settlement mechanisms
 * - Comprehensive metrics tracking for issuers and representatives
 * - Support for different energy attributes (zone, delivery type, fuel type)
 * 
 * The contract maintains detailed records of:
 * - Token issuance and redemption
 * - Issuer performance and defaults
 * - Token expiration and settlement
 * - Physical delivery settlements
 * - Various metrics for monitoring and analysis
 * 
 * @dev This contract uses OpenZeppelin's ERC1155, AccessControl, and ReentrancyGuard
 * @dev Implements Chainlink Automation for automated token expiration
 * @dev Uses USDC for collateral and settlement
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import "./interface/IMaisonEnergyToken.sol";
import "./interface/IERCOTPriceOracle.sol";
import "./library/CommonTypes.sol";

contract MaisonEnergyToken is
    IMaisonEnergyToken,
    ERC1155Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    AutomationCompatibleInterface
{
    using SafeERC20 for IERC20;

    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    uint256 private constant BASE_BIPS = 10000;
    uint256 public NumKindsOfToken;

    address public insuranceAddress;

    enum IssuerStatus {
        Active,
        Frozen,
        Inactive
    }

    struct IssuerData {
        uint256 collateralBips;
        uint256 totalDefaults;
        uint256 pendingPromiseToPayAmounts;
        uint256 pendingPromiseToPayDefaultHonored;
        uint256 pendingPromiseToPayDefault;
    }

    struct TokenMetrics {
        uint256 totalSoldVolumeKwh;
        uint256 totalSoldVolumeDollar;
        TokenDetail tokenDetail;
    }

    struct TokenDetail {
        address issuer;
        uint256 embeddedValue;
        uint256 validFrom;
        uint256 validTo;
        uint256 totalMintedToken;
        uint256 totalSupply;
        uint256 totalRedeemed;
        uint256 totalDestroyed;
        string ercotSupplyId;
        bool isExpired;
        EnergyAttributes energyAttributes;
    }

    struct EnergyAttributes {
        CommonTypes.ZoneType zone;
        CommonTypes.PhysicalDeliveryType physicalDelivery;
        uint256 physicalDeliveryHours;
        CommonTypes.PhysicalDeliveryDays physicalDeliveryDays;
        CommonTypes.FuelType fuelType;
    }

    mapping(uint256 => address) public tokenIssuers;
    mapping(uint256 => TokenDetail) public tokenDetails;
    mapping(address => uint256) public redeemedTokensForUser;
    mapping(address => IssuerData) public issuerMetrics;
    mapping(address => uint256[]) public tokenIdsForIssuer;
    mapping(address => mapping(uint256 => bool))
        public hasIssuerPendingPromiseToPay;
    mapping(uint256 => uint8) public retryAttempts;
    mapping(address => mapping(uint256 => bool))
        public isIssuerDefaultedForToken;

    IERCOTPriceOracle public priceOracle;
    IERC20 public usdc;

    struct IssuerMetrics {
        uint256 score;
        IssuerStatus status;
        uint256 totalKwhMinted;
        uint256 totalVolumeSoldKwh;
        uint256 totalVolumeSoldDollar;
        uint256 totalActiveTokens;
        uint256 totalExpiredTokens;
        uint256 tokensExpiringIn1;
        uint256 tokensExpiringIn2;
        uint256 tokensExpiringIn3;
        uint256 tokensExpiringIn4;
        uint256 tokensExpiringIn5;
        uint256 tokensExpiringIn6;
        uint256 tokensExpiringIn12;
        uint256 tokensExpiringIn24;
        uint256 tokensExpiringIn36;
        uint256 settledForPhysicalDelivery;
        uint256 settledOnExpirationVolumeKwh;
        uint256 settledOnExpirationVolumeDollar;
        uint256 tokensDestroyed;
        uint256 pendingPromiseToPay;
        uint256 pendingPromiseToPayDefault;
        uint256 pendingPromiseToPayDefaultHonored;
        uint256 minTimeToHonorDefaults;
        uint256 maxTimeToHonorDefaults;
    }

    /**
     * @notice Initializes the contract with required addresses and sets up initial roles
     * @param _priceOracleAddress Address of the ERCOT price oracle contract
     * @param _insuranceAddress Address where collateral will be sent
     * @param _usdcAddress Address of the USDC token contract
     */
    function initialize(
        address _priceOracleAddress,
        address _insuranceAddress,
        address _usdcAddress
    ) public initializer {
        __ERC1155_init("https://maisonenergy.com/metadata/{id}.json");
        __AccessControl_init();
        __ReentrancyGuard_init();

        require(_usdcAddress != address(0), "Invalid usdc address");
        require(_insuranceAddress != address(0), "Invalid insurance address");
        require(
            _priceOracleAddress != address(0),
            "Invalid priceoracle address"
        );

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ISSUER_ROLE, msg.sender);
        // _grantRole(REP_ROLE, msg.sender);

        priceOracle = IERCOTPriceOracle(_priceOracleAddress);
        usdc = IERC20(_usdcAddress);
        insuranceAddress = _insuranceAddress;
    }

    /**
     * @notice Mints new energy tokens with specified attributes
     * @param amount Amount of tokens to mint
     * @param embeddedValue Embedded value of the token
     * @param validFrom Timestamp when the token becomes valid
     * @param validTo Timestamp when the token expires
     * @param ercotSupplyId ERCOT supply identifier
     * @param energyAttributes Energy attributes including zone and physical delivery details
     */
    function mint(
        uint256 amount,
        uint256 embeddedValue,
        uint256 validFrom,
        uint256 validTo,
        string memory ercotSupplyId,
        EnergyAttributes memory energyAttributes
    ) external onlyRole(ISSUER_ROLE) {
        require(!hasDebt(msg.sender), "You are in default.");
        require(
            !hasPendingPromiseToPay(msg.sender),
            "You have pending promise-to-pay."
        );
        require(
            validFrom > block.timestamp && validTo > validFrom,
            "Invalid timestamp"
        );

        (uint256 realtimePrice, ) = priceOracle.getRealTimePrice(
            energyAttributes.zone,
            energyAttributes.physicalDelivery
        );

        // Calculate USDC value (convert from 18 decimals to 6 decimals)
        uint256 usdcValue = (amount * realtimePrice) / 10 ** 30;

        if (tokenIdsForIssuer[msg.sender].length == 0) {
            issuerMetrics[msg.sender].collateralBips = 100;
        }

        // Send collateral to insurance address
        uint256 collateralAmount = (usdcValue *
            issuerMetrics[msg.sender].collateralBips) / BASE_BIPS;
        usdc.safeTransferFrom(msg.sender, insuranceAddress, collateralAmount);

        uint256 id = NumKindsOfToken;
        tokenIssuers[id] =  msg.sender;
        tokenDetails[id] = TokenDetail(
            msg.sender,
            embeddedValue,
            validFrom,
            validTo,
            amount,
            amount,
            0,
            0,
            ercotSupplyId,
            false,
            energyAttributes
        );

        _mint(msg.sender, id, amount, "");

        tokenIdsForIssuer[msg.sender].push(id);

        NumKindsOfToken++;

        emit TokenMinted(msg.sender, id, amount);
    }

    modifier onlyIssuer(uint256 id) {
        require(id < NumKindsOfToken, "Invalid token id");
        TokenDetail memory token = tokenDetails[id];
        require(
            msg.sender == token.issuer,
            "You are not an issuer of this token"
        );
        _;
    }

    /**
     * @notice Allows token issuer to destroy their own tokens
     * @param amount Amount of tokens to destroy
     * @param id Token ID to destroy
     */
    function destroy(uint256 amount, uint256 id) external onlyIssuer(id) {
        TokenDetail storage token = tokenDetails[id];

        require(
            !isIssuerDefaultedForToken[token.issuer][id],
            "You are in default for this token."
        );
        require(
            !hasIssuerPendingPromiseToPay[msg.sender][id],
            "You have outstanding settlements."
        );
        require(
            balanceOf(msg.sender, id) >= amount,
            "You don't have enough token to destroy"
        );

        _burn(msg.sender, id, amount);

        token.totalSupply -= amount;
        token.totalDestroyed += amount;

        emit TokenDestroyed(msg.sender, id, amount);
    }

    /**
     * @notice Allows users to redeem their energy tokens
     * @param id Token ID to redeem
     * @param amount Amount of tokens to redeem
     */
    function redeem(uint256 id, uint256 amount) external {
        TokenDetail storage token = tokenDetails[id];

        require(msg.sender != token.issuer, "You are an issuer of this token");
        require(!token.isExpired, "Token expired");
        require(
            balanceOf(msg.sender, id) >= amount,
            "You don't have enough token to redeem"
        );

        safeTransferFrom(msg.sender, token.issuer, id, amount, "");
        // _burn(msg.sender, id, amount);
        redeemedTokensForUser[msg.sender] += amount;
        token.totalSupply -= amount;
        token.totalRedeemed += amount;

        emit Redeemed(msg.sender, id, amount, block.timestamp);
    }

    /**
     * @notice Chainlink Automation function to check if any tokens need expiration
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
        for (uint256 id = 0; id < NumKindsOfToken; id++) {
            TokenDetail memory token = tokenDetails[id];
            if (block.timestamp >= token.validTo - 1 days && !token.isExpired) {
                return (true, abi.encode(id));
            }
        }
        return (false, "");
    }

    /**
     * @notice Chainlink Automation function to perform token expiration
     * @param performData Data containing the token ID to expire
     */
    function performUpkeep(bytes calldata performData) external override {
        uint256 id = abi.decode(performData, (uint256));
        TokenDetail storage token = tokenDetails[id];

        require(!token.isExpired, "Token already expired");
        token.isExpired = true;
        emit TokenExpirationRequested(id, block.timestamp);
    }

    /**
     * @notice Backend function to settle debts for expired tokens
     * @param id Token ID to settle debts for
     * @param tokenHolders Array of token holders who are owed settlement
     * @param amountOwed Array of amounts owed to each token holder
     */
    function settleDebtsForExpiration(
        uint256 id,
        address[] memory tokenHolders,
        uint256[] memory amountOwed
    ) external onlyRole(BACKEND_ROLE) {
        require(tokenHolders.length == amountOwed.length, "Invalid input");
        require(tokenDetails[id].isExpired, "Token not expired yet");
        require(retryAttempts[id] < 3, "Can't not be called over 3 times");
        require(
            !hasIssuerPendingPromiseToPay[tokenDetails[id].issuer][id] &&
                !isIssuerDefaultedForToken[tokenDetails[id].issuer][id],
            "All debts are settled"
        );

        TokenDetail storage token = tokenDetails[id];
        bool allSettled = true;

        // Attempt settlement
        for (uint256 i = 0; i < tokenHolders.length; i++) {
            if (amountOwed[i] > 0) {
                bool success = usdc.transferFrom(
                    token.issuer,
                    tokenHolders[i],
                    amountOwed[i]
                );

                if (success) {
                    emit Settled(id, tokenHolders[i], amountOwed[i]);
                } else {
                    emit SettlementFailed(id, tokenHolders[i], amountOwed[i]);
                    allSettled = false;
                }
            }
        }

        // If everything settled, clear debts and reset flags
        if (allSettled) {
            isIssuerDefaultedForToken[token.issuer][id] = false;
            hasIssuerPendingPromiseToPay[token.issuer][id] = false;
            emit SettledAllDebts(id);
        } else {
            // If retry attempts exceed limit, mark issuer as defaulted
            retryAttempts[id]++;
            if (retryAttempts[id] >= 3) {
                isIssuerDefaultedForToken[token.issuer][id] = true;
                emit TokenIssuerMarkedAsDefault(id);
            }
            hasIssuerPendingPromiseToPay[token.issuer][id] = true;
        }
    }

    /**
     * @notice Allows issuer to manually settle debts for expired tokens
     * @param id Token ID to settle debts for
     * @param tokenHolders Array of token holders who are owed settlement
     * @param amountOwed Array of amounts owed to each token holder
     */
    function manualSettle(
        uint256 id,
        address[] memory tokenHolders,
        uint256[] memory amountOwed
    ) external onlyIssuer(id) {
        require(tokenDetails[id].isExpired, "Token not expired yet");
        require(tokenHolders.length == amountOwed.length, "Invalid input");

        bool allSettled = true;

        for (uint256 i = 0; i < tokenHolders.length; i++) {
            // Ensure the amount does not exceed what's owed
            bool success = usdc.transferFrom(
                msg.sender, // The issuer manually settles the debt
                tokenHolders[i],
                amountOwed[i]
            );

            if (success) {
                emit Settled(id, tokenHolders[i], amountOwed[i]);
            } else {
                emit SettlementFailed(id, tokenHolders[i], amountOwed[i]);
                allSettled = false;
            }
        }

        // If this was the second retry and still unpaid holders exist, mark token as defaulted
        if (allSettled) {
            isIssuerDefaultedForToken[tokenDetails[id].issuer][id] = false;
            hasIssuerPendingPromiseToPay[tokenDetails[id].issuer][id] = false;
            emit SettledAllDebts(id);
        } else {
            hasIssuerPendingPromiseToPay[tokenDetails[id].issuer][id] = true;
        }
    }

    /**
     * @notice Returns token metrics including volume and details
     * @param id Token ID to get metrics for
     * @return TokenMetrics struct containing token statistics
     */
    function getTokenMetrics(
        uint256 id
    ) public view returns (TokenMetrics memory) {
        require(id <= NumKindsOfToken, "Invalid mint ID");

        TokenDetail memory token = tokenDetails[id];

        (uint256 realtimePrice, ) = priceOracle.getRealTimePrice(
            token.energyAttributes.zone,
            token.energyAttributes.physicalDelivery
        );

        uint256 totalSoldVolumeKwh = token.totalMintedToken -
            balanceOf(token.issuer, id) -
            token.totalDestroyed;
        uint256 totalSoldVolumeDollar = totalSoldVolumeKwh * realtimePrice;

        return
            TokenMetrics({
                totalSoldVolumeKwh: totalSoldVolumeKwh,
                totalSoldVolumeDollar: totalSoldVolumeDollar,
                tokenDetail: token
            });
    }

    /**
     * @notice Returns metrics for a representative address
     * @param repAddress Address of the representative
     * @return totalRedeemed Total number of tokens redeemed by the representative
     * @return totalAllocated Total number of tokens currently allocated to the representative
     * @return tokensExpiringIn1 Number of tokens expiring in 1 month
     * @return tokensExpiringIn2 Number of tokens expiring in 2 months
     * @return tokensExpiringIn3 Number of tokens expiring in 3 months
     * @return tokensExpiringIn4 Number of tokens expiring in 4 months
     * @return tokensExpiringIn5 Number of tokens expiring in 5 months
     * @return tokensExpiringIn6 Number of tokens expiring in 6 months
     * @return tokensExpiringIn12 Number of tokens expiring in 12 months
     * @return tokensExpiringIn24 Number of tokens expiring in 24 months
     * @return tokensExpiringIn36 Number of tokens expiring in 36 months
     */
    function getRepMetrics(
        address repAddress
    )
        public
        view
        returns (
            uint256 totalRedeemed,
            uint256 totalAllocated,
            uint256 tokensExpiringIn1,
            uint256 tokensExpiringIn2,
            uint256 tokensExpiringIn3,
            uint256 tokensExpiringIn4,
            uint256 tokensExpiringIn5,
            uint256 tokensExpiringIn6,
            uint256 tokensExpiringIn12,
            uint256 tokensExpiringIn24,
            uint256 tokensExpiringIn36
        )
    {
        totalRedeemed = redeemedTokensForUser[repAddress];

        for (uint256 id = 0; id < NumKindsOfToken; id++) {
            uint256 balance = balanceOf(repAddress, id);
            totalAllocated += balance;
            TokenDetail memory token = tokenDetails[id];

            if (!token.isExpired) {
                uint256 timeToExpiry = token.validTo - block.timestamp;
                if (timeToExpiry <= 30 days) {
                    tokensExpiringIn1 = balance;
                } else if (timeToExpiry <= 60 days) {
                    tokensExpiringIn2 = balance;
                } else if (timeToExpiry <= 90 days) {
                    tokensExpiringIn3 = balance;
                } else if (timeToExpiry <= 120 days) {
                    tokensExpiringIn4 = balance;
                } else if (timeToExpiry <= 150 days) {
                    tokensExpiringIn5 = balance;
                } else if (timeToExpiry <= 180 days) {
                    tokensExpiringIn6 = balance;
                } else if (timeToExpiry <= 365 days) {
                    tokensExpiringIn12 = balance;
                } else if (timeToExpiry <= 730 days) {
                    tokensExpiringIn24 = balance;
                } else if (timeToExpiry <= 1095 days) {
                    tokensExpiringIn36 = balance;
                }
            }
        }
    }

    /**
     * @notice Checks if an issuer has any outstanding debts
     * @param issuer Address of the issuer to check
     * @return bool Whether the issuer has any debts
     */
    function hasDebt(address issuer) public view returns (bool) {
        uint256[] memory issuerTokens = tokenIdsForIssuer[issuer];

        for (uint256 i = 0; i < issuerTokens.length; i++) {
            uint256 tokenId = issuerTokens[i];

            if (isIssuerDefaultedForToken[issuer][tokenId]) {
                return true; // Issuer has debt for at least one token
            }
        }
        return false; // No debts found
    }

    /**
     * @notice Checks if an issuer has any pending promise-to-pay
     * @param issuer Address of the issuer to check
     * @return bool Whether the issuer has any pending promise-to-pay
     */
    function hasPendingPromiseToPay(address issuer) public view returns (bool) {
        uint256[] memory issuerTokens = tokenIdsForIssuer[issuer];

        for (uint256 i = 0; i < issuerTokens.length; i++) {
            uint256 tokenId = issuerTokens[i];

            if (hasIssuerPendingPromiseToPay[issuer][tokenId]) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice ERC165 interface support check
     * @param interfaceId Interface ID to check
     * @return bool Whether the contract supports the given interface
     */
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @notice Returns comprehensive metrics for an issuer
     * @param issuerAddress Address of the issuer to get metrics for
     * @return IssuerMetrics struct containing all issuer statistics
     */
    function getIssuerMetrics(
        address issuerAddress
    ) public view returns (IssuerMetrics memory) {
        IssuerMetrics memory metrics;
        uint256[] memory issuerTokens = tokenIdsForIssuer[issuerAddress];

        // Initialize metrics
        metrics.status = hasDebt(issuerAddress)
            ? IssuerStatus.Frozen
            : hasPendingPromiseToPay(issuerAddress)
                ? IssuerStatus.Inactive
                : IssuerStatus.Active;

        metrics.pendingPromiseToPay = issuerMetrics[issuerAddress]
            .pendingPromiseToPayAmounts;
        metrics.pendingPromiseToPayDefault = issuerMetrics[issuerAddress]
            .pendingPromiseToPayDefault;
        metrics.pendingPromiseToPayDefaultHonored = issuerMetrics[issuerAddress]
            .pendingPromiseToPayDefaultHonored;

        // Calculate metrics for each token
        for (uint256 i = 0; i < issuerTokens.length; i++) {
            uint256 id = issuerTokens[i];
            TokenDetail memory token = tokenDetails[id];

            // Total minted and volume metrics
            metrics.totalKwhMinted += token.totalMintedToken;
            metrics.totalVolumeSoldKwh += (token.totalMintedToken -
                balanceOf(issuerAddress, id) -
                token.totalDestroyed);
            metrics.tokensDestroyed += token.totalDestroyed;

            // Get realtime price for dollar calculations
            (uint256 realtimePrice, ) = priceOracle.getRealTimePrice(
                token.energyAttributes.zone,
                token.energyAttributes.physicalDelivery
            );

            uint256 soldVolume = token.totalMintedToken -
                balanceOf(issuerAddress, id) -
                token.totalDestroyed;
            metrics.totalVolumeSoldDollar +=
                (soldVolume * realtimePrice) /
                10 ** 18;

            // Active and expired tokens
            if (token.isExpired) {
                metrics.totalExpiredTokens += balanceOf(issuerAddress, id);
                metrics.settledOnExpirationVolumeKwh += token.totalRedeemed;
                metrics.settledOnExpirationVolumeDollar +=
                    (token.totalRedeemed * realtimePrice) /
                    10 ** 18;
            } else {
                metrics.totalActiveTokens += balanceOf(issuerAddress, id);

                // Calculate tokens expiring in different time periods
                uint256 timeToExpiry = token.validTo - block.timestamp;
                if (timeToExpiry <= 30 days) {
                    metrics.tokensExpiringIn1 += balanceOf(issuerAddress, id);
                } else if (timeToExpiry <= 60 days) {
                    metrics.tokensExpiringIn2 += balanceOf(issuerAddress, id);
                } else if (timeToExpiry <= 90 days) {
                    metrics.tokensExpiringIn3 += balanceOf(issuerAddress, id);
                } else if (timeToExpiry <= 120 days) {
                    metrics.tokensExpiringIn4 += balanceOf(issuerAddress, id);
                } else if (timeToExpiry <= 150 days) {
                    metrics.tokensExpiringIn5 += balanceOf(issuerAddress, id);
                } else if (timeToExpiry <= 180 days) {
                    metrics.tokensExpiringIn6 += balanceOf(issuerAddress, id);
                } else if (timeToExpiry <= 365 days) {
                    metrics.tokensExpiringIn12 += balanceOf(issuerAddress, id);
                } else if (timeToExpiry <= 730 days) {
                    metrics.tokensExpiringIn24 += balanceOf(issuerAddress, id);
                } else if (timeToExpiry <= 1095 days) {
                    metrics.tokensExpiringIn36 += balanceOf(issuerAddress, id);
                }
            }

            // Physical delivery settlement - count all physical delivery types
            if (
                token.energyAttributes.physicalDelivery ==
                CommonTypes.PhysicalDeliveryType.On_Peak ||
                token.energyAttributes.physicalDelivery ==
                CommonTypes.PhysicalDeliveryType.Off_Peak ||
                token.energyAttributes.physicalDelivery ==
                CommonTypes.PhysicalDeliveryType.All
            ) {
                metrics.settledForPhysicalDelivery += token.totalRedeemed;
            }
        }

        // Calculate score based on various factors
        metrics.score = calculateIssuerScore(metrics);

        return metrics;
    }

    /**
     * @notice Calculates issuer score based on various metrics
     * @param metrics IssuerMetrics struct containing issuer statistics
     * @return uint256 Calculated score
     */
    function calculateIssuerScore(
        IssuerMetrics memory metrics
    ) internal pure returns (uint256) {
        // Base score starts at 1000
        uint256 score = 1000;

        // Deduct points for defaults and pending payments
        if (metrics.pendingPromiseToPayDefault > 0) {
            score -= 200;
        }
        if (metrics.pendingPromiseToPay > 0) {
            score -= 100;
        }

        // Add points for honored defaults
        if (metrics.pendingPromiseToPayDefaultHonored > 0) {
            score += 50;
        }

        // Adjust score based on volume
        if (metrics.totalVolumeSoldKwh > 1000000) {
            // 1M kWh
            score += 100;
        } else if (metrics.totalVolumeSoldKwh > 100000) {
            // 100k kWh
            score += 50;
        }

        // Deduct points for high ratio of expired tokens
        if (metrics.totalExpiredTokens > 0) {
            uint256 expiredRatio = (metrics.totalExpiredTokens * 100) /
                metrics.totalKwhMinted;
            if (expiredRatio > 50) {
                score -= 200;
            } else if (expiredRatio > 20) {
                score -= 100;
            }
        }

        return score;
    }
}
