import { ethers, upgrades } from "hardhat";
import { insuranceAddress, usdcAddress } from "./address";

async function main() {
    console.log("Deploying Token contract...");

    const priceOracleAddress = "0x";

    // Verify that required addresses are set
    if (!insuranceAddress || !usdcAddress) {
        throw new Error("Required addresses not set in address.ts");
    }

    const MaisonEnergyToken = await ethers.getContractFactory("MaisonEnergyToken");

    // Deploy the proxy contract
    const maisonEnergyToken = await upgrades.deployProxy(MaisonEnergyToken, [
        priceOracleAddress,
        insuranceAddress,
        usdcAddress
    ], {
        initializer: "initialize",
        kind: "uups" // Specify UUPS proxy pattern
    });

    await maisonEnergyToken.waitForDeployment();
    const tokenAddress = await maisonEnergyToken.getAddress();

    console.log(`✅ MaisonEnergyToken deployed at: ${tokenAddress}`);
    console.log(`Proxy address: ${tokenAddress}`);
    console.log(`Implementation address: ${await upgrades.erc1967.getImplementationAddress(tokenAddress)}`);
}

// Execute deployment
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Deployment failed:", error);
        process.exit(1);
    });
