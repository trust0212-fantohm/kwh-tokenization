import { ethers, upgrades } from "hardhat";
import { insuranceAddress, treasury, usdcAddress } from "./address";

async function main() {
    console.log("Deploying Orderbook contract...");

    // Verify that required addresses are set
    if (!treasury || !insuranceAddress || !usdcAddress) {
        throw new Error("Required addresses not set in address.ts");
    }

    const MaisonEnergyOrderBook = await ethers.getContractFactory("MaisonEnergyOrderBook");
    
    // Deploy the proxy contract
    const maisonEnergyOrderBook = await upgrades.deployProxy(MaisonEnergyOrderBook, [
        treasury,
        insuranceAddress,
        usdcAddress,
        "MaisonEnergyOrderbook" // Contract name
    ], {
        initializer: "initialize",
        kind: "uups" // Specify UUPS proxy pattern
    });
    
    await maisonEnergyOrderBook.waitForDeployment();
    const orderbookAddress = await maisonEnergyOrderBook.getAddress();

    console.log(`✅ MaisonEnergyOrderBook deployed at: ${orderbookAddress}`);
    console.log(`Proxy address: ${orderbookAddress}`);
    console.log(`Implementation address: ${await upgrades.erc1967.getImplementationAddress(orderbookAddress)}`);
}

// Execute deployment
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Deployment failed:", error);
        process.exit(1);
    });
