// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {Test} from "forge-std/Test.sol";
import {MockSystem} from "./Camp.t.sol";
import {FeeProxyFixture} from "./FuelPool.t.sol";
import {IndependentMonitor, FuelBank} from "../src/gas-pool/IndependentMonitor.sol";
import {AddExpenses,CheckAllowance,SealReceipt} from "../src/gas-pool/ExpenseStepsV2.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
contract IndependentMonitorTest is Test {
    MockSystem constant sys = MockSystem(payable(0x8888888888888888888888888888888888888888));
    IndependentMonitor monitor;
    FeeProxyFixture proxy;
    FuelBank bank;
    AddExpenses a;
    CheckAllowance b;
    SealReceipt c;
    address[3] workers;
    receive() external payable {}
    function setUp() public {
        vm.chainId(5318007);
        vm.etch(address(sys),address(new MockSystem()).code);
        monitor = new IndependentMonitor();
        proxy = new FeeProxyFixture();
        IPayable p = IPayable(payable(address(proxy)));
        a = new AddExpenses(p,address(monitor));
        b = new CheckAllowance(p,address(monitor),a);
        c = new SealReceipt(p,address(monitor),b);
        workers = [address(a),address(b),address(c)];
        bank = new FuelBank{value:0.003 ether}(p,address(monitor),workers);
    }
    function tick() private {
        IReactive.LogRecord memory e;
        e.blockNumber=block.timestamp;
        e.chainId=block.chainid;
        e.contractAddress=address(uint160(16777215));
        e.topic0=0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
        vm.prank(address(sys)); monitor.react(e);
    }
    function testBusinessRunsWhileStopped() public {
        a.begin(1200,800,2500); a.complete(); b.complete(); c.complete();
        assertEq(uint256(a.output()),2000); assertEq(uint256(b.output()),1);
        assertTrue(c.done()); assertEq(monitor.requests(),0);
    }
    function testReportAndSinglePayment() public {
        monitor.start(address(bank),workers); tick();
        assertEq(sys.lastRequest().recipient,address(a));
        proxy.depositTo{value:10}(address(a));
        vm.expectEmit(true,false,false,true,address(a));
        emit FuelReport(1,10,0);
        proxy.deliver(address(a),address(monitor),sys.lastRequest().payload);
        IReactive.LogRecord memory e;
        e.chainId=11155111; e.contractAddress=address(a);
        e.topic0=uint256(keccak256("FuelReport(uint256,uint256,uint256)"));
        e.topic1=1; e.data=abi.encode(10,0);
        vm.prank(address(sys)); monitor.react(e);
        assertEq(sys.lastRequest().recipient,address(bank));
        proxy.depositTo{value:10}(address(bank));
        proxy.deliver(address(bank),address(monitor),sys.lastRequest().payload);
        assertEq(proxy.reserves(address(a)),0.001 ether);
        assertEq(bank.spent(address(b)),0);
        vm.prank(address(sys)); monitor.react(e);
        assertEq(sys.requestCount(),2);
    }
    event FuelReport(uint256 indexed round,uint256 credit,uint256 debt);
    function testTimeoutDoesNotOverfundHealthyWorker() public {
        monitor.start(address(bank),workers); tick();
        vm.warp(block.timestamp+3 minutes); tick();
        assertEq(sys.lastRequest().recipient,address(bank));
        proxy.depositTo{value:0.001 ether}(address(a));
        proxy.depositTo{value:10}(address(bank));
        proxy.deliver(address(bank),address(monitor),sys.lastRequest().payload);
        assertEq(bank.spent(address(a)),0);
        monitor.stop(); tick(); assertEq(sys.requestCount(),2);
    }
    function testBankAutomaticallyFundsOwnFeesAndSkipsHealthyReserve() public {
        vm.prank(address(proxy)); bank.refill(address(monitor),address(a),1);
        assertEq(proxy.reserves(address(bank)),bank.FEE_TOPUP_CAP());
        uint256 balance = address(bank).balance;
        bank.maintainFeeReserve();
        assertEq(address(bank).balance,balance);
        assertEq(bank.feeSpent(),bank.FEE_TOPUP_CAP());
    }
    function testFeeBudgetAndEmptyBankRecovery() public {
        bank.withdraw(address(bank).balance);
        bank.maintainFeeReserve();
        assertEq(bank.feeSpent(),0);
        (bool ok,) = address(bank).call{value:0.002 ether}("");
        assertTrue(ok);
        proxy.owe(address(bank),0.002 ether);
        for (uint256 i; i < 6; ++i) bank.maintainFeeReserve();
        assertEq(bank.feeSpent(),bank.FEE_BUDGET());
        assertEq(proxy.debt(address(bank)),0.001 ether);
    }
    function testWrongCallerAndUnlistedWorkerBlocked() public {
        vm.expectRevert(); bank.refill(address(monitor),address(a),1);
        vm.prank(address(proxy)); vm.expectRevert(); bank.refill(address(7),address(a),1);
        vm.prank(address(proxy)); vm.expectRevert(); bank.refill(address(monitor),address(7),1);
        assertEq(bank.feeSpent(),0);
    }
    function testDuplicateAndLaterRoundsCannotExceedWorkerBudget() public {
        vm.startPrank(address(proxy));
        bank.refill(address(monitor),address(a),1);
        proxy.charge(address(a),bank.TARGET());
        bank.refill(address(monitor),address(a),1);
        bank.refill(address(monitor),address(a),2);
        vm.stopPrank();
        assertEq(bank.spent(address(a)),bank.TARGET());
        assertEq(proxy.reserves(address(a)),0);
    }    function testBankEmptyReportPausesAndReplayAfterResumeIsIgnored() public {
        monitor.start(address(bank),workers); tick();
        IReactive.LogRecord memory e;
        e.chainId=11155111; e.contractAddress=address(bank);
        e.topic0=uint256(keccak256("BankEmpty(uint256)")); e.topic1=1;
        vm.prank(address(sys)); monitor.react(e);
        assertFalse(monitor.active());
        monitor.resume();
        vm.prank(address(sys)); monitor.react(e);
        assertTrue(monitor.active());
    }}

