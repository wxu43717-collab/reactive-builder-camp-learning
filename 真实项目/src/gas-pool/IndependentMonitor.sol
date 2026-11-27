// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ExpenseStep, ICredits} from "./ExpenseStepsV2.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

interface IFuelDeposit is ICredits {
    function depositTo(address worker) external payable;
}

contract FuelBank is AbstractCallback {
    uint256 public constant TARGET = 0.001 ether;
    uint256 public constant LOW = 0.0002 ether;
    mapping(address => bool) public allowed;
    mapping(address => uint256) public spent;
    mapping(address => uint256) public lastRound;
    address public immutable owner;
    event Paid(address indexed worker, uint256 indexed round, uint256 amount);

    constructor(IPayable proxy, address monitor, address[3] memory workers)
        payable AbstractCallback(proxy, monitor)
    {
        owner = msg.sender;
        for (uint256 i; i < 3; ++i) {
            require(workers[i].code.length != 0 && !allowed[workers[i]]);
            allowed[workers[i]] = true;
        }
    }

    uint256 public constant FEE_TOPUP_CAP = 0.0003 ether;
    uint256 public constant FEE_BUDGET = 0.001 ether;
    uint256 public feeSpent;
    event FeeReserveFunded(uint256 amount);
    event BankEmpty(uint256 indexed round);

    // Anyone may wake the bank when a callback cannot be delivered.
    // The only possible beneficiary is the bank's own proxy credit.
    function maintainFeeReserve() public {
        IFuelDeposit proxy = IFuelDeposit(address(_SERVICE_PROVIDER));
        uint256 credit = proxy.reserves(address(this));
        uint256 owed = _SERVICE_PROVIDER.debt(address(this));
        if (credit >= LOW && owed == 0) return;
        uint256 cap = FEE_BUDGET - feeSpent;
        if (cap > FEE_TOPUP_CAP) cap = FEE_TOPUP_CAP;
        if (cap > address(this).balance) cap = address(this).balance;
        uint256 amount = owed < cap ? owed : cap;
        if (credit < FEE_TOPUP_CAP) {
            uint256 gap = FEE_TOPUP_CAP - credit;
            amount += gap < cap - amount ? gap : cap - amount;
        }
        if (amount == 0) return;
        feeSpent += amount;
        proxy.depositTo{value: amount}(address(this));
        emit FeeReserveFunded(amount);
    }

    function withdraw(uint256 amount) external {
        require(msg.sender == owner);
        (bool ok,) = payable(owner).call{value: amount}("");
        require(ok);
    }

    function refill(address sender, address worker, uint256 round)
        external onlyServiceProvider onlyCallbackSender(sender)
    {
        require(allowed[worker]);
        if (round <= lastRound[worker]) return;
        lastRound[worker] = round;
        maintainFeeReserve();
        IFuelDeposit proxy = IFuelDeposit(address(_SERVICE_PROVIDER));
        uint256 credit = proxy.reserves(worker);
        uint256 debt = _SERVICE_PROVIDER.debt(worker);
        uint256 amount;
        if (credit < LOW || debt != 0) {
            uint256 cap = TARGET - spent[worker];
            if (cap > address(this).balance) cap = address(this).balance;
            amount = debt < cap ? debt : cap;
            if (credit < TARGET) {
                uint256 gap = TARGET - credit;
                amount += gap < cap - amount ? gap : cap - amount;
            }
            if (amount != 0) {
                spent[worker] += amount;
                proxy.depositTo{value: amount}(worker);
            }
        }
        emit Paid(worker, round, amount);
        if (address(this).balance == 0) emit BankEmpty(round);
    }
}

contract IndependentMonitor is AbstractReactive {
    address public immutable owner;
    address public pool;
    address[3] public workers;
    uint256 constant SEP = 11155111;
    address constant CLOCK = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant TICK = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 constant REPORT = uint256(keccak256("FuelReport(uint256,uint256,uint256)"));
    uint256 constant EMPTY = uint256(keccak256("BankEmpty(uint256)"));
    uint256 public constant LIMIT = 16;
    bool public active;
    uint256 public requests;
    uint256 public round;
    uint256 public cursor;
    uint256 public lastEmptyRound;
    uint256 public deadline;
    mapping(bytes32 => bool) private processedTicks;
    mapping(address => uint256) public nextCheck;
    mapping(address => uint256) public lastCredit;
    mapping(address => uint256) public sampledAt;
    event Requested(uint256 indexed round, address indexed recipient, address worker);
    constructor() payable { owner = msg.sender; }

    function start(address bank, address[3] calldata objects) external {
        require(msg.sender == owner && pool == address(0) && bank != address(0));
        for (uint256 i; i < 3; ++i) {
            require(objects[i] != address(0) && objects[i] != bank);
            for (uint256 j; j < i; ++j) require(objects[i] != objects[j]);
        }
        workers = objects;
        pool = bank;
        toggle(true);
    }

    function stop() external { require(msg.sender == owner); if (active) toggle(false); }
    function resume() external {
        require(msg.sender == owner && pool != address(0) && !active && requests < LIMIT);
        toggle(true);
    }
    function toggle(bool on) private {
        active = on;
        deadline = 0;
        subscribe(on, block.chainid, CLOCK, TICK);
        subscribe(on, SEP, pool, EMPTY);
        for (uint256 i; i < 3; ++i) subscribe(on, SEP, workers[i], REPORT);
    }
    function subscribe(bool on, uint256 chain, address emitter, uint256 topic) private {
        if (on) SYSTEM.subscribe(chain, emitter, topic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        else SYSTEM.unsubscribe(chain, emitter, topic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }
    function request(address to, address worker, bytes memory payload) private {
        ++requests;
        SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0({
            chainId: SEP, recipient: to, gasLimit: 1000000, payload: payload
        }));
        emit Requested(round, to, worker);
        if (requests == LIMIT) toggle(false);
    }
    function react(LogRecord calldata e) external onlySystem {
        if (!active) return;
        if (e.chainId == SEP && e.contractAddress == pool && e.topic0 == EMPTY
            && e.topic1 > lastEmptyRound && e.topic1 <= round) {
            lastEmptyRound = e.topic1;
            toggle(false);
            return;
        }
        address worker = workers[cursor];
        if (e.chainId == SEP && e.contractAddress == worker && e.topic0 == REPORT
            && e.topic1 == round && deadline != 0 && e.data.length == 64) {
            (uint256 credit, uint256 debt) = abi.decode(e.data, (uint256,uint256));
            uint256 delay = 5 minutes;
            if (credit <= 0.0002 ether || debt != 0) delay = 2 minutes;
            else if (sampledAt[worker] != 0) {
                uint256 old = lastCredit[worker];
                delay = old <= credit ? 1 hours :
                    (credit - 0.0002 ether) * (block.timestamp - sampledAt[worker]) / (old - credit) / 2;
                if (delay < 2 minutes) delay = 2 minutes;
                if (delay > 1 hours) delay = 1 hours;
            }
            nextCheck[worker] = block.timestamp + delay;
            sampledAt[worker] = block.timestamp;
            lastCredit[worker] = credit;
            deadline = 0;
            cursor = (cursor + 1) % 3;
            if (credit < 0.0002 ether || debt != 0)
                request(pool, worker, abi.encodeCall(FuelBank.refill, (address(0), worker, round)));
            return;
        }
        if (e.chainId != block.chainid || e.contractAddress != CLOCK || e.topic0 != TICK) return;
        bytes32 key = keccak256(abi.encode(e.blockNumber, e.txHash, e.logIndex));
        if (processedTicks[key]) return;
        processedTicks[key] = true;
        if (deadline != 0) {
            if (block.timestamp < deadline) return;
            deadline = 0;
            cursor = (cursor + 1) % 3;
            nextCheck[worker] = block.timestamp + 5 minutes;
            // Missing report: the bank rechecks this worker before paying.
            request(pool, worker, abi.encodeCall(FuelBank.refill, (address(0), worker, round)));
            return;
        }
        for (uint256 i; i < 3; ++i) {
            worker = workers[cursor];
            if (block.timestamp >= nextCheck[worker]) {
                ++round;
                deadline = block.timestamp + 3 minutes;
                request(worker, worker, abi.encodeCall(ExpenseStep.report, (address(0), round)));
                return;
            }
            cursor = (cursor + 1) % 3;
        }
    }
}
