# Maison Energy Tokenization Project

This project implements a tokenization system for energy trading using blockchain technology. It includes smart contracts for energy token management, orderbook functionality, and price oracles.

## Project Structure

```
├── contracts/              # Smart contracts
│   ├── MaisonEnergyToken.sol      # Main energy token contract
│   ├── MaisonEnergyOrderbook.sol  # Orderbook for energy trading
│   ├── ERCOTPriceOracle.sol       # Price oracle for ERCOT market
│   ├── interface/          # Contract interfaces
│   ├── library/            # Utility libraries
│   └── mocks/              # Mock contracts for testing
├── scripts/                # Deployment and utility scripts
├── test/                   # Test files
├── typechain-types/        # TypeScript type definitions
└── artifacts/              # Compiled contract artifacts
```

## Features

- Energy tokenization system
- Orderbook for energy trading
- ERCOT market price oracle integration
- Upgradeable smart contracts
- Comprehensive test suite

## Technology Stack

- Solidity for smart contracts
- Hardhat development environment
- TypeScript for testing and scripts
- OpenZeppelin contracts for security
- Chainlink for oracle integration

## Prerequisites

- Node.js (v16 or later)
- npm or yarn
- Hardhat
- MetaMask or similar Web3 wallet

## Installation

1. Clone the repository:
```bash
git clone [repository-url]
cd tokenization
```

2. Install dependencies:
```bash
npm install
```

3. Create a `.env` file based on `.env.example`:
```bash
cp .env.example .env
```

4. Configure your environment variables in `.env`

## Development

### Compile Contracts
```bash
npx hardhat compile
```

### Run Tests
```bash
npx hardhat test
```

### Deploy Contracts
```bash
npx hardhat run scripts/deploy.ts --network [network-name]
```

## Smart Contracts

### MaisonEnergyToken
The main token contract that represents energy units on the blockchain.

### MaisonEnergyOrderbook
Handles the trading of energy tokens through an orderbook system.

### ERCOTPriceOracle
Provides price feeds from the ERCOT energy market.

## Security

This project uses OpenZeppelin's battle-tested contracts and follows best practices for smart contract development. All contracts are upgradeable to allow for future improvements.

## License

ISC

## Contributing

1. Fork the repository
2. Create your feature branch
3. Commit your changes
4. Push to the branch
5. Create a new Pull Request
