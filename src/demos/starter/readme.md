# Reactive Omni starter

最小的「源链事件 → Reactive 判断 → 目标链回调」示例，与本项目的 Uniswap demo 共用 Foundry 配置和依赖。
**以下所有命令均在项目根目录 `reactive_study_notes/` 执行。**

## 文件与流程

```text
src/demos/starter/
  CampOrigin.sol       源链：ping(value) 发出 Ping 事件
  CampReactive.sol     Reactive 链：订阅事件，达到阈值时请求回调
  CampCallback.sol     目标链：接收回调，更新 count 并发出 Handled
  .env.example         此示例的环境变量模板
  readme.md            本说明
script/DeployStarter.s.sol  部署、绑定、触发脚本
script/verify-starter.sh    链上状态核验
test/Camp.t.sol             8 个本地模拟测试
```

默认以 Sepolia 同时作为源链和目标链，Lasna 作为 Reactive 链。
`CampReactive.react()` 使用 `onlySystem`，通过 `SYSTEM.requestCallbackV_1_0` 请求回调。
Callback 同时使用 `onlyServiceProvider` 和 `onlyCallbackSender` 鉴权。

## 本地验证

当前项目已有依赖时，无需重复安装，也无需复制上游的 `foundry.toml` 或 `foundry.lock`。
`@reactive/` 复用本地 `lib/reactive-lib/`，其来源为 Omni 专用库。

```bash
forge build
forge test --match-contract CampTest -vv
forge test -vv
```

测试通过模拟系统合约和 Callback Proxy 验证订阅、阈值、鉴权、回调和次数上限，
不连接公共链，不需要私钥或测试币。脚本及测试中的 `vm.*` 是 Foundry cheatcode。

## 环境配置

```bash
cp -n src/demos/starter/.env.example .env
```

若根目录已有 `.env`，上述命令不会覆盖它，请手动合并本示例所需变量。
本示例与 Uniswap 部署脚本使用不同的变量名；部署脚本和核验脚本均读取根目录 `.env`。
填写 `PRIVATE_KEY`、RPC、链 ID 和当前目标链的 Omni Callback Proxy。
模板中的网络和 Proxy 是上游示例值，部署前应确认适用于实际环境。
使用测试专用钱包，私钥仅保存在已忽略的根目录 `.env` 中，不写入本目录模板。

```bash
set -a
source .env
set +a
```

上游脚本直接读取 `PRIVATE_KEY`，与本项目其他脚本的 keystore 方式不同。
默认参数如下，可在 `.env` 中追加同名变量进行覆盖：

| 变量 | 默认值 | 用途 |
|---|---|---|
| `THRESHOLD` | `100` | 请求回调的数值下限 |
| `LIMIT` | `5` | 最多请求回调次数 |
| `PING_VALUE` | `500` | 测试触发值 |
| `REACTIVE_FUND` | `500000000000000000` | 部署附带 0.5 lREACT，单位 wei |
| `CALLBACK_FUND` | `20000000000000000` | 部署附带 0.02 ETH，单位 wei |

两条链的部署账户分别需要足够的原生币，除附带资金外还需支付部署交易 gas。

## 部署与触发

各阶段可先省略 `--broadcast` 模拟；后续阶段只使用成功广播交易产出的地址。
每次修改 `.env` 后，都重新执行上面的 `set -a / source .env / set +a` 三条命令。

```bash
# 1. Sepolia 部署事件源；将输出地址写入根目录 .env 的 ORIGIN_ADDR 并重新导出。
forge script script/DeployStarter.s.sol:DeployOrigin \
  --rpc-url "$SEPOLIA_RPC_URL" --broadcast

# 2. Lasna 部署 Reactive；将输出地址写入 REACTIVE_ADDR 并重新导出。
forge script script/DeployStarter.s.sol:DeployReactive \
  --rpc-url "$LASNA_RPC_URL" --broadcast

# 3. Sepolia 部署 Callback；将输出地址写入 CALLBACK_ADDR 并重新导出。
forge script script/DeployStarter.s.sol:DeployCallback \
  --rpc-url "$SEPOLIA_RPC_URL" --broadcast

# 4. Lasna 绑定 Callback。
forge script script/DeployStarter.s.sol:SetRecipient \
  --rpc-url "$LASNA_RPC_URL" --broadcast

# 5. Sepolia 发出事件。
forge script script/DeployStarter.s.sol:Ping \
  --rpc-url "$SEPOLIA_RPC_URL" --broadcast

# 6. 查询源链事件、Reactive 状态和目标链回调。
bash script/verify-starter.sh
```

成功标准：源链出现 `Ping`，Reactive 的 `lastReactBlock` 更新，目标链 `count` 增加并出现 `Handled`。
`lastTxHash` 记录源链交易哈希；Reactive 交易哈希需在 Reactive 浏览器或交易日志中另外确认。
核验脚本只查询最近 5000 个区块内的源链和目标链事件，RPC 限制查询范围时可缩小该范围。

## 示例边界

- 构造时立即订阅；先完成 Callback 部署和绑定，再触发事件。
- `remaining` 统计回调请求次数，并不保证目标链执行成功；归零后会退订。
- `topUp()` 设置剩余次数并接收资金，不会重新订阅，也不主动清偿已有欠款。
- 直接转账增加合约余额，不等同于清偿欠款；有欠款时需通过系统或代理的 `depositTo(address)` 等官方方式处理。
- 保留上游示例逻辑，本地测试不代表已完成公共网络端到端验证。

## 来源

基于 [reactive-builder-camp starter](https://github.com/ethpanda-org/reactive-builder-camp/tree/87675f45bdaf7b944028bd6231e463f869b453c8/starter)，
来源提交 `87675f45bdaf7b944028bd6231e463f869b453c8`。
合约业务逻辑保持上游版本，仅调整项目布局、脚本和测试的路径及本说明。

- [Reactive Contracts](https://dev.reactive.network/reactive-contracts)
- [Callback Contracts](https://dev.reactive.network/callback-contracts)
- [Economy & System Interactions](https://dev.reactive.network/economy)
- [Omni micro-demos](https://github.com/Reactive-Network/reactive-smart-contract-demos/tree/omni/src/micro-demos)
