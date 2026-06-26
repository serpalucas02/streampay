# 💸 StreamPay

**🌐 Idioma:** [English](README.md) · Español

Pagos de tokens en tiempo real: bloqueás un monto de un ERC-20 y lo **streameás a alguien de forma lineal en el tiempo**. El receptor puede retirar lo que se haya devengado en cualquier segundo, y cualquiera de las dos partes puede cancelar y repartir el resto de forma justa. Pensalo como "sueldo por segundo" — un primitivo de pagos en streaming como [Sablier](https://sablier.com) o [Superfluid](https://superfluid.finance).

> Proyecto de portfolio fullstack: contrato Solidity (Foundry) + frontend Next.js (wagmi/viem) con un contador que sube en vivo, segundo a segundo.

---

## Demo en vivo

- 🌐 **App:** https://streampay-project.vercel.app
- 📜 **StreamPay (verificado):** [`0xF8b6…8c4b`](https://sepolia.etherscan.io/address/0xf8b6d10abc4155a510cab90932f0902c4c4c8c4b#code)
- 🪙 **Token de prueba sUSD (verificado):** [`0x39A5…2cB7`](https://sepolia.etherscan.io/address/0x39a5042cfb5cc1af57d8648799feac555a492cb7#code)

En **Ethereum Sepolia**. La app tiene una faucet integrada — conectá, conseguí `sUSD` de prueba y streamealo a cualquier address.

---

## Qué lo hace interesante

- **Plata que fluye.** Un stream paga de forma continua; el receptor retira lo devengado cuando quiere. La UI muestra el balance streameado **subiendo en vivo**, calculado del lado del cliente desde la tasa on-chain (sin transacciones para verlo).
- **Cualquier ERC-20.** El que paga elige el token al crear el stream — el contrato es agnóstico al token.
- **Cancelación justa.** Cancelás a mitad de stream y el receptor se queda exactamente lo devengado; el emisor recupera el resto no streameado, en una sola llamada.

---

## Cómo funciona

El monto devengado no se guarda — se **computa al leer** desde el tiempo, la misma idea que una curva de vesting:

```
streamed = deposit * elapsed / duration   (0 antes del start, el deposit completo en/después del stop)
```

```solidity
function createStream(token, recipient, deposit, duration); // bloquea fondos, abre el stream
function withdraw(streamId);                                 // el receptor retira lo devengado (pull pattern)
function cancel(streamId);                                   // settle: acredita el saldo claimable de cada parte
function claim(token);                                       // retirás tu saldo settled tras un cancel
```

---

## Arquitectura

```
src/StreamPay.sol         El protocolo: create / withdraw / cancel + views de devengado
src/MockToken.sol         ERC-20 tipo faucet para la demo
script/Deploy.s.sol       Deploya StreamPay + MockToken
test/StreamPay.t.sol      Suite Foundry (unit + fuzz + ataque de reentrancy), 100% coverage
web/                      Frontend Next.js (App Router)
  lib/wagmi.ts            Chains, connectors, transports
  lib/contract.ts         Addresses + ABIs (tipado con `as const`)
  app/page.tsx            Conectar, faucet, form de crear stream, cards con contador en vivo
```

El frontend no guarda estado propio: escribe al contrato, espera y lo vuelve a leer.

---

## Decisiones de diseño

**Devengado computado al leer (no guardado).** El "streameado hasta ahora" de un stream es una función pura de `block.timestamp`, así que siempre está actualizado y no cuesta gas mantenerlo — el contrato solo guarda el deposit, lo retirado y la ventana de tiempo.

**`Math.mulDiv` para la proporción.** `deposit * elapsed / duration` se hace con el `mulDiv` de OpenZeppelin: precisión total, sin overflow en el producto intermedio, y cae **exacto** en el deposit al `stopTime` — sin "polvo" de redondeo trabado en el contrato.

**Encontrar streams vía eventos, no enumeración on-chain.** Listar los streams de un usuario es una necesidad de la UI, así que el contrato emite `StreamCreated` (indexado por sender y recipient) y el frontend lo lee off-chain vía RPC — mucho más barato que mantener arrays on-chain por cada cuenta.

**Agnóstico al token.** Los streams llevan su propia address de token, así que un solo deploy sirve para cualquier ERC-20 (muchos a la vez). La demo en Sepolia usa un único token de prueba minteable (`sUSD`) para que cualquiera lo pruebe gratis; un deploy de producción conecta una **lista de tokens por red** (ver `web/lib/tokens.ts`) a un selector — USDC, USDT, DAI, etc. El contrato ya maneja sus particularidades: `SafeERC20` para el return no estándar de USDT, pull settlement para el blacklist de USDC, y contabilidad fee-on-transfer. Ojo con los decimales (USDC/USDT usan 6, DAI 18).

---

## Seguridad

- **`SafeERC20`** en cada movimiento de tokens (maneja ERC-20 no estándar).
- **`ReentrancyGuard` + CEI estricto** en `withdraw` y `cancel` (estado settled antes de cualquier transferencia).
- **Pull pattern** — los receptores retiran; el contrato nunca empuja.
- **Control de acceso** — solo el receptor retira; solo el emisor o el receptor pueden cancelar.
- Custom errors + validación de inputs (zero address, deposit/duration en cero, no streamear a uno mismo).
- Un test (`testReentrancyGuardBlocksMaliciousToken`) deploya un ERC-20 malicioso que intenta **reentrar `withdraw`** en su hook de transfer y verifica que el guard lo bloquea.
- Un test (`testMultipleStreamsAreIsolated`) prueba que un stream nunca puede tocar los fondos de otro.
- **Pull settlement:** `cancel` acredita el saldo claimable de cada parte y **no hace llamadas externas**, así que un token que revierte para un lado (ej. un blacklist que congela al receptor) nunca puede trabar el cancel ni los fondos de la otra parte. Cada lado retira por su cuenta con `claim()`. Probado por `testCancelAndRefundUnblockedByBlacklistedRecipient`.

**Revisado adversarialmente** (reentrancy, conservación de fondos, control de acceso, integer/precisión, fee-on-transfer, blacklisting/DoS, edge cases): sin issues críticos/altos/medios. La conservación se mantiene exacta (`recipientPayout + senderRefund == deposit − withdrawn`), y los depósitos registran el monto **realmente recibido** para que un token fee-on-transfer no pueda hacer que un stream sobre-contabilice contra otro.

**Limitaciones conocidas (por diseño):** asume tokens no rebasing; con un token fee-on-transfer el receptor igual paga el fee del propio token en el retiro *de salida* (el protocolo queda solvente — solo ese receptor se ve afectado).

---

## Tests

```
src/StreamPay.sol   100% líneas · 100% statements · 100% branches · 100% funcs   (32 tests)
```

Happy paths, todos los reverts, devengado basado en tiempo, un fuzz test sobre el invariante de devengado, y el ataque de reentrancy.

---

## Gas

| Operación | Gas |
|-----------|-----|
| `createStream` | ~185.000 |
| `withdraw` | ~90.000 |
| `cancel` | ~80.000 |
| `claim` | ~45.000 |
| views de devengado | 0 — se leen off-chain |

---

## Stack

Solidity 0.8.24 · Foundry · OpenZeppelin (SafeERC20, ReentrancyGuard, Math) · Next.js · wagmi · viem · TypeScript · Tailwind CSS
