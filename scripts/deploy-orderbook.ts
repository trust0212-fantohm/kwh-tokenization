import { ethers, upgrades } from "hardhat";
import { insuranceAddress, treasury, usdcAddress } from "./address";

async function main() {
    console.log("Deploying Orderbook contract...");

    const MaisonEnergyOrderBook = await ethers.getContractFactory("MaisonEnergyOrderBook")
    const maisonEnergyOrderBook = await upgrades.deployProxy(MaisonEnergyOrderBook, [treasury, insuranceAddress, usdcAddress, ""], {
        initializer: "initialize",
    });
    await maisonEnergyOrderBook.waitForDeployment();

    console.log(`✅ maisonEnergyOrderBook deployed at: ${await maisonEnergyOrderBook.getAddress()}`);
}

// Execute deployment
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Deployment failed:", error);
        process.exit(1);
    });
