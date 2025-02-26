import { ethers, upgrades } from "hardhat";

async function main() {
    console.log("Deploying ERCOTPriceOracle contract...");

    const ERCOTPriceOracle = await ethers.getContractFactory("ERCOTPriceOracle")
    const ercotPriceOracle = await upgrades.deployProxy(ERCOTPriceOracle, [], {
        initializer: "initialize",
    });
    await ercotPriceOracle.waitForDeployment();

    console.log(`✅ ERCOTPriceOracle deployed at: ${await ercotPriceOracle.getAddress()}`);
}

// Execute deployment
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Deployment failed:", error);
        process.exit(1);
    });
