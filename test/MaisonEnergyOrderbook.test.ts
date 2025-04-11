import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { ERCOTPriceOracle, MaisonEnergyOrderBook, MaisonEnergyToken, MockUSDC } from "../typechain-types";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("MaisonEnergyOrderBook", function () {
  const ISSUER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ISSUER_ROLE"));

  let orderBook: MaisonEnergyOrderBook;
  let token: MaisonEnergyToken;
  let usdc: MockUSDC;

  let owner: SignerWithAddress;
  let buyer: SignerWithAddress;
  let seller: SignerWithAddress;
  let treasury: SignerWithAddress;
  let insurance: SignerWithAddress;
  let ercotPriceOracle: ERCOTPriceOracle;

  const tokenId = 0;
  const USDC_DECIMALS = 6;
  const TOKEN_DECIMALS = 18;

  // Enum values
  const ZoneType = {
    LZ_NORTH: 0,
    LZ_WEST: 1,
    LZ_SOUTH: 2,
    LZ_HOUSTON: 3
  };

  const PhysicalDeliveryType = {
    On_Peak: 0,
    Off_Peak: 1,
    All: 2
  };

  const PhysicalDeliveryDays = {
    Mon: 0,
    Tue: 1,
    Wed: 2,
    Thu: 3,
    Fri: 4,
    Sat: 5,
    Sun: 6
  };

  const FuelType = {
    Solar: 0,
    Wind: 1,
    NaturalGas: 2
  };

  beforeEach(async () => {
    [owner, buyer, seller, treasury, insurance] = await ethers.getSigners();

    // Deploy MockUSDC
    const USDC = await ethers.getContractFactory("MockUSDC");
    usdc = await USDC.deploy();
    await usdc.waitForDeployment();

    // Deploy ERCOTPriceOracle
    const ERCOTPriceOracle = await ethers.getContractFactory("ERCOTPriceOracle");
    ercotPriceOracle = await upgrades.deployProxy(ERCOTPriceOracle, [], {
      initializer: "initialize",
    });
    await ercotPriceOracle.waitForDeployment();

    // Deploy MaisonEnergyToken
    const Token = await ethers.getContractFactory("MaisonEnergyToken");
    token = await upgrades.deployProxy(
      Token,
      [await ercotPriceOracle.getAddress(), owner.address, await usdc.getAddress()],
      {
        initializer: "initialize",
      }
    );
    await token.waitForDeployment();

    // Deploy MaisonEnergyOrderbook
    const OrderBook = await ethers.getContractFactory("MaisonEnergyOrderBook");
    orderBook = await upgrades.deployProxy(
      OrderBook,
      [treasury.address, await usdc.getAddress(), await token.getAddress()],
      {
        initializer: "initialize",
      }
    );
    await orderBook.waitForDeployment();

    const amount = ethers.parseUnits("1000", 18);
    const embeddedValue = ethers.parseUnits("50", 18);
    const validFrom = (await time.latest()) + 3600;
    const validTo = validFrom + 86400 * 30; // 30 days

    // Grant roles
    await token.grantRole(ISSUER_ROLE, seller.address);

    // Mint tokens
    await token.connect(seller).mint(
      amount,
      embeddedValue,
      validFrom,
      validTo,
      "ERCOT123",
      {
        zone: ZoneType.LZ_HOUSTON,
        physicalDelivery: PhysicalDeliveryType.On_Peak,
        physicalDeliveryHours: 24,
        physicalDeliveryDays: PhysicalDeliveryDays.Mon,
        fuelType: FuelType.NaturalGas
      }
    );
  });

  function getOrderMetadata(orderType: number) {
    return {
      orderType, // 0 = BUY, 1 = SELL
      zone: 0, // LZ_NORTH
      physicalDelivery: 0 // On_Peak
    };
  }

  it("should revert buy market order when no active sell orders", async () => {
    const usdcAmount = ethers.parseUnits("100", USDC_DECIMALS);
    await usdc.mint(await buyer.getAddress(), usdcAmount);
    await usdc.connect(buyer).approve(await orderBook.getAddress(), usdcAmount);

    await expect(orderBook.connect(buyer).createBuyMarketOrder(
      usdcAmount,
      tokenId,
      getOrderMetadata(0)
    )).to.be.revertedWith("No active sell orders");
  });

  it("should create and match a buy market order", async () => {
    const price = ethers.parseUnits("1", USDC_DECIMALS);
    const tokenAmount = ethers.parseUnits("100", TOKEN_DECIMALS);
    const validTo = Math.floor(Date.now() / 1000) + 3600;

    // Seller places limit order
    await token.connect(seller).setApprovalForAll(orderBook.getAddress(), true);
    await orderBook.connect(seller).createLimitOrder(
      price,
      tokenAmount,
      validTo,
      tokenId,
      getOrderMetadata(1) // SELL
    );

    const usdcAmount = price * BigInt(100);
    await usdc.mint(await buyer.getAddress(), usdcAmount);
    await usdc.connect(buyer).approve(orderBook.getAddress(), usdcAmount);

    const before = await token.balanceOf(await buyer.getAddress(), tokenId);
    await orderBook.connect(buyer).createBuyMarketOrder(usdcAmount, tokenId, getOrderMetadata(0));
    const after = await token.balanceOf(await buyer.getAddress(), tokenId);

    expect(after > before).to.be.true;
  });

  it("should forward unmatched sell market orders to insurance", async () => {
    const tokenAmount = ethers.parseUnits("50", TOKEN_DECIMALS);
    await token.connect(seller).setApprovalForAll(orderBook.getAddress(), true);

    const before = await token.balanceOf(await insurance.getAddress(), tokenId);

    await orderBook.connect(seller).createSellMarketOrder(
      tokenAmount,
      tokenId,
      getOrderMetadata(1) // SELL
    );

    const after = await token.balanceOf(await insurance.getAddress(), tokenId);
    expect(after - before).to.equal(tokenAmount);
  });

  it("should cancel a limit order and refund USDC", async () => {
    const price = ethers.parseUnits("1", USDC_DECIMALS); // 1 USDC per token
    const tokenAmount = ethers.parseUnits("100", TOKEN_DECIMALS); // 100 tokens

    const validTo = Math.floor(Date.now() / 1000) + 3600;

    const totalUSDC = ethers.parseUnits("100", USDC_DECIMALS);

    await usdc.mint(buyer.address, totalUSDC);
    await usdc.connect(buyer).approve(orderBook.getAddress(), totalUSDC);

    await orderBook.connect(buyer).createLimitOrder(
      price,
      tokenAmount,
      validTo,
      tokenId,
      getOrderMetadata(0) // BUY
    );

    const balanceBefore = await usdc.balanceOf(buyer.address);
    await orderBook.connect(buyer).cancelOrder(0);
    const balanceAfter = await usdc.balanceOf(buyer.address);

    expect(balanceAfter > balanceBefore).to.be.true;
  });

  it("should revert cancel if not maker", async () => {
    const price = ethers.parseUnits("1", USDC_DECIMALS);
    const tokenAmount = ethers.parseUnits("100", TOKEN_DECIMALS);
    const usdcAmount = price * BigInt(100);
    const validTo = Math.floor(Date.now() / 1000) + 3600;

    await usdc.mint(await buyer.getAddress(), usdcAmount);
    await usdc.connect(buyer).approve(orderBook.getAddress(), usdcAmount);

    await orderBook.connect(buyer).createLimitOrder(
      price,
      tokenAmount,
      validTo,
      tokenId,
      getOrderMetadata(0)
    );

    await expect(orderBook.connect(seller).cancelOrder(0)).to.be.revertedWith("You are not an maker of this order");
  });

  it("should detect expired orders via checkUpkeep", async () => {
    const price = ethers.parseUnits("1", USDC_DECIMALS);
    const tokenAmount = ethers.parseUnits("100", TOKEN_DECIMALS);
    const validTo = (await time.latest()) + 5;

    await token.connect(seller).setApprovalForAll(orderBook.getAddress(), true);
    await orderBook.connect(seller).createLimitOrder(
      price,
      tokenAmount,
      validTo,
      tokenId,
      getOrderMetadata(1) // SELL
    );

    await time.increase(10);

    const currentBlock = await ethers.provider.getBlock("latest");
    const expectedTimestamp = currentBlock.timestamp + 1; // 1 second later

    const [needed, data] = await orderBook.checkUpkeep("0x");
    expect(needed).to.equal(true);

    await expect(orderBook.performUpkeep(data))
      .to.emit(orderBook, "NoLiquiditySellOrderCreated")
      .withArgs(await seller.getAddress(), tokenAmount, expectedTimestamp);
  });
});
