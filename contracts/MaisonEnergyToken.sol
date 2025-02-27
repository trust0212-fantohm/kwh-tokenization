// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

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

        uint256 usdcValue = amount * realtimePrice;

        if (tokenIdsForIssuer[msg.sender].length == 0) {
            issuerMetrics[msg.sender].collateralBips = 100;
        }

        // Send collateral to insurance address
        uint256 collateralAmount = (usdcValue *
            issuerMetrics[msg.sender].collateralBips) / BASE_BIPS;
        usdc.safeTransferFrom(msg.sender, insuranceAddress, collateralAmount);

        uint256 id = NumKindsOfToken;
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

    // This is for Token Issuer
    function destroy(uint256 amount, uint256 id) external onlyIssuer(id) {
        TokenDetail storage token = tokenDetails[id];

        require(
            !isIssuerDefaultedForToken[token.issuer][id],
            "You are in default for this token."
        );
        require(
            hasIssuerPendingPromiseToPay[msg.sender][id],
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

    // This is for User
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

    // Expiration - Chainlink Automation checks this regularly
    function checkUpkeep(
        bytes calldata
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

    // Chainlink Automation executes this when checkUpkeep returns true
    function performUpkeep(bytes calldata performData) external override {
        uint256 id = abi.decode(performData, (uint256));

        TokenDetail storage token = tokenDetails[id];

        require(!token.isExpired, "Token already expired");

        token.isExpired = true;

        emit TokenExpirationRequested(id, block.timestamp);
    }

    // Backend action: This function should be called instantly after token expiration
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

    // Expiration - manually by Issuer
    function manualSettle(
        uint256 id,
        address[] memory tokenHolders,
        uint256[] memory amountOwed
    ) external onlyRole(ISSUER_ROLE) {
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
            totalAllocated += balanceOf(repAddress, id);
            TokenDetail memory token = tokenDetails[id];

            if (
                block.timestamp > token.validTo &&
                block.timestamp < token.validTo + 30 days
            ) {
                tokensExpiringIn1 = balanceOf(repAddress, id);
            } else if (block.timestamp < token.validTo + 60 days) {
                tokensExpiringIn2 = balanceOf(repAddress, id);
            } else if (block.timestamp < token.validTo + 90 days) {
                tokensExpiringIn3 = balanceOf(repAddress, id);
            } else if (block.timestamp < token.validTo + 120 days) {
                tokensExpiringIn4 = balanceOf(repAddress, id);
            } else if (block.timestamp < token.validTo + 150 days) {
                tokensExpiringIn5 = balanceOf(repAddress, id);
            } else if (block.timestamp < token.validTo + 180 days) {
                tokensExpiringIn6 = balanceOf(repAddress, id);
            } else if (block.timestamp < token.validTo + 365 days) {
                tokensExpiringIn12 = balanceOf(repAddress, id);
            } else if (block.timestamp < token.validTo + 730 days) {
                tokensExpiringIn24 = balanceOf(repAddress, id);
            } else if (block.timestamp < token.validTo + 1095 days) {
                tokensExpiringIn36 = balanceOf(repAddress, id);
            }
        }
    }

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
}
