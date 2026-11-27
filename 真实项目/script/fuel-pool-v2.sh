#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
sep=${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}
las=${LASNA_RPC_URL:-https://lasna-rpc.rnk.dev/}
proxy=${CALLBACK_PROXY:-0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4}
dir=broadcast/fuel-bank-v2
mkdir -p "$dir"
exec 9>"$dir/lock"
flock -n 9 || { echo 'Another deployment is running'; exit 1; }
case ${1:-} in
    order|run) ;;
    *) [[ $(cast chain-id -r "$las") == 5318007 ]] ;;
esac
if [[ ${1:-} != monitor ]]; then
    [[ $(cast chain-id -r "$sep") == 11155111 ]]
fi
read_sep() { cast call -r "$sep" "$@"; }
read_las() { cast call -r "$las" "$@"; }
number() { awk '{print $1}'; }
if [[ ${1:-} == status ]]; then
    pool=$(cat "$dir/pool"); monitor=$(cat "$dir/monitor")
    echo "Pool $pool / Monitor $monitor"
    echo "Active: $(read_las "$monitor" 'active()(bool)')"
    echo "Requests: $(read_las "$monitor" 'requests()(uint256)') / 16"
    echo "Receipt: $(read_sep "$(cat "$dir/c")" 'output()(bytes32)')"
    for i in 0 1 2; do
        names=(a b c)
        w=$(cat "$dir/${names[$i]}")
        echo "Cumulative bank payment: $(read_sep "$pool" 'spent(address)(uint256)' "$w")"
        echo "$w  credit=$(read_sep "$proxy" 'reserves(address)(uint256)' "$w")  debt=$(read_sep "$proxy" 'debt(address)(uint256)' "$w")"
    done
    exit
fi
account=${FUEL_ACCOUNT:-fuel-demo}
case ${1:-} in
    order)
        [[ $# == 4 ]] || { echo 'Use order MEAL_CENTS TRAVEL_CENTS LIMIT_CENTS'; exit 2; }
        a=$(cat "$dir/a")
        [[ $(read_sep "$a" 'started()(bool)') == false ]] || { echo 'Order already submitted'; exit 1; }
        cast send -r "$sep" --account "$account" "$a" 'begin(uint128,uint128,uint128)' "$2" "$3" "$4" | tee "$dir/begin.log"
        exit ;;
    run)
        for name in a b c; do
            worker=$(cat "$dir/$name")
            if [[ $(read_sep "$worker" 'done()(bool)') == false ]]; then
                cast send -r "$sep" --account "$account" "$worker" 'complete()'
            fi
        done
        exit ;;
    start)
        monitor=$(cat "$dir/monitor")
        pool=$(cat "$dir/pool")
        objects="[$(cat "$dir/a"),$(cat "$dir/b"),$(cat "$dir/c")]"
        [[ $(read_las "$monitor" 'pool()(address)') == 0x0000000000000000000000000000000000000000 ]] || { echo 'Already initialized; see status'; exit 1; }
        cast send -r "$las" --account "$account" "$monitor" 'start(address,address[3])' "$pool" "$objects"
        exit ;;
    pause|resume)
        method=stop
        [[ $1 == pause ]] || method=resume
        cast send -r "$las" --account "$account" "$(cat "$dir/monitor")" "$method()"
        exit ;;
    deploy|monitor|a|b|c) ;;
    *) echo 'Use monitor, a, b, c, deploy, order, run, start, status, pause or resume'; exit 2 ;;
esac
if [[ $1 == deploy ]]; then
    sender=$(cast wallet address --account "$account")
    read_sep "$proxy" 'reserves(address)(uint256)' "$sender" >/dev/null
    read_sep "$proxy" 'debt(address)(uint256)' "$sender" >/dev/null
fi
deploy() {
    local name=$1 rpc=$2 contract=$3 value=$4
    shift 4
    if [[ ! -s "$dir/$name" ]]; then
        cast block-number -r "$rpc" > "$dir/$name.block"
        forge create --broadcast --account "$account" --rpc-url "$rpc" --value "$value" "$contract" "$@" | tee "$dir/$name.log"
        local addr
        addr=$(awk '/Deployed to:/ {print $3}' "$dir/$name.log")
        [[ $addr =~ ^0x[[:xdigit:]]{40}$ ]]
        echo "$addr" > "$dir/$name"
    fi
    [[ $(cast code -r "$rpc" "$(cat "$dir/$name")") != 0x ]]
}
send() {
    local rpc=$1
    shift
    cast send -r "$rpc" --account "$account" "$@"
}
if [[ $1 == deploy || $1 == monitor ]]; then
    deploy monitor "$las" src/gas-pool/IndependentMonitor.sol:IndependentMonitor 0.5ether
fi
monitor=$(cat "$dir/monitor")
if [[ $1 == monitor ]]; then
    echo "Lasna Monitor: $monitor"
    exit
fi
steps=src/gas-pool/ExpenseStepsV2.sol
if [[ $1 == deploy || $1 == a ]]; then
    deploy a "$sep" "$steps:AddExpenses" 0 --constructor-args "$proxy" "$monitor"
fi
a=$(cat "$dir/a")
if [[ $1 == a ]]; then
    echo "Sepolia A: $a"
    exit
fi
if [[ $1 == deploy || $1 == b ]]; then
    deploy b "$sep" "$steps:CheckAllowance" 0 --constructor-args "$proxy" "$monitor" "$a"
fi
b=$(cat "$dir/b")
if [[ $1 == b ]]; then
    [[ $(read_sep "$b" 'source()(address)' | tr '[:upper:]' '[:lower:]') == ${a,,} ]]
    echo "Sepolia B: $b"
    exit
fi
deploy c "$sep" "$steps:SealReceipt" 0 --constructor-args "$proxy" "$monitor" "$b"
if [[ $1 == c ]]; then
    c=$(cat "$dir/c")
    approval=$(read_sep "$c" 'approval()(address)')
    [[ ${approval,,} == ${b,,} ]]
    echo "Sepolia C: $c"
    exit
fi
objects="[$a,$b,$(cat "$dir/c")]"
deploy pool "$sep" src/gas-pool/IndependentMonitor.sol:FuelBank 0.003ether --constructor-args "$proxy" "$monitor" "$objects"
pool=$(cat "$dir/pool")
bound_monitor=$(read_sep "$pool" '_CALLBACK_SENDER()(address)')
[[ ${bound_monitor,,} == ${monitor,,} ]]
# Prepay report delivery separately from the bank principal. Idempotent setup before start.
if [[ $(read_las "$monitor" 'pool()(address)') == 0x0000000000000000000000000000000000000000 ]]; then
    for name in pool a b c; do
        target=$(cat "$dir/$name")
        goal=100000000000000
        [[ $name != pool ]] || goal=3000000000000000
        credit=$(read_sep "$proxy" 'reserves(address)(uint256)' "$target" | number)
        if (( credit < goal )); then
            send "$sep" "$proxy" 'depositTo(address)' "$target" --value "$((goal-credit))"
        fi
    done
fi
echo "Monitor $monitor / Pool $pool"
