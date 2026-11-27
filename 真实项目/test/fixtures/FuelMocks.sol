// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

contract MockSystem {
    struct Sub { uint256 chainId; address contract_; uint256 topic0; }
    Sub[] public subs;
    uint256 public unsubscribeCount;
    ISystemContract.CallbackConfiguration_V_1_0[] public requests;

    function subscribe(uint256 c, address a, uint256 t0, uint256, uint256, uint256) external { subs.push(Sub(c, a, t0)); }
    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external { unsubscribeCount++; }
    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory cfg) external { requests.push(cfg); }
    function debt(address) external pure returns (uint256) { return 0; }
    function requestCount() external view returns (uint256) { return requests.length; }
    function lastRequest() external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) { return requests[requests.length - 1]; }
    receive() external payable {}
}

contract FeeProxyFixture {
    mapping(address => uint256) public reserves;
    mapping(address => uint256) public debt;

    function owe(address who, uint256 value) external {
        debt[who] = value;
    }

    function charge(address who, uint256 value) external {
        reserves[who] -= value;
    }

    function depositTo(address who) external payable {
        uint256 paid = msg.value < debt[who] ? msg.value : debt[who];
        debt[who] -= paid;
        reserves[who] += msg.value - paid;
    }

    function deliver(address who, address sender, bytes memory payload) external {
        require(debt[who] == 0 && reserves[who] >= 1);
        assembly { mstore(add(payload, 36), sender) }
        (bool ok,) = who.call(payload);
        require(ok);
        reserves[who] -= 1; // deterministic test delivery fee
    }
}
