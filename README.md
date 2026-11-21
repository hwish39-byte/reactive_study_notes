# Reactive Network Omni 学习与 Uniswap V2 demo

本项目复现单笔止损和个人多订单止损／止盈。合约按 Omni 接口迁移，
`react()` 使用 `onlySystem`，回调请求使用 `SYSTEM.requestCallbackV_1_0`。

## 项目结构

```text
src/demos/uniswap-v2-stop-order/             单笔止损、测试代币
src/demos/uniswap-v2-stop-take-profit-order/ 多订单止损／止盈
script/DeploymentBase.sol                   部署环境检查
script/DeployStopOrder.s.sol                单笔 demo 的三个部署阶段
script/DeployStopTakeProfit.s.sol           多订单 demo 的三个部署阶段
test/OmniMigration.t.sol                    事件、鉴权、订单和链 ID 回归测试
test/DeploymentScripts.t.sol                部署脚本与配置检查的本地模拟
lib/                                       Git 子模块依赖
notes/                                     学习笔记
.env.example                               不含私钥的环境变量模板
foundry.toml                               Solidity 0.8.29、优化器、RPC 别名
foundry.lock                               Foundry 依赖版本记录
remappings.txt                             Solidity 导入路径映射
```

## 安装与验证

新克隆项目后，在根目录执行：

```bash
git submodule update --init --recursive
forge build
forge test -vv
forge fmt --check src script test
```

使用 Solidity 0.8.29、Cancun EVM 和 IR 编译。这里只导入 Uniswap 接口，
部署流程使用目标链已经部署的 Factory／Router／Pair，无须重新编译旧版本 Uniswap 实现。

Reactive 依赖存放在 `lib/reactive-lib`，来源为 `Reactive-Network/reactive-lib-omni`，
固定到官方 Omni micro-demos 引用的 `3ade0dcf1d27e67e5783ef807e73a1b9e0c0cce8`。
提交自己的依赖安装结果时，需要把各 `lib/` 子模块的新提交记录与
`.gitmodules`、`foundry.lock` 一起纳入提交，保证新克隆使用相同依赖。

测试使用模拟系统、proxy、Router 和代币，不连接公共链，也不产生真实交易。
部署脚本测试按顺序检查各场景，因为环境变量是进程级共享状态。

## 准备部署环境

```bash
cp .env.example .env
```

填写 `.env` 后，将变量导出到当前 shell：

```bash
set -a
source .env
set +a
```

- `DESTINATION_CHAIN_ID=11155111` 表示 Sepolia。原 demo 的错误硬编码 `1` 已被构造参数替代。
- `REACTIVE_CHAIN_ID` 与 `DESTINATION_CHAIN_ID` 是两条不同网络的 ID，分别与实际 RPC 核对。
- 填写当前 Omni 环境的 callback proxy，以及目标链 Router 和有流动性的 Pair。
- 填写 keystore 账户名与对应的公开地址，脚本使用公开地址指定 broadcast signer。
- `CLIENT_WALLET` 是代币持有人，多订单 Callback 的 owner 也是该地址。
- 多订单 Reactive 的 owner 由脚本设为 `REACTIVE_DEPLOYER`，与目标链用户钱包可以不同。
- `REACTIVE_FUNDING_WEI`、`CALLBACK_FUNDING_WEI` 是部署时附带的原生币数量，单位为 wei。
  示例为 0.1 REACT 和 0.02 目标链原生币；按当前环境调整，部署钱包还需留出交易 gas。

签名账户可通过 `cast wallet import <账户名> --interactive` 导入。
脚本通过 `--account` 使用 keystore，不读取或输出私钥。
`.env`、广播记录、缓存和构建产物已列入 `.gitignore`。

## 部署单笔止损

每个阶段先模拟：运行对应命令并省略 `--broadcast`。确认输出后再加回该参数广播。
**模拟地址不作为下一阶段配置；仅记录已成功广播交易中的部署地址。**

```bash
# 1. 在 Reactive 链部署监听合约；尚未建立业务订阅。
forge script script/DeployStopOrder.s.sol:DeployStopOrder \
  --sig 'deployReactive()' --rpc-url reactive \
  --account "$REACTIVE_ACCOUNT" --sender "$REACTIVE_DEPLOYER" --broadcast

# 将输出的地址填入 .env，并在当前 shell 导出：
# export SINGLE_REACTIVE_ADDR=实际地址

# 2. 在目标链部署 Callback，绑定 proxy 与上述 Reactive 地址。
forge script script/DeployStopOrder.s.sol:DeployStopOrder \
  --sig 'deployCallback()' --rpc-url destination \
  --account "$DESTINATION_ACCOUNT" --sender "$DESTINATION_DEPLOYER" --broadcast

# 同样记录并导出：
# export SINGLE_CALLBACK_ADDR=实际地址

# 3. 回到 Reactive 链，使用 Reactive owner 绑定 Callback 并建立订阅。
forge script script/DeployStopOrder.s.sol:DeployStopOrder \
  --sig 'configure()' --rpc-url reactive \
  --account "$REACTIVE_ACCOUNT" --sender "$REACTIVE_DEPLOYER" --broadcast
```

示例参数 `SELL_TOKEN0=true`、`PRICE_COEFFICIENT=10000`、`STOP_LOSS_THRESHOLD=8000`，
在两种代币精度相同时表示 token0 价格不高于 0.8 时卖出。
授权额度即该 demo 的卖出量，具体建池、触发与验收步骤见
[单笔止损说明](src/demos/uniswap-v2-stop-order/README.md)。

## 部署多订单止损／止盈

```bash
forge script script/DeployStopTakeProfit.s.sol:DeployStopTakeProfit \
  --sig 'deployReactive()' --rpc-url reactive \
  --account "$REACTIVE_ACCOUNT" --sender "$REACTIVE_DEPLOYER" --broadcast

# 将成功广播后的地址填入 .env，并导出 MULTI_REACTIVE_ADDR。

forge script script/DeployStopTakeProfit.s.sol:DeployStopTakeProfit \
  --sig 'deployCallback()' --rpc-url destination \
  --account "$DESTINATION_ACCOUNT" --sender "$DESTINATION_DEPLOYER" --broadcast

# 将成功广播后的地址填入 .env，并导出 MULTI_CALLBACK_ADDR。

forge script script/DeployStopTakeProfit.s.sol:DeployStopTakeProfit \
  --sig 'configure()' --rpc-url reactive \
  --account "$REACTIVE_ACCOUNT" --sender "$REACTIVE_DEPLOYER" --broadcast
```

确认订阅和资金就绪后，由 `CLIENT_WALLET` 对应的账户授权、建单。
建单接口、暂停／恢复／取消和测试价格操作见
[多订单说明](src/demos/uniswap-v2-stop-take-profit-order/README.md)。

脚本在各阶段校验当前链 ID；Reactive 侧要求 Omni 系统地址有代码，
目标链要求 proxy、Router 有代码；绑定阶段核对 Reactive owner、目标链 ID 和未绑定状态。
这些检查不等于验证合约实现来源。两条链之间不能直接读取对方合约，
部署 Callback 前需确认 Reactive 广播成功，绑定前需确认目标链 Callback 的授权地址正确。
重复执行 deploy 阶段会部署新实例；configure 只允许成功一次。

## 当前范围

本项目提供本地测试与部署脚本，尚未证明指定公共网络的端到端执行。
保留原 demo 的 `amountOutMin=0`、单笔无自动重试、多订单失败计数回滚等限制，
详见各 demo README。原生币费用资金与待出售 ERC20 授权是两类独立配置。

参考资料：

- [Reactive Contracts](https://dev.reactive.network/reactive-contracts)
- [Callback Contracts](https://dev.reactive.network/callback-contracts)
- [Economy](https://dev.reactive.network/economy)
- [Omni micro-demos](https://github.com/Reactive-Network/reactive-smart-contract-demos/tree/omni/src/micro-demos)
