# Reactive Network 学习上下文

我在用 Reactive Network 的 Omni 新版本（2026-10-28 主网迁移后）。

请只参考以下资料：

- [Reactive Contracts](https://dev.reactive.network/reactive-contracts)
- [Callback Contracts](https://dev.reactive.network/callback-contracts)
- [Economy & System Interactions](https://dev.reactive.network/economy)
- [Omni 分支的 micro-demos](https://github.com/Reactive-Network/reactive-smart-contract-demos/tree/omni/src/micro-demos)

不要使用 `vm` 修饰符、ReactVM 或 `emit Callback`。旧系统合约 `0x0000000000000000000000000000000000fffFfF` 只作为 Cron 事件来源。

`react()` 必须加 `onlySystem`。发起回调时使用 `requestCallbackV_1_0`。
