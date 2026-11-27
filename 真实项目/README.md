# Reactive Builder Camp

ETHPanda × Reactive Network 两周共学（2026-11-16 → 11-29），对接 Reactive Omni Buildathon。

- `starter/` — clone 即用的「事件 → react() → 回调」三步走模板（Foundry），已在 Sepolia ↔ Lasna 实测跑通
- `docs/cheatsheet.md` — 网络 / 地址 / 费用 / Omni 写法速查表
- `docs/faq.md` — 学员 FAQ

报名：https://web3career.build/zh/programs/reactive-builder-camp
黑客松：https://dorahacks.io/hackathon/reactive-omni-buildathon/detail

本仓库的模板和文档由 AI 辅助编写，经人工审阅与链上实测。

## 出问题怎么办

本节适用于新版 FuelBank 和 IndependentMonitor。Sepolia 的 Pool 用自己的 ETH 给 A、B、C 的回调账户补款，也能给自己的回调账户存手续费。每次处理有效拨款指令时，Pool 先检查自己的预付余额。余额低于 0.0002 ETH 或存在欠费时触发，自补每次最多 0.0003 ETH，累计最多 0.001 ETH。共用本金，给自己补费会减少可拨给业务的金额。这些上限针对主动充值；网络执行费用按实际收取。

- **防误触与重复。** 只处理指定链和合约的事件。银行校验回调代理、Monitor、三个指定收款对象和轮次，付款前再次检查余额与欠款。重复轮次不能再付款。每个对象单笔和累计最多 0.001 ETH，三个对象累计最多 0.003 ETH。
- **资金池见底。** Pool 最多付出现有余额。处理拨款后如果本金为零，会发出 BankEmpty 事件，Lasna 收到后自动暂停。往 Pool 地址转 Sepolia ETH，再由所有者调用 Monitor 的 resume。充值保留已用额度；16 次请求的硬上限也保留。
- **费用见底。** 如果 Pool 的回调本身已无法送达，任何人可在 Sepolia 主动调用 Pool 的 maintainFeeReserve()；发起人付这笔交易费，资金只能进 Pool 自己的代理账户。自补预算用完后可以直接在代理调用 depositTo(Pool地址) 手动预付。Lasna 的 Monitor 单独使用 lREACT，需要在 Lasna 补充。
- **目标链交易失败。** 回滚会撤销这次交易内的付款和记账。对象三分钟未报告，下次定时事件会请求银行复核；余额够就跳过。银行回调若失败，先看目标链内部调用，再检查累计拨款、代理预付和欠费。旧版一次检查三个对象曾耗尽单笔 gas，增加存款无法提高交易 gas 上限。新版每笔只处理一个对象。可用 stop 暂停后排查。

[Foundry 保护测试](IndependentMonitor.t.sol)。在 starter 目录运行 `forge test --match-contract IndependentMonitorTest -vv`。
