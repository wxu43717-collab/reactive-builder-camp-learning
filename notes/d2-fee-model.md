# Reactive 费用模型笔记

查询日期：2026 年 11 月 17 日。网络：Reactive Lasna。

## 查询命令和输出

在 WSL 中设置节点和系统合约地址：

```bash
export LASNA_RPC_URL=https://lasna-rpc.rnk.dev/
export SYSTEM_ADDR=0x8888888888888888888888888888888888888888
```

读取计费系数：

```bash
cast call "$SYSTEM_ADDR" "_gasPriceCoeffPer1000()(uint256)" --rpc-url "$LASNA_RPC_URL"
```

输出：

```text
1000
```

读取固定附加 Gas：

```bash
cast call "$SYSTEM_ADDR" "_extraGas()(uint256)" --rpc-url "$LASNA_RPC_URL"
```

输出：

```text
100000 [1e5]
```

读取付款操作的 Gas 上限：

```bash
cast call "$SYSTEM_ADDR" "_maxChargeGas()(uint256)" --rpc-url "$LASNA_RPC_URL"
```

输出：

```text
50000 [5e4]
```

## 1. 一次 react() 的费用怎么算？

我查到的系数是 1000，要除以 1000，所以倍率是 1。固定附加 Gas 是 100000。因此当前参数下：

```text
一次 react() 的费用
= 基础 Gas 单价 × 1 ×（实际执行消耗的 Gas + 100000）
```

基础单价取 `tx.gasprice` 和 `block.basefee` 中较大的值。Gas 数量是工作量，还要乘单价才是费用。这个公式让我想到英国税法里的一些 special rules，要先弄清各项规则，再代入计算。

`_maxChargeGas = 50000` 是结算时付款函数可使用的 Gas 上限，不是一次 react() 的总费用上限，也不直接加进这个公式。

## 2. balance、reserves、debt 是什么？为什么有一点 debt 就停止执行？

我把它们理解成余额、预付款和欠款，但它们不是三个独立合约：

- balance：我的合约地址实际持有的原生币余额。
- reserves：系统合约记在我的合约名下、用于付费的预存额度。
- debt：系统记录的、已经产生但还没付清的费用。

收费先使用 reserves，不够的部分形成 debt，系统再尝试让合约从自身余额付款。如果还存在欠款，后续就不再调用 react()。这是先结清账单再继续服务的规则。

所以合约有 balance，不一定代表没有 debt。直接给合约转钱只增加余额，不会自动结清已经留下的欠款。通过系统的 depositTo() 为指定合约充值，会先还债，剩余才成为 reserves。

## 3. react() 回滚还收费吗？对设计有什么影响？

还收费。回滚是执行出错后，撤销这次调用中已经做出的状态修改，但计算资源已经用掉了，不会因为结果撤销就免费。

如果只是数字没有达到阈值，这是正常情况，我会用 return 提前结束，而不是用 revert 报错。return 也会消耗已执行部分的 Gas，但可以避免无意义的失败。权限不对等真正的错误，仍然需要检查和拒绝。

参考：[Reactive 官方费用说明](https://dev.reactive.network/economy)。
