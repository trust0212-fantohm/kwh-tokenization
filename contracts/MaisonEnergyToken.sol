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

    uint256 private constant BASE_BIPS = 10000;
    uint256 public NumKindsOfToken;

    address public insuranceAddress;

    struct IssuerData {
        uint256 collateralBips;
        uint256 totalCollateral;
        uint256 totalDefaults;
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

    // totalMintedToken = totalSupply + totalRedeemed + totalDestroyed + Balance(Issuer);
    // totalSupply =  Balance(Issuer) + BalanceOfTheOtherUsers

    mapping(uint256 => uint256) private attemptSettlement;
    mapping(uint256 => TokenDetail) public tokenDetails;
    mapping(address => bool) private isTokenIssuerInDefault;
    mapping(address => bool) private hasTokenIssuerPendingPromiseToPay;
    // mapping(uint256 => uint256) public expirationRequestedAt; // Store when expiration was requested
    mapping(address => uint256) public redeemedTokensForUser;
    mapping(address => IssuerData) public tokenIssuers;

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
        require(
            !isTokenIssuerInDefault[msg.sender],
            "Token issuer is in default"
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

        // Send collateral to insurance address
        uint256 collateralAmount = (usdcValue *
            tokenIssuers[msg.sender].collateralBips) / BASE_BIPS;
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

        // totalSupplyById[id] += amount;

        NumKindsOfToken++;

        emit TokenMinted(msg.sender, id, amount);
    }

    modifier onlyIssuer(uint256 id) {
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

        require(!isTokenIssuerInDefault[msg.sender], "You are in default");
        require(
            !hasTokenIssuerPendingPromiseToPay[msg.sender],
            "You have a pending promise-to-pay"
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

        _requestTokenExpiration(id);
    }

    function _requestTokenExpiration(uint256 id) internal {
        TokenDetail storage token = tokenDetails[id];
        // expirationRequestedAt[id] = block.timestamp;

        require(!token.isExpired, "Token already expired");

        token.isExpired = true;

        if (balanceOf(token.issuer, id) < token.totalMintedToken) {
            hasTokenIssuerPendingPromiseToPay[token.issuer] = true;
        }

        emit TokenExpirationRequested(id, block.timestamp);
    }

    // Should be run iterally 24 hours up till 3 times after requestTokenExpiration
    function settle(
        uint256 id,
        address[] memory tokenHolders,
        uint256[] memory amounts
    ) external onlyIssuer(id) {
        TokenDetail storage token = tokenDetails[id];

        require(token.isExpired, "Not expired yet");
        // require(block.timestamp > expirationRequestedAt[id], "Not available");
        require(tokenHolders.length == amounts.length, "Invalid");

        (uint256 realtimePrice, ) = priceOracle.getRealTimePrice(
            token.energyAttributes.zone,
            token.energyAttributes.physicalDelivery
        );

        uint256 settlementPrice = realtimePrice < token.embeddedValue
            ? realtimePrice
            : token.embeddedValue;

        for (uint256 i = 0; i < tokenHolders.length; i++) {
            bool success = usdc.transferFrom(
                insuranceAddress,
                tokenHolders[i],
                settlementPrice * amounts[i]
            );
            if (!success && ++attemptSettlement[id] >= 3) {
                isTokenIssuerInDefault[token.issuer] = true;
            } else {
                emit Settled(id, tokenHolders[i], amounts[i]);
            }
        }
    }

    function getTokenMetrics(
        uint256 id
    ) public view returns (TokenMetrics memory) {
        require(id <= NumKindsOfToken, "Invalid mint ID");

        TokenDetail storage token = tokenDetails[id];

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

    // function getIssuerMetrics(address tokenIssuer) public view returns

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
