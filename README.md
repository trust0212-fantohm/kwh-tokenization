# NFT Mint Smart Contract

This Solidity smart contract implements an ERC721 token for NFT minting with access control and supply limitations.  
Only an authorized wallet (backend wallet) is allowed to mint NFTs.

## Setup

1. Install Dependencies

```ssh
npm install
```

2. Environment Configuration

```ssh
PRIVATE_KEY_TESTNET=<Your_Private_Key>
ETHERSCAN_API_KEY=<ETHERSCAN_API_KEY>
```

## Compile

```ssh
npx hardhat compile
```

## deploy

```ssh
npx hardhat run scripts/deploy.ts --network sepolia
```
# kwh-tokenization
