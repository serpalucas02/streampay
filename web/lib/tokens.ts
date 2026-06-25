// The StreamPay contract is token-agnostic — every stream carries its own ERC-20 address.
// For this Sepolia demo the UI uses one mintable test token (sUSD) so anyone can try it for free
// (you can't get real USDC/USDT on a testnet). In production a dApp wires a network-aware token
// list to a selector; these are the mainnet stablecoins the same contract works with as-is.
// Note the decimals: USDC/USDT use 6, DAI uses 18 — the UI must read each token's decimals.
export type TokenInfo = { symbol: string; address: `0x${string}`; decimals: number };

export const PRODUCTION_TOKENS: TokenInfo[] = [
  { symbol: "USDC", address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", decimals: 6 },
  { symbol: "USDT", address: "0xdAC17F958D2ee523a2206206994597C13D831ec7", decimals: 6 },
  { symbol: "DAI", address: "0x6B175474E89094C44Da98b954EedeAC495271d0F", decimals: 18 },
];
