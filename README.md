# SwarmCore (SWARMCORE)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum.

| Parameter        | Value                                                        |
| ---------------- | ------------------------------------------------------------ |
| Solidity contract | `SwarmCore` (`src/SwarmCore.sol`)                           |
| `name()`         | `SwarmCore`                                                  |
| `symbol()`       | `SWARMCORE`                                                  |
| `decimals()`     | 18                                                           |
| `totalSupply()`  | 1,000,000,000 × 10^18 = `1000000000000000000000000000` minor units |
| Constructor args | none                                                         |
| Minted to        | `msg.sender` of the constructor, once (the launch factory)   |
| Admin powers     | none                                                         |

## Layout

```
foundry.toml          compiler pins and build settings (solc 0.8.26, bytecode_hash = "none")
src/SwarmCore.sol     the token
test/SwarmCore.t.sol  behaviour tests, including fuzz tests
test/utils/Harness.sol a minimal cheatcode interface and assertion base, so nothing is vendored
```

The project has no external dependencies. The tests declare the subset of Foundry cheatcodes they
use (`prank`, `expectRevert`, `expectEmit`, `recordLogs`, `getRecordedLogs`, `assume`, `label`)
against the cheatcode address directly, so there is no `lib/` directory and no submodule.

## Verification

```
forge build
forge test
forge fmt --check
```

Fuzz tests run with the default 256 runs; the launch verifier runs them with its own fixed seed.
No test reads or sets environment variables, and tests pass in any order and in parallel.

## Design and assumptions

- **Fixed supply.** The whole supply is written into the deployer's balance in the constructor and a
  single `Transfer(address(0), deployer, supply)` event is emitted. There is no `mint`, no `burn`,
  no minter role and no upgrade path, so the supply can never change after deployment.
- **No owner.** The contract has no owner, pause, blocklist, freeze or seizure function. Nobody but a
  holder (or a spender the holder approved) can move that holder's balance.
- **Exact transfers.** There is no fee, tax, reflection or burn on transfer. Every transfer moves
  exactly the amount requested, which is what the launch flows require: the swarm's share arrives
  at the MerkleDistributor whole, claims leave it whole, the pool seed and swaps through the Uniswap
  v4 PoolManager move exactly what they say, and the requester's remainder arrives whole.
- **No exemptions needed.** Because the token applies no transfer rules, the constructor does not take
  the factory, pool manager or launch number, and it calls no other contract. It can be deployed on
  an empty chain.
- **Allowances.** `approve` sets (does not add to) the allowance; an allowance of `type(uint256).max`
  is unlimited and is not decremented by `transferFrom`. Approving the zero address reverts.
  Transfers to the zero address revert, so tokens cannot be destroyed by mistake.
- **Errors.** Failures revert with ERC-6093 custom errors (`ERC20InsufficientBalance`,
  `ERC20InvalidReceiver`, `ERC20InsufficientAllowance`, `ERC20InvalidSpender`) rather than
  returning `false`.
- **Bytecode.** No `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`; no library calls, so nothing is left
  unlinked; the runtime is far below the EIP-170 limit. `bytecode_hash = "none"` keeps the build
  reproducible for the launch's bytecode comparison.
- **No ether.** The token has no `receive` or `fallback`, so plain ether sent to it is refused.

## Deployment parameters

The launch is performed by IdentityMD's deployer through the ProjectFactory, not by this project.
The values below are the launch's, recorded here for the manifest step and for reviewers:

| Setting                      | Value                                                                      |
| ---------------------------- | -------------------------------------------------------------------------- |
| Chain                        | Ethereum mainnet (chain id 1)                                              |
| Token contract               | `SwarmCore`, constructor arguments `[]`                                    |
| `token.totalSupply`          | `1000000000000000000000000000`                                             |
| `token.decimals`             | `18`                                                                       |
| Paired currency              | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals)            |
| `pool.fee`                   | `12500` (1.25%)                                                            |
| `pool.tickSpacing`           | `60`                                                                       |
| `pool.initialPrice`          | `79228162514264337593543950336` (provenance only; the deployer derives the opening price) |
| `economics.poolBps`          | `8000` (80% of the supply seeds the pool)                                  |
| `economics.initialMarketCapWei` | `3500000000000000000000` (3,500 IMD for the whole supply)               |
| `economics.remainderTo`      | `0xd6fac924dcda60610764cc645dbd3939fc18e1a3`                               |
| Swarm share                  | 10% of the supply, taken by the factory to the launch's MerkleDistributor  |
| Application contracts        | none                                                                       |

The constructor mints the whole supply to `msg.sender`, which is the factory at launch. The factory
then forwards the swarm's 10% to the MerkleDistributor, seeds the pool with 80%, and sends the
remaining 10% to `economics.remainderTo`. No contract in this repository is allocated or sent any
tokens at launch.

`launch.json` is written by the manifest step after this work is accepted; it is deliberately not
part of this repository.

## After launch

There is nothing to configure. The token has no owner-settable values, no roles and no
post-deployment initialisation.

## Operational responsibilities

- **Holders** are responsible for their own keys and allowances. The plain ERC-20 `approve` has the
  well-known race when changing a non-zero allowance; set it to zero first if the spender is untrusted.
- **The requester** receives the remainder at `economics.remainderTo` and is responsible for that
  wallet. There is no way to recover tokens sent to a wrong address or to the token contract itself.
- **Nobody** can pause, freeze, mint, burn, upgrade or seize. This is a feature of the design: there is
  no key to lose and no admin to compromise, but also no emergency lever.
- **Pre-release review.** Tests passing are not a security audit. The launch policy's independent
  review follows acceptance of this work; explorer verification of the deployed bytecode belongs to the
  network's deployer. Static analysers (Slither, Mythril) were not available in this environment and
  were not run.

## Security checklist notes

Checked against the eth-security reference supplied with the task:

- Reentrancy: no external calls of any kind, so none possible.
- Access control: no privileged functions exist.
- Arithmetic: the only `unchecked` blocks follow explicit checks (`value <= balance`,
  `value <= allowance`) and the balance addition is bounded by the constant total supply.
- Front-running of `approve`: inherent to ERC-20; documented above.
- Upgradeability, delegatecall, selfdestruct: none.
- Token supply: constant, verified by tests that try every common mint and admin selector from both
  a stranger and the deployer.
