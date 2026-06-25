// Deployed on Ethereum Sepolia.
export const STREAMPAY_ADDRESS = "0x6125DdC07117760c095623A95eEc3Ede17A846A8" as const;
export const TOKEN_ADDRESS = "0x39a5042cfb5cc1af57d8648799feac555a492cb7" as const;

// Block both contracts were deployed at — we scan StreamCreated events from here.
export const START_BLOCK = BigInt(11137983);

export const TOKEN_DECIMALS = 18;
export const TOKEN_SYMBOL = "sUSD";

export const streamPayAbi = [
  {
    type: "function",
    name: "createStream",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token_", type: "address" },
      { name: "recipient_", type: "address" },
      { name: "deposit_", type: "uint256" },
      { name: "duration_", type: "uint64" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "withdraw",
    stateMutability: "nonpayable",
    inputs: [{ name: "streamId_", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "cancel",
    stateMutability: "nonpayable",
    inputs: [{ name: "streamId_", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "getStream",
    stateMutability: "view",
    inputs: [{ name: "streamId_", type: "uint256" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "sender", type: "address" },
          { name: "recipient", type: "address" },
          { name: "token", type: "address" },
          { name: "deposit", type: "uint256" },
          { name: "withdrawn", type: "uint256" },
          { name: "startTime", type: "uint64" },
          { name: "stopTime", type: "uint64" },
          { name: "active", type: "bool" },
        ],
      },
    ],
  },
  {
    type: "event",
    name: "StreamCreated",
    inputs: [
      { name: "streamId", type: "uint256", indexed: true },
      { name: "sender", type: "address", indexed: true },
      { name: "recipient", type: "address", indexed: true },
      { name: "token", type: "address", indexed: false },
      { name: "deposit", type: "uint256", indexed: false },
      { name: "startTime", type: "uint64", indexed: false },
      { name: "stopTime", type: "uint64", indexed: false },
    ],
  },
] as const;

export const tokenAbi = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to_", type: "address" },
      { name: "amount_", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;
