# stake-foundry — 质押挖矿合约的 Foundry 版本

> 本项目是课程作业:把stake-contract`(Hardhat 版)的 MetaNode 质押项目**完整迁移到 Foundry**,并补齐测试。合约源码微改动,开发、测试、部署全部改用 Foundry 工具链。

## 项目是什么

一个质押生息(Staking)系统,共 3 个合约:

| 合约            | 职责                                                         |
| --------------- | ------------------------------------------------------------ |
| `MetaNodeToken` | 平台币(ERC20),质押的"利息"用它支付,部署时一次性铸造、总量固定 |
| `MetaNodeStake` | 核心:UUPS 可升级质押合约——存/取本金(unstake→withdraw 两条线)、领利息(claim)、奖励记账(acc 懒结算)、三层暂停开关、角色权限 |
| `TestERC20`     | 测试用 ERC20(TST),开 1 号质押池用                            |

## 目录结构

```
src/        三个合约(与 Hardhat 版零改动一致)
test/       MetaNodeStake.t.sol — 48 个测试函数
script/     DeployMetaNodeSystem.s.sol — Foundry 部署脚本
lib/        依赖(git 忽略,按 foundry.lock 还原,见下)
out/        编译产物(git 忽略)
```

## 快速开始

### 1. 还原依赖(克隆后第一件事)

`lib/` 不进 git,按 `foundry.lock` 锁定的版本一行命令还原:

```bash
forge install foundry-rs/forge-std@tag=v1.16.2 \
  OpenZeppelin/openzeppelin-contracts@tag=v5.0.2 \
  OpenZeppelin/openzeppelin-contracts-upgradeable@tag=v5.0.2 \
  --no-commit
```

### 2. 编译 / 测试 / 覆盖率

```bash
forge build                                        # 编译
forge test                                         # 48 个测试全过
forge coverage --no-match-coverage "script/"      # 覆盖率(部署脚本按惯例排除)
```

当前覆盖率:**语句 94.25% / 行 94.27% / 分支 73.08% / 函数 91.18%**。

### 3. 本地部署演练(anvil)

```bash
# 终端 1
anvil

# 终端 2(建议 .env 里配 ETH_RPC_URL / ETH_PRIVATE_KEY,命令即可省略参数)
forge script script/DeployMetaNodeSystem.s.sol --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed
5efcae784d7bf4f2ff80  --broadcast
```

脚本流程:部署奖励币 → 部署实现合约 → 部署 ERC1967 代理(initialize)→ 预充奖励币 → 开 ETH 池和 TST 池,最后打印 token / proxy / impl 地址。

## 与 Hardhat 版的对照

| 事项     | Hardhat(stake-contract)          | Foundry(本项目)                                       |
| -------- | -------------------------------- | ----------------------------------------------------- |
| 测试     | JS(test/*.js)                    | Solidity(test/*.t.sol)                                |
| 部署     | deploy.js + upgrades.deployProxy | DeployMetaNodeSystem.s.sol + 手写 ERC1967Proxy 三件套 |
| 依赖     | npm package.json                 | git 子模块 + foundry.lock                             |
| 覆盖率   | 无                               | forge coverage,94% 语句                               |
| 部署目标 | Sepolia                          | 本地 anvil 验证通过                                   |
