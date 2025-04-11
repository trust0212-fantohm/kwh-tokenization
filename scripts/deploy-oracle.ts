import { ethers, upgrades } from "hardhat";

async function main() {
    console.log("Deploying ERCOTPriceOracle contract...");

    const ERCOTPriceOracle = await ethers.getContractFactory("ERCOTPriceOracle");
    
    // Deploy the proxy contract
    const ercotPriceOracle = await upgrades.deployProxy(ERCOTPriceOracle, [], {
        initializer: "initialize",
        kind: "uups" // Specify UUPS proxy pattern
    });
    
    await ercotPriceOracle.waitForDeployment();
    const oracleAddress = await ercotPriceOracle.getAddress();

    console.log(`✅ ERCOTPriceOracle deployed at: ${oracleAddress}`);
    console.log(`Proxy address: ${oracleAddress}`);
    console.log(`Implementation address: ${await upgrades.erc1967.getImplementationAddress(oracleAddress)}`);
}

// Execute deployment
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Deployment failed:", error);
        process.exit(1);
    });
