// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

interface ICredits { function reserves(address target) external view returns (uint256); }

abstract contract ExpenseStep is AbstractCallback {
    bool public done;
    bytes32 public output;
    event StepCompleted(uint256 indexed stage, bytes32 result);
    constructor(IPayable proxy, address monitor) AbstractCallback(proxy, monitor) {}

    event FuelReport(uint256 indexed round, uint256 credit, uint256 debt);

    function report(address sender, uint256 round) external onlyServiceProvider onlyCallbackSender(sender) {
        address self = address(this);
        emit FuelReport(round, ICredits(address(_SERVICE_PROVIDER)).reserves(self), _SERVICE_PROVIDER.debt(self));
    }

    function execute(address sender) external onlyServiceProvider onlyCallbackSender(sender) { complete(); }
    function complete() public {
        if (!done) {
            output = compute();
            done = true;
        }
        // Re-acknowledge a lost receipt without executing the business step twice.
        emit StepCompleted(index(), output);
    }
    function compute() internal view virtual returns (bytes32);
    function index() internal pure virtual returns (uint256);
}

contract AddExpenses is ExpenseStep {
    address public immutable owner;
    bool public started;
    uint256 public meal;
    uint256 public travel;
    uint256 public allowance;

    constructor(IPayable p, address m) ExpenseStep(p, m) {
        owner = msg.sender;
    }

    function begin(uint128 a, uint128 b, uint128 limit) external {
        require(msg.sender == owner && !started);
        started = true;
        meal = a;
        travel = b;
        allowance = limit;
    }

    function index() internal pure override returns (uint256) {
        return 0;
    }

    function compute() internal view override returns (bytes32) {
        require(started);
        return bytes32(meal + travel);
    }
}

contract CheckAllowance is ExpenseStep {
    AddExpenses public immutable source;

    constructor(IPayable p, address m, AddExpenses a) ExpenseStep(p, m) {
        source = a;
    }

    function index() internal pure override returns (uint256) {
        return 1;
    }

    function compute() internal view override returns (bytes32) {
        require(source.done());
        return bytes32(uint256(source.output()) <= source.allowance() ? uint256(1) : 0);
    }
}

contract SealReceipt is ExpenseStep {
    CheckAllowance public immutable approval;

    constructor(IPayable p, address m, CheckAllowance b) ExpenseStep(p, m) {
        approval = b;
    }

    function index() internal pure override returns (uint256) {
        return 2;
    }

    function compute() internal view override returns (bytes32) {
        require(approval.done());
        AddExpenses a = approval.source();
        return keccak256(abi.encode(block.chainid, address(a), a.output(), approval.output()));
    }
}
