// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/MetaNode.sol";
import "../src/MetaNodeStake.sol";
import "../src/TestERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
// IAccessControl 是"声明错误的地方":AccessControlUnauthorizedAccount 这个错误
// 定义在 IAccessControl 接口里(不是 AccessControlUpgradeable 里),必须通过它来引用
import {IAccessControl} from "../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";


contract MetaNodeStakeTest is Test {
    // 1.全局变量
    MetaNodeStake public stake;
    MetaNodeToken public rewardToken;
    TestERC20 public stakingToken;

    address public admin = makeAddr("admin");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");

    uint256 constant public PER_BLOCK = 100; // 每块总奖励100 wei
    uint256 constant public LOCK_BLOCKS = 10; // 解压锁定的区块个数

    // 2.写setUp函数，在每个测试前执行
    function setUp() public {
        // 思路：先部署质押合约，然后部署奖励代币合约，再然后将奖励代币合约铸造的所有代币转移给质押合约，再然后部署测试用的ERC20合约
        vm.startPrank(admin);
        vm.deal(admin, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);
        MetaNodeStake impl = new MetaNodeStake();
        rewardToken = new MetaNodeToken();
        stakingToken = new TestERC20("Test Stake Token", "TST", 1000000 ether);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(MetaNodeStake.initialize, (rewardToken, 1, 1_000_000, PER_BLOCK))
        );
        stake = MetaNodeStake(address(proxy));
        rewardToken.transfer(address(stake), 1_000_000 ether);
        stake.addPool(address(0), 5, 1e15, LOCK_BLOCKS, false);
        stake.addPool(address(stakingToken), 5, 1e15, LOCK_BLOCKS, false);
        stakingToken.transfer(address(user1), 100 ether);
        stakingToken.transfer(address(user2), 100 ether);
        stakingToken.transfer(address(user3), 100 ether);
        vm.stopPrank();
    }
    // 3.针对每个可能的合约方法创建对应的测试用例

    // 测试提取利息
    function test_claim() public {
        vm.startPrank(user1);
        // 抵押一定的eth给质押合约
        stake.depositETH{value: 10 ether}();
        // 然后让区块走10个
        vm.roll(block.number + 10);
        // 然后获取claim之前的利息和所在metaNode代币合约的金额
        uint256 pendingBefore = stake.pendingMetaNode(0, user1);
        uint256 rewardBefore = rewardToken.balanceOf(user1);
        // 执行claim操作
        stake.claim(0);
        // 然后再获取claim之后的利息和所在metanode代币合约的金额
        uint256 pendingAfter = stake.pendingMetaNode(0, user1);
        uint256 rewardAfter = rewardToken.balanceOf(user1);
        console2.log(unicode"claim 后的待领利息", pendingBefore);
        console2.log(unicode"claim 后的实际到账", rewardAfter - rewardBefore);
        // 最后做对比，金额claim后-前 >= 利息claim前
        assert(rewardAfter - rewardBefore >= pendingBefore);
        assertEq(pendingAfter, 0);
        vm.stopPrank();
    }

    // 测试质押ETH操作正常路径
    function test_depositETH() public {
        // 先记录user1没抵押之前的金额
        uint256 stakeBeforeBalance = address(user1).balance;
        vm.prank(user1);
        // 执行抵押操作
        stake.depositETH{value: 10 ether}();
        // 校验合约收到抵押的ETH
        assertEq(address(stake).balance, 10 ether);
        // 校验user1在抵押合约中的余额为10
        assertEq(stake.stakingBalance(0, user1), 10 ether);

        vm.prank(user1);
        stake.depositETH{value: 5 ether}();
        assertEq(stake.stakingBalance(0, user1), 15 ether);
        assertEq(address(user1).balance, stakeBeforeBalance - 15 ether);
    }

    // 测试质押ETH
    function test_depositETH_minAmount() public {
        vm.startPrank(user1);
        uint256 stakeBeforeBalance = address(user1).balance;
        stake.depositETH{value: 1e15}();
        assertEq(stake.stakingBalance(0, user1), 1e15);
        assertEq(address(user1).balance, stakeBeforeBalance - 1e15);
        vm.expectRevert("deposit amount is too small");
        stake.depositETH{value: 1e15 - 1}();
        vm.stopPrank();
    }

    // 测试质押ERC20
    function test_depositERC20() public {
        vm.startPrank(user1);
        console2.log("stake address:", address(stake));
        vm.expectRevert("deposit not support ETH staking");
        stake.deposit(0, 100);
        vm.expectRevert("deposit amount is too small");
        stake.deposit(1, 1);
        vm.expectRevert(abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientAllowance.selector,
            address(stake),
            0,
            1 ether
        ));
        stake.deposit(1, 1 ether);

        stakingToken.approve(address(stake), 1 ether);
        stake.deposit(1, 1 ether);
        assertEq(stakingToken.allowance(address(user1), address(stake)), 0, unicode"授权应该恰好被用完");
        assertEq(stake.stakingBalance(1, address(user1)), 1 ether);
        assertEq(stakingToken.balanceOf(address(stake)), 1 ether);
        assertEq(stakingToken.balanceOf(address(user1)), 99 ether);
        vm.stopPrank();
    }

    // ==================== unstake 测试 ====================

    // ----- 第一组：正常路径 -----

    /// 池 0（ETH 池）部分解押 6 ether
    /// 断言清单：
    ///   1. user(0,user1).stAmount == 4 ether
    ///   2. withdrawAmount(0,user1) == (6 ether, 0)   // 解押了6个，可领取的奖励代币是0个
    ///   3. pool(0) 的 stTokenAmount 减少 6 ether      // 解构第 5 个返回值
    ///   4. address(stake).balance 不变                // 解押不转账，钱还在合约
    ///   5. expectEmit 校验 RequestUnstake(user1, 0, 6 ether)
    function test_unstake_eth() public {
        // 准备：prank(user1) → depositETH{value: 10 ether} → vm.roll(block.number + 1)
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        vm.roll(block.number + 1);
        vm.expectEmit(true, true, false, true, address(stake));
        emit MetaNodeStake.RequestUnstake(user1, 0, 6 ether);
        uint256 balanceBefore = address(stake).balance;
        (
            ,
            ,
            ,
            ,
            uint256 stTokenAmountBefore,
            ,

        ) = stake.pool(0);

        stake.unstake(0, 6 ether);
        uint256 balanceAfter = address(stake).balance;
        // 执行：stake.unstake(0, 6 ether)
        (uint256 stAmount,,) = stake.user(0, user1);
        assertEq(stAmount, 4 ether, unicode"抵押了6 ether，这里应该只剩下4 ether");
        (uint256 requestAmount, uint256 pendingWithdrawAmount) = stake.withdrawAmount(0, user1);
        assertEq(requestAmount, 6 ether, unicode"解押申请总额应为 6 ether");
        assertEq(pendingWithdrawAmount, 0, unicode"锁定 10 块内，可提现应为 0");
        (
            ,
            ,
            ,
            ,
            uint256 stTokenAmountAfter,
            ,

        ) = stake.pool(0);
        assertEq(balanceBefore, balanceAfter, unicode"解押前后池子的余额不会发生改变");
        assertEq(stTokenAmountAfter, stTokenAmountBefore - 6 ether, unicode"池子抵押总量应减少6 ether");
        // 走完锁定期再查一次，验证 unlockBlocks 确实记录的是 N+10
        vm.roll(block.number + LOCK_BLOCKS);
        (, uint256 unlocked) = stake.withdrawAmount(0, user1);
        assertEq(unlocked, 6 ether, unicode"锁定期过后应全部解锁");
        vm.stopPrank();
    }

    /// 池 1（ERC20 池）部分解押 5 ether，断言逻辑同上
    /// 核心要测试的其实就是解质押都改了哪些状态变量，这些状态变量的变化是否符合预期
    /// 这个方法都改了pool的stTokenAmount  User的stAmount、pendingMetaNode、UnstakeRequest的所有字段值
    function test_unstake_erc20() public {
        vm.startPrank(user1);
        stakingToken.approve(address(stake), 5 ether);
        stake.deposit(1, 5 ether);


        uint256 balanceBefore = stakingToken.balanceOf(address(stake));
        (uint256 requestAmountBefore, uint256 pendingWithdrawAmountBefore) = stake.withdrawAmount(1, address(user1));
        (
            ,
            ,
            ,
            ,
            uint256 stTokenAmountBefore,
            ,

        ) = stake.pool(1);

        vm.roll(block.number + 1);
        vm.expectEmit(true, true, false, true, address(stake));
        emit MetaNodeStake.RequestUnstake(user1, 1, 4 ether);
        stake.unstake(1, 4 ether);
        uint256 balanceAfter = stakingToken.balanceOf(address(stake));
        (uint256 requestAmountAfter, uint256 pendingWithdrawAmountAfter) = stake.withdrawAmount(1, address(user1));
        (
            ,
            ,
            ,
            ,
            uint256 stTokenAmountAfter,
            ,

        ) = stake.pool(1);
        (uint256 stAmount,,uint256 pendingMetaNode) = stake.user(1, user1);
        assertEq(balanceBefore, balanceAfter, unicode"解质押前后合约的余额保持不变");
        assertEq(stAmount, 1 ether, unicode"解质押后的用户的抵押amount值应该减少4 ether");
        assertEq(pendingWithdrawAmountBefore, 0, unicode"解押前可提现应为 0");
        assertEq(pendingWithdrawAmountAfter, 0, unicode"锁定期内可提现应为 0");
        assertEq(requestAmountAfter - requestAmountBefore, 4 ether, unicode"请求解押前后用户的amount值为4 ether");
        assertEq(stTokenAmountBefore - stTokenAmountAfter, 4 ether, unicode"合约收到的ERC20代币也得减少4 ether");
        assertEq(pendingMetaNode, 50, unicode"解押时应把已产生的奖励结算进 pendingMetaNode");
        vm.roll(block.number + LOCK_BLOCKS);
        (, uint256 pendingWithdrawAmountNew) = stake.withdrawAmount(1, user1);
        assertEq(pendingWithdrawAmountNew, 4 ether, unicode"解押时间到了 可以提取4 ether代币了");
        vm.stopPrank();
    }

/// 全额解押 10 ether：stAmount == 0、requestAmount == 10 ether
    function test_unstake_all() public {
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        vm.roll(block.number + 1);
        uint256 balanceBefore = address(stake).balance;
        (
            ,
            ,
            ,
            ,
            uint256 stTokenAmountBefore,
            ,

        ) = stake.pool(0);
        vm.expectEmit(true, true, false, true, address(stake));
        emit MetaNodeStake.RequestUnstake(user1, 0, 10 ether);
        stake.unstake(0, 10 ether);
        uint256 balanceAfter = address(stake).balance;
        (uint256 stAmount,,) = stake.user(0, user1);
        assertEq(stAmount, 0 ether, unicode"抵押了10 ether，这里应该只剩下0 ether");
        (uint256 requestAmount, uint256 pendingWithdrawAmount) = stake.withdrawAmount(0, user1);
        assertEq(requestAmount, 10 ether, unicode"解押申请总额应为 10 ether");
        assertEq(pendingWithdrawAmount, 0, unicode"锁定 10 块内，可提现应为 0");
        (
            ,
            ,
            ,
            ,
            uint256 stTokenAmountAfter,
            ,

        ) = stake.pool(0);
        assertEq(balanceBefore, balanceAfter, unicode"解押前后池子的余额不会发生改变");
        assertEq(stTokenAmountAfter, stTokenAmountBefore - 10 ether, unicode"池子抵押总量应减少10 ether");
        // 走完锁定期再查一次，验证 unlockBlocks 确实记录的是 N+10
        vm.roll(block.number + LOCK_BLOCKS);
        (, uint256 pendingWithdrawAmountAfter) = stake.withdrawAmount(0, user1);
        assertEq(pendingWithdrawAmountAfter, 10 ether, unicode"锁定期过后应全部解锁");
        vm.stopPrank();
    }

/// 同池连续解押两次（2 + 3）：requestAmount 累加到 5 ether、stAmount 减到 5 ether
    function test_unstake_multiple() public {
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        vm.roll(block.number + 1);
        uint256 balanceBefore = address(stake).balance;
        (
            ,
            ,
            ,
            ,
            uint256 stTokenAmountBefore,
            ,

        ) = stake.pool(0);
        vm.expectEmit(true, true, false, true, address(stake));
        emit MetaNodeStake.RequestUnstake(user1, 0, 4 ether);
        stake.unstake(0, 4 ether);
        stake.unstake(0, 1 ether);
        uint256 balanceAfter = address(stake).balance;
        (uint256 stAmount,,) = stake.user(0, user1);
        assertEq(stAmount, 5 ether, unicode"解押了5 ether，这里应该只剩下5 ether");
        (uint256 requestAmount, uint256 pendingWithdrawAmount) = stake.withdrawAmount(0, user1);
        assertEq(requestAmount, 5 ether, unicode"解押申请总额应为 5 ether");
        assertEq(pendingWithdrawAmount, 0, unicode"锁定 10 块内，可提现应为 0");
        (
            ,
            ,
            ,
            ,
            uint256 stTokenAmountAfter,
            ,

        ) = stake.pool(0);
        assertEq(balanceBefore, balanceAfter, unicode"解押前后池子的余额不会发生改变");
        assertEq(stTokenAmountAfter, stTokenAmountBefore - 5 ether, unicode"池子抵押总量应减少5 ether");
        // 走完锁定期再查一次，验证 unlockBlocks 确实记录的是 N+10
        vm.roll(block.number + LOCK_BLOCKS);
        (, uint256 pendingWithdrawAmountAfter) = stake.withdrawAmount(0, user1);
        assertEq(pendingWithdrawAmountAfter, 5 ether, unicode"锁定期过后应全部解锁");
        vm.stopPrank();
    }

// ----- 第二组：边界值 -----

/// amount = 0：合法不 revert，但什么都不该发生
/// 断言：stAmount 不变、withdrawAmount 前后都是 (0, 0)
    function test_unstake_zero() public {
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        vm.roll(block.number + 1);
        (
            ,
            ,
            ,
            ,
            uint256 stTokenAmountBefore,
            ,

        ) = stake.pool(0);


        stake.unstake(0, 0 ether);

        (
            ,
            ,
            ,
            ,
            uint256 stTokenAmountAfter,
            ,

        ) = stake.pool(0); // 池子中ETH总抵押个数

        assertEq(stTokenAmountBefore, stTokenAmountAfter, unicode"解押前后stake合约池子0前后ETH余额保持不变");
        assertEq(stTokenAmountBefore, 10 ether, unicode"解押前后user1前后ETH余额保持不变");
        vm.stopPrank();
    }

/// amount 恰好等于 stAmount（10 ether）：合法解完，stAmount == 0、requestAmount == 10 ether
    function test_unstake_exact() public {
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        vm.roll(block.number + 1);

        stake.unstake(0, 10 ether);

        (
            ,
            ,
            ,
            ,
            uint256 stTokenAmount,
            ,

        ) = stake.pool(0);
        (uint256 requestAmount,) = stake.withdrawAmount(0, user1);
        assertEq(stTokenAmount, 0, unicode"解押后池子中的抵押ETH值应该为0");
        assertEq(requestAmount, 10 ether, unicode"解押请求中requestAmount的值应该为10 ether");
        vm.stopPrank();
    }

// ----- 第三组：异常路径 -----

/// pid 越界（setUp 只建了池 0 和 1，传 2）
/// vm.expectRevert("invalid pid"); stake.unstake(2, 1 ether);
    function test_unstake_revertWhen_invalidPid() public {
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        vm.roll(block.number + 1);
        vm.expectRevert("invalid pid");
        stake.unstake(2, 1 ether);
        vm.stopPrank();
    }

/// 超额解押：先押 10，再解 11
/// vm.expectRevert("Not enough staking token balance");
    function test_unstake_revertWhen_insufficient() public {
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        vm.roll(block.number + 1);
        vm.expectRevert("Not enough staking token balance");
        stake.unstake(0, 11 ether);
        vm.stopPrank();
    }

/// 合约全局暂停：vm.prank(admin); stake.pause(); 后解押
/// vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    function test_unstake_revertWhen_paused() public {
        vm.prank(admin);
        stake.pause();
        vm.startPrank(user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stake.depositETH{value: 10 ether}();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stake.unstake(0, 1 ether);
        vm.stopPrank();
    }

/// 提现暂停：vm.prank(admin); stake.pauseWithdraw(); 后解押
/// vm.expectRevert("withdraw is paused");
    function test_unstake_revertWhen_withdrawPaused() public {
        vm.prank(admin);
        stake.pauseWithdraw();
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        vm.expectRevert("withdraw is paused");
        stake.unstake(0, 1 ether);
        vm.stopPrank();
    }

// ----- 第四组：奖励结算 -----

/// 解押时未领奖励转入暂存：押 10 → roll 1 块 → 解押
/// 断言：user(0,user1).pendingMetaNode == 50（1 块 × 100 wei × 权重 5/10，user1 独占）
/// 注意：质押时同样记一下 finishedMetaNode 的变化，理解"结算基准线重算"
    function test_unstake_pendingReward() public {
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        vm.roll(block.number + 1);
        stake.unstake(0, 10 ether);
        (,,uint256 pendingMetaNode) = stake.user(0, user1);
        assertEq(pendingMetaNode, 50, unicode"解质押10eth，获得的pending代币个数为：50"); // 每块总奖励100 wei 但是因为两个池子各分1/2权重，所以这里是50 wei
        vm.stopPrank();
    }

    // ==================== withdraw 测试 ====================

    // 正常测试：还没在提取区块范围的时候，执行提取操作，合约余额和用户余额不会发生变化
    function test_withdraw_lock() public {
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        vm.roll(block.number + 1);
        stake.unstake(0, 10 ether);
        uint256 userBalanceBefore = address(user1).balance;
        uint256 stakeBalanceBefore = address(stake).balance;
        (uint256 requestAmountBefore, uint256 pendingWithdrawAmountBefore) = stake.withdrawAmount(0, user1);

        assertEq(requestAmountBefore, 10 ether, unicode"提取前用户解押代币数为 10 ether");
        assertEq(pendingWithdrawAmountBefore, 0 ether, unicode"提取前用户解押代币数为 0 ether");
        stake.withdraw(0);

        uint256 userBalanceAfter = address(user1).balance;
        uint256 stakeBalanceAfter = address(stake).balance;
        (uint256 requestAmountAfter, uint256 pendingWithdrawAmountAfter) = stake.withdrawAmount(0, user1);


        assertEq(userBalanceBefore, userBalanceAfter, unicode"合约还未到达可提取的时间，因此前后操作用户余额不变");
        assertEq(stakeBalanceBefore, stakeBalanceAfter, unicode"合约还未到达可提取的时间，因此前后操作合约余额不变");
        assertEq(requestAmountAfter, 10 ether, unicode"提取后用户解押代币数为 10 ether");
        assertEq(pendingWithdrawAmountAfter, 0 ether, unicode"提取后用户解押代币数为 0 ether");
        vm.stopPrank();
    }

    function test_withdraw_eth_unlock() public {
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        vm.roll(block.number + 1);
        stake.unstake(0, 10 ether);
        uint256 userBalanceBefore = address(user1).balance;
        uint256 stakeBalanceBefore = address(stake).balance;
        (uint256 requestAmountBefore, uint256 pendingWithdrawAmountBefore) = stake.withdrawAmount(0, user1);

        assertEq(requestAmountBefore, 10 ether, unicode"提取前用户解押代币数为 10 ether");
        assertEq(pendingWithdrawAmountBefore, 0 ether, unicode"提取前用户解押代币数为 0 ether");
        vm.roll(block.number + LOCK_BLOCKS);
        (uint256 requestAmountAfter, uint256 pendingWithdrawAmountAfter) = stake.withdrawAmount(0, user1);
        assertEq(requestAmountAfter, 10 ether, unicode"提取后用户解押代币数为 10 ether");
        assertEq(pendingWithdrawAmountAfter, 10 ether, unicode"提取后用户解押代币数为 10 ether");

        stake.withdraw(0);

        uint256 userBalanceAfter = address(user1).balance;
        uint256 stakeBalanceAfter = address(stake).balance;


        assertEq(userBalanceBefore + 10 ether, userBalanceAfter, unicode"合约已到达可提取的时间，因此前后操作用户余额差值为10 ether");
        assertEq(stakeBalanceBefore - 10 ether, stakeBalanceAfter, unicode"合约已到达可提取的时间，因此前后操作合约余额差值为10 ether");

        (uint256 requestAmountNew, uint256 pendingWithdrawAmountNew) = stake.withdrawAmount(0, user1);
        assertEq(requestAmountNew, 0 ether, unicode"提取后用户解押代币数为 0 ether");
        assertEq(pendingWithdrawAmountNew, 0 ether, unicode"提取后用户解押代币数为 0 ether");
        vm.stopPrank();
    }

    function test_withdraw_erc20_unlock() public {
        vm.startPrank(user1);
        stakingToken.approve(address(stake), 10 ether);
        stake.deposit(1, 10 ether);
        vm.roll(block.number + 1);
        stake.unstake(1, 10 ether);

        uint256 userBalanceBefore = stakingToken.balanceOf(address(user1));
        uint256 stakeBalanceBefore = stakingToken.balanceOf(address(stake));
        (uint256 requestAmountBefore, uint256 pendingWithdrawAmountBefore) = stake.withdrawAmount(1, user1);

        assertEq(requestAmountBefore, 10 ether, unicode"提取前用户解押代币数为 10 ether");
        assertEq(pendingWithdrawAmountBefore, 0 ether, unicode"提取前用户解押代币数为 0 ether");
        vm.roll(block.number + LOCK_BLOCKS);
        (uint256 requestAmountAfter, uint256 pendingWithdrawAmountAfter) = stake.withdrawAmount(1, user1);
        assertEq(requestAmountAfter, 10 ether, unicode"提取后用户解押代币数为 10 ether");
        assertEq(pendingWithdrawAmountAfter, 10 ether, unicode"提取后用户解押代币数为 10 ether");

        stake.withdraw(1);

        uint256 userBalanceAfter = stakingToken.balanceOf(address(user1));
        uint256 stakeBalanceAfter = stakingToken.balanceOf(address(stake));


        assertEq(userBalanceBefore + 10 ether, userBalanceAfter, unicode"合约已到达可提取的时间，因此前后操作用户余额差值为10 ether");
        assertEq(stakeBalanceBefore - 10 ether, stakeBalanceAfter, unicode"合约已到达可提取的时间，因此前后操作合约余额差值为10 ether");

        (uint256 requestAmountNew, uint256 pendingWithdrawAmountNew) = stake.withdrawAmount(1, user1);
        assertEq(requestAmountNew, 0 ether, unicode"提取后用户解押代币数为 0 ether");
        assertEq(pendingWithdrawAmountNew, 0 ether, unicode"提取后用户解押代币数为 0 ether");
        vm.stopPrank();
    }

    // 部分到期只提一半存 10 → 解押 2 →
    // roll 几块但别走完 → 再解押 3(它的解锁块比第一笔晚 10 块) →
    // roll 到“第一笔到期、第二笔没到期”的位置 → withdraw。
    // 断言：只转出 2;withdrawAmount 变成 (3 ether, 0)。
    // 再 roll 过第二笔的解锁块，再 withdraw,又转 3,归 (0, 0)。
    function test_withdraw_half() public {
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        uint256 anchor = block.number;
        vm.roll(anchor + 1);
        stake.unstake(0, 2 ether);

        (uint256 requestAmountFirst, uint256 pendingWithdrawAmountFirst) = stake.withdrawAmount(0, user1);
        assertEq(requestAmountFirst, 2 ether, unicode"第一次提取2 ether，requestAmountFirst应为2 etehr");
        assertEq(pendingWithdrawAmountFirst, 0 ether, unicode"第一次提取2 ether，pendingWithdrawAmountFirst 应为0 etehr");
        vm.roll(anchor + 1 + LOCK_BLOCKS);
        stake.unstake(0, 3 ether);

        (uint256 requestAmountSec, uint256 pendingWithdrawAmountSec) = stake.withdrawAmount(0, user1);
        assertEq(requestAmountSec, 5 ether, unicode"第一次提取2 ether，requestAmountSec应为5 etehr");
        assertEq(pendingWithdrawAmountSec, 2 ether, unicode"第一次提取2 ether，pendingWithdrawAmountSec 应为0 etehr");
        stake.withdraw(0);
        vm.roll(anchor + 1 + LOCK_BLOCKS + LOCK_BLOCKS);
        (uint256 ra, uint256 pwa) = stake.withdrawAmount(0, user1);
        console2.log(unicode"-----  ra :", ra);
        console2.log(unicode"-----  pwa :", pwa);
        (uint256 requestAmountThree, uint256 pendingWithdrawAmountThree) = stake.withdrawAmount(0, user1);
        console2.log(unicode"第一次提取抵押的2个ether奖励时，requestAmountThree：", requestAmountThree);
        console2.log(unicode"第一次提取抵押的2个ether奖励时，pendingWithdrawAmountThree：", pendingWithdrawAmountThree);

        assertEq(requestAmountThree, 3 ether, unicode"第一次提取的份额已经被取走，因此正常应该只剩下第二次能够提取的3 ether");
        assertEq(pendingWithdrawAmountThree, 3 ether, unicode"第一次提取的份额已经被取走 pendingWithdrawAmountThree应该是3 ether 因为区块走到了能提取的时间了");

        stake.withdraw(0);

        (uint256 r, uint256 p) = stake.withdrawAmount(0, user1);
        assertEq(r, 0, unicode"最后再验证下r应该是0");
        assertEq(p, 0, unicode"最后再验证下p应该是0");
        vm.stopPrank();
    }

    // 测试暂停
    function test_withdraw_paused() public {
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        uint256 anchor = block.number;
        vm.roll(anchor + 1);
        stake.unstake(0, 2 ether);
        vm.stopPrank();
        vm.prank(admin);
        stake.pause();
        vm.prank(user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stake.withdraw(0);
        vm.prank(admin);
        stake.unpause();
        vm.prank(admin);
        stake.pauseWithdraw();
        vm.prank(user1);
        vm.expectRevert("withdraw is paused");
        stake.withdraw(0);
    }

    // 测试正常提取流程
    function test_claim_basic() public {
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        uint256 anchor = block.number;
        vm.roll(anchor + 1);

        // 事件测试
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.Claim(user1, 0, 50);
        stake.claim(0);
        uint256 balanceAfter = rewardToken.balanceOf(address(user1));
        (,uint256 finishedMetaNode,) = stake.user(0, user1);
        assertGt(finishedMetaNode, 0, unicode"finishedMetaNode此刻应该大于0");
        assertEq(balanceAfter, 50, unicode"经过一个区块儿后，用户一的奖励代币值为50。");

        vm.stopPrank();
    }

    function test_claim_twice_second_is_zero() public {
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        uint256 anchor = block.number;
        vm.roll(anchor + 1);

        // 事件测试
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.Claim(user1, 0, 50);
        stake.claim(0);
        uint256 balanceAfter = rewardToken.balanceOf(address(user1));
        (,uint256 finishedMetaNode,) = stake.user(0, user1);
        assertGt(finishedMetaNode, 0, unicode"finishedMetaNode此刻应该大于0");
        assertEq(balanceAfter, 50, unicode"经过一个区块儿后，用户一的奖励代币值为50。");

        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.Claim(user1, 0, 0);
        stake.claim(0);

        vm.stopPrank();
    }

    // 如果奖励率设计的太小，那么计算的时候就容易有精度损耗
    function test_claim_two_user_share() public {
        vm.prank(user1);
        stake.depositETH{value: 10 ether}();

        vm.prank(user2);
        stake.depositETH{value: 10 ether}();

        uint256 anchor = block.number;
        vm.roll(anchor + 1);

        vm.prank(user1);
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.Claim(user1, 0, 20);
        stake.claim(0);
        uint256 metaNodeUser1 = rewardToken.balanceOf(address(user1));
        assertEq(metaNodeUser1, 20, unicode"由于奖励率设置的原因，在计算奖励的时候发生了截断，因此每个人不是获得25，而是20");

        vm.prank(user2);
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.Claim(user2, 0, 20);
        stake.claim(0);
        uint256 metaNodeUser2 = rewardToken.balanceOf(address(user1));
        assertEq(metaNodeUser2, 20, unicode"由于奖励率设置的原因，在计算奖励的时候发生了截断，因此每个人不是获得25，而是20");
    }


    function test_claim_after_unstake() public {
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        uint256 anchor = block.number;
        vm.roll(anchor + 1);
        stake.unstake(0, 6 ether);

        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.Claim(user1, 0, 50);
        stake.claim(0);

        (uint256 requestAmount, uint256 pendingWithdrawAmount) = stake.withdrawAmount(0, user1);
        assertEq(requestAmount, 6 ether, unicode"请求提取的eth应为6ether");
        assertEq(pendingWithdrawAmount, 0, unicode"当前可提取的eth应为0");

        vm.roll(anchor + 1 + LOCK_BLOCKS);

        (uint256 requestAmount2, uint256 pendingWithdrawAmount2) = stake.withdrawAmount(0, user1);
        assertEq(requestAmount2, 6 ether, unicode"请求提取的eth应为6 ether");
        assertEq(pendingWithdrawAmount2, 6 ether, unicode"当前可提取的eth应为6 ether");
        vm.stopPrank();
    }

    function test_claim_no_stake_gets_zero() public {
        vm.startPrank(user1);

        uint256 a = rewardToken.balanceOf(address(user1));

        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.Claim(user1, 0, 0);
        stake.claim(0);

        uint256 b = rewardToken.balanceOf(address(user1));

        assertEq(a, b, unicode"因为什么都没质押所以前后余额应该相同");
        assertEq(a, 0, unicode"因为什么都没质押所以前余额应该为0");
        assertEq(b, 0, unicode"因为什么都没质押所以后余额应该为0");
        vm.stopPrank();
    }

    // --------------admin test--------------------
    // admin 测试的通用套路:每个函数测三件事
    //   ① 权限:非 admin 调用必须 revert(AccessControl 拦截)
    //   ② happy path:admin 调用成功 → 状态变量改变 + 事件正确发出
    //   ③ 业务校验:非法参数必须 revert(合约里的 require 分支)

    // ---------- 全局暂停/恢复 ----------

    function test_pause() public {
        // ① 权限:user1 不是 admin,必须被拦
        vm.prank(user1);
        vm.expectRevert();
        stake.pause();

        // ② happy path:admin 暂停后,paused() 变为 true(OZ 自带 Paused 事件)
        vm.prank(admin);
        stake.pause();
        assertTrue(stake.paused(), unicode"admin 暂停后 paused() 应为 true");

        // 暂停的效果:业务函数被 whenNotPaused 拦截
        vm.prank(user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stake.depositETH{value: 1 ether}();

        // ③ 重复暂停:_pause() 带 whenNotPaused 修饰器,抛 EnforcedPause
        //    (ExpectedPause 是"未暂停却 unpause"时才抛的,见 test_unpause)
        vm.prank(admin);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stake.pause();
    }

    function test_unpause() public {
        // ③ 未暂停就 unpause:revert ExpectedPause
        vm.prank(admin);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        stake.unpause();

        // ② pause → unpause → 状态恢复,业务函数可用
        vm.startPrank(admin);
        stake.pause();
        stake.unpause();
        vm.stopPrank();
        assertFalse(stake.paused(), unicode"恢复后 paused() 应为 false");

        vm.prank(user1);
        stake.depositETH{value: 1 ether}(); // 不再 revert 即通过
        assertEq(address(stake).balance, 1 ether, unicode"恢复后可正常存款");
    }

    // ---------- 奖励币地址 ----------

    function test_setMetaNode() public {
        // ① 权限
        vm.prank(user1);
        vm.expectRevert();
        stake.setMetaNode(IERC20(address(stakingToken)));

        // ② happy path:换成一个新代币,断言状态 + 事件
        TestERC20 newToken = new TestERC20("New Reward", "NRT", 100 ether);
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.SetMetaNode(IERC20(address(newToken)));
        stake.setMetaNode(IERC20(address(newToken)));
        assertEq(
            address(stake.MetaNode()),
            address(newToken),
            unicode"奖励币地址应更新为 newToken"
        );
    }

    // ---------- 解押/提现 暂停开关 ----------

    function test_pauseWithdraw() public {
        // ① 权限
        vm.prank(user1);
        vm.expectRevert();
        stake.pauseWithdraw();

        // ② happy path:暂停后 unstake 被拦(withdrawPaused 是 public,可直接读)
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.PauseWithdraw();
        stake.pauseWithdraw();
        assertTrue(stake.withdrawPaused(), unicode"withdrawPaused 应为 true");

        vm.prank(user1);
        vm.expectRevert("withdraw is paused");
        stake.unstake(0, 1 ether);

        // ③ 重复暂停
        vm.prank(admin);
        vm.expectRevert("withdraw has been already paused");
        stake.pauseWithdraw();
    }

    function test_unpauseWithdraw() public {
        // ③ 未暂停就 unpause:revert
        vm.prank(admin);
        vm.expectRevert("withdraw has been already unpaused");
        stake.unpauseWithdraw();

        // ② pause → unpause → unstake 恢复可用
        vm.startPrank(admin);
        stake.pauseWithdraw();
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.UnpauseWithdraw();
        stake.unpauseWithdraw();
        vm.stopPrank();
        assertFalse(stake.withdrawPaused(), unicode"withdrawPaused 应为 false");

        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        stake.unstake(0, 1 ether); // 不再 revert 即通过
        vm.stopPrank();
    }

    // ---------- 领取奖励 暂停开关 ----------

    function test_pauseClaim() public {
        // ① 权限
        vm.prank(user1);
        vm.expectRevert();
        stake.pauseClaim();

        // ② happy path
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.PauseClaim();
        stake.pauseClaim();
        assertTrue(stake.claimPaused(), unicode"claimPaused 应为 true");

        vm.prank(user1);
        vm.expectRevert("claim is paused");
        stake.claim(0);

        // ③ 重复暂停
        vm.prank(admin);
        vm.expectRevert("claim has been already paused");
        stake.pauseClaim();
    }

    function test_unpauseClaim() public {
        // ③ 未暂停就 unpause:revert
        vm.prank(admin);
        vm.expectRevert("claim has been already unpaused");
        stake.unpauseClaim();

        // ② pause → unpause → claim 恢复可用(未质押时 claim 金额 0,不 revert)
        vm.startPrank(admin);
        stake.pauseClaim();
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.UnpauseClaim();
        stake.unpauseClaim();
        vm.stopPrank();
        assertFalse(stake.claimPaused(), unicode"claimPaused 应为 false");

        vm.prank(user1);
        stake.claim(0); // 不再 revert 即通过
    }

    // ---------- 奖励参数 setter ----------

    function test_setStartBlock() public {
        // ① 权限
        vm.prank(user1);
        vm.expectRevert();
        stake.setStartBlock(500);

        // ② happy path
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.SetStartBlock(500);
        stake.setStartBlock(500);
        assertEq(stake.startBlock(), 500, unicode"startBlock 应更新为 500");

        // ③ 非法参数:大于 endBlock(setUp 里 endBlock = 1_000_000)
        vm.prank(admin);
        vm.expectRevert("start block must be smaller than end block");
        stake.setStartBlock(2_000_000);
    }

    function test_setEndBlock() public {
        // ① 权限
        vm.prank(user1);
        vm.expectRevert();
        stake.setEndBlock(2_000_000);

        // ② happy path
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.SetEndBlock(2_000_000);
        stake.setEndBlock(2_000_000);
        assertEq(stake.endBlock(), 2_000_000, unicode"endBlock 应更新");

        // ③ 非法参数:小于 startBlock(setUp 里 startBlock = 1)
        vm.prank(admin);
        vm.expectRevert("start block must be smaller than end block");
        stake.setEndBlock(0);
    }

    function test_setMetaNodePerBlock() public {
        // ① 权限
        vm.prank(user1);
        vm.expectRevert();
        stake.setMetaNodePerBlock(200);

        // ② happy path
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.SetMetaNodePerBlock(200);
        stake.setMetaNodePerBlock(200);
        assertEq(
            stake.MetaNodePerBlock(),
            200,
            unicode"MetaNodePerBlock 应更新为 200"
        );

        // ③ 非法参数:0
        vm.prank(admin);
        vm.expectRevert("invalid parameter");
        stake.setMetaNodePerBlock(0);
    }

    // ---------- 资金池管理 ----------

    function test_addPool() public {
        // ① 权限
        vm.prank(user1);
        vm.expectRevert();
        stake.addPool(address(stakingToken), 5, 1e15, LOCK_BLOCKS, false);

        // ② happy path:新增第 3 个池(setUp 已有 2 个)
        //    lastRewardBlock = max(block.number, startBlock) = 当前块
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.AddPool(
            address(stakingToken),
            8,
            block.number,
            2e15,
            LOCK_BLOCKS
        );
        stake.addPool(address(stakingToken), 8, 2e15, LOCK_BLOCKS, false);

        assertEq(stake.poolLength(), 3, unicode"池子数量应为 3");
        (
            address stToken,
            uint256 weight,
            ,
            ,
            ,
            uint256 minDeposit,
            uint256 lockedBlocks
        ) = stake.pool(2);
        assertEq(stToken, address(stakingToken), unicode"新池的质押币应为 TST");
        assertEq(weight, 8, unicode"新池权重应为 8");
        assertEq(minDeposit, 2e15, unicode"新池最小质押额应为 2e15");
        assertEq(lockedBlocks, LOCK_BLOCKS, unicode"新池锁定块数应为 10");
        assertEq(
            stake.totalPoolWeight(),
            18,
            unicode"总权重应从 10 累加到 18"
        );

        // ③ 非法参数 1:非首个池不允许 address(0)
        vm.prank(admin);
        vm.expectRevert("invalid staking token address");
        stake.addPool(address(0), 5, 1e15, LOCK_BLOCKS, false);

        // ③ 非法参数 2:锁定块数为 0
        vm.prank(admin);
        vm.expectRevert("invalid withdraw locked blocks");
        stake.addPool(address(stakingToken), 5, 1e15, 0, false);

        // ③ 非法参数 3:超过结束块(setUp 里 endBlock = 1_000_000)
        vm.roll(1_000_001);
        vm.prank(admin);
        vm.expectRevert("Already ended");
        stake.addPool(address(stakingToken), 5, 1e15, LOCK_BLOCKS, false);
    }

    function test_updatePool() public {
        // ① 权限
        vm.prank(user1);
        vm.expectRevert();
        stake.updatePool(0, 2e15, 20);

        // ② happy path:修改池 0 的最小质押额和锁定块数
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.UpdatePoolInfo(0, 2e15, 20);
        stake.updatePool(0, 2e15, 20);

        (, , , , , uint256 minDeposit, uint256 lockedBlocks) = stake.pool(0);
        assertEq(minDeposit, 2e15, unicode"池0最小质押额应更新为 2e15");
        assertEq(lockedBlocks, 20, unicode"池0锁定块数应更新为 20");

        // ③ 非法 pid
        vm.prank(admin);
        vm.expectRevert("invalid pid");
        stake.updatePool(99, 2e15, 20);
    }

    function test_setPoolWeight() public {
        // ① 权限
        vm.prank(user1);
        vm.expectRevert();
        stake.setPoolWeight(0, 10, false);

        // ② happy path:池 0 权重 5 → 10,总权重 10 → 15
        //    事件 data 里的 totalPoolWeight = 15
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(stake));
        emit MetaNodeStake.SetPoolWeight(0, 10, 15);
        stake.setPoolWeight(0, 10, false);

        (, uint256 weight, , , , ,) = stake.pool(0);
        assertEq(weight, 10, unicode"池0权重应更新为 10");
        assertEq(stake.totalPoolWeight(), 15, unicode"总权重应为 10-5+10=15");

        // ③ 非法参数:权重为 0
        vm.prank(admin);
        vm.expectRevert("invalid pool weight");
        stake.setPoolWeight(0, 0, false);

        // ③ 非法 pid
        vm.prank(admin);
        vm.expectRevert("invalid pid");
        stake.setPoolWeight(99, 10, false);
    }

    // --------------view test--------------------
    // view 函数不改状态,测试套路比业务函数简单:
    //   准备(构造一个已知状态)→ 调用 → 断言返回值 == 手算的期望值
    // 关键是"期望值必须能事先算出来",多用 setUp 里已知的参数来推

    /**
     * pendingMetaNode(_pid, _user):查询用户当前可领奖励
     * 期望值推导(引用 setUp 参数):每块总奖励 PER_BLOCK=100,池0权重5/总权重10 → 池0每块50
     */
    function test_view_pendingMetaNode() public {
        // 准备:user1 向池 0 押 10 ether(锚点块高写法,记 anchor)
        uint256 anchor = block.number;
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();

        // 场景1:刚存完不 roll,pending 应为 0(还没经过产出块)
        // 断言 stake.pendingMetaNode(0, user1) == 0

        assertEq(stake.pendingMetaNode(0, user1), 0, unicode"刚存了钱，区块还没动，可领取代币的值应该是0");
        // 场景2:roll 1 块后,pending = 1块 × 100 × 5/10 = 50
        vm.roll(anchor + 1);
        assertEq(stake.pendingMetaNode(0, user1), 50, unicode"区块前进了1个，user1可领取代币的值应该是50");

        // 场景3:roll 到 endBlock 之后(1_000_000),奖励封顶不再增长
        // 提示:期望值 = 从 anchor 到 endBlock 的块数 × 50,注意 [_from,_to) 左闭右开差 1 块
        vm.roll(anchor + 1_000_000);
        assertEq(stake.pendingMetaNode(0, user1), 50 * (1000000 - 1), unicode"区块到了endblock，期待奖励是50*999999");
        vm.roll(anchor + 1000001);
        assertEq(stake.pendingMetaNode(0, user1), 50 * (1000000 - 1), unicode"区块到了endblock，期待奖励是50*999999");
    }

    /**
     * withdrawAmount(_pid, _user):查询解押申请总额 + 已解锁可提额
     * 期望值依赖"解押时的块高 + LOCK_BLOCKS",必须用锚点块高推算
     */
    function test_view_withdrawAmount() public {
        // 准备:user1 押 10 ether → roll 到 anchor+1 解押 6 ether(解锁块 = anchor+1+10)
        vm.startPrank(user1);
        stake.depositETH{value: 10 ether}();
        uint256 anchor = block.number;
        vm.roll(anchor + 1);
        stake.unstake(0, 6 ether);

        // 场景1:锁定期内 → 返回 (6 ether, 0)
        (uint256 requestAmount, uint256 pendingWithdrawAmount) = stake.withdrawAmount(0, user1);
        assertEq(requestAmount, 6 ether, unicode"期望解押的个数是6 ether");
        assertEq(pendingWithdrawAmount, 0, unicode"期望现在可提取的个数是0");

        // 场景2:roll 到解锁块 → 返回 (6 ether, 6 ether)
        // 注意:在解锁块的"边界上"测一次(unlockBlocks <= block.number 刚好成立)
        vm.roll(anchor + 1 + LOCK_BLOCKS);
        (uint256 requestAmount2, uint256 pendingWithdrawAmount2) = stake.withdrawAmount(0, user1);
        assertEq(requestAmount2, 6 ether, unicode"期望解押的个数是6 ether");
        assertEq(pendingWithdrawAmount2, 6 ether, unicode"期望现在可提取的个数是6 ether");
        // 场景3:没解押过的用户(user2)→ 返回 (0, 0)
        (uint256 requestAmount3, uint256 pendingWithdrawAmount3) = stake.withdrawAmount(0, user2);
        assertEq(requestAmount3, 0, unicode"user2期望解押的个数是0");
        assertEq(pendingWithdrawAmount3, 0, unicode"user2期望现在可提取的个数是0");
        vm.stopPrank();
    }

    /**
     * stakingBalance(_pid, _user):查询用户质押本金
     */
    function test_view_stakingBalance() public {
        // 场景1:没存过 → 0
        vm.startPrank(user1);
        uint256 balance = stake.stakingBalance(0, user1);
        assertEq(balance, 0, unicode"期望是0，因为你没存过eth");
        // 场景2:押 10 ether 后 → 10 ether
        stake.depositETH{value: 10 ether}();
        uint256 balance2 = stake.stakingBalance(0, user1);
        assertEq(balance2, 10 ether, unicode"期望是10 ether");

        // 场景3:解押 4 ether 后 → 6 ether(与 user() 的 stAmount 交叉验证一致性)
        stake.unstake(0, 4 ether);
        vm.roll(block.number + LOCK_BLOCKS);
        (uint256 stAmount,,) = stake.user(0, user1);
        uint256 stBalance = stake.stakingBalance(0, user1);
        assertEq(stAmount, 6 ether);
        assertEq(stBalance, 6 ether);

        vm.stopPrank();
    }

    /**
     * poolLength():查询池子数量
     */
    function test_view_poolLength() public {
        // 场景1:setUp 后应为 2
        uint256 len = stake.poolLength();
        assertEq(len, 2);
        // 场景2:admin addPool 一次后应为 3
        vm.startPrank(admin);
        TestERC20 sToken = new TestERC20("T Stake Token", "TS", 1000000 ether);
        stake.addPool(address(sToken), 100, 100, 10, false);
        uint256 lenNew = stake.poolLength();
        assertEq(lenNew, 3);
        (address stTokenAddress,uint256 poolWeight,,,,,) = stake.pool(2);
        assertEq(stTokenAddress, address(sToken));
        assertEq(poolWeight, 100);
        vm.stopPrank();
    }

    /**
     * getMultiplier(_from, _to):[_from, _to) 区间的奖励基数 = 块数 × MetaNodePerBlock
     * 注意两个隐藏行为(startBlock/endBlock 截断)和两个 require
     */
    function test_view_getMultiplier() public {
        // 场景1:普通区间,如 getMultiplier(10, 15) → 5 × 100 = 500
        uint256 reward1 = stake.getMultiplier(10, 15);
        assertEq(reward1, 500, "sholud return 500");
        // 场景2:左闭右开 —— getMultiplier(10, 10) 应为 0(同一块)
        uint256 reward2 = stake.getMultiplier(10, 10);
        assertEq(reward2, 0, "sholud return 0");
        // 场景3:_to 超过 endBlock 时被截断 —— getMultiplier(999_999, 2_000_000)
        //       实际只算到 endBlock=1_000_000,期望 = 1 × 100 = 100
        uint256 reward3 = stake.getMultiplier(999999, 9999999);
        assertEq(reward3, 100, "sholud return 100");

        // 场景4:revert —— _from > _to 抛 "invalid block"
        // 提示:选一个不会先触发其他 require 的参数组合
        vm.expectRevert("invalid block");
        stake.getMultiplier(10, 9);
    }

    // --------------初始化与升级安全 test--------------------
    // 背景:
    //   initialize = 部署时给合约"开机配置"的函数,它会给调用者分配三种权限:
    //     1. ADMIN_ROLE 管理权限 —— 管所有业务配置(开池/调参数/暂停等)
    //     2. UPGRADE_ROLE 升级权限 —— 唯一能做合约升级的权限
    //     3. DEFAULT_ADMIN_ROLE 权限管理权限 —— 唯一能给别人授予/收回上面两种权限的权限
    //   initialize 自带一把"只许成功执行一次"的锁。
    //   升级 = 把代理背后指向的实现合约换成一个新的,入口是 upgradeToAndCall,
    //   入口处挂着 onlyRole(UPGRADE_ROLE) 检查:只有拥有"升级权限"的人才能调。

    // #15 对已初始化的合约再调一次 initialize,必须被拒
    function test_two_initialize() public {
        // ① 普通用户 user1 调
        vm.prank(user1);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        stake.initialize(rewardToken, 1, 1000000, LOCK_BLOCKS);

        // ② 管理员调也一样被拒
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        stake.initialize(rewardToken, 1, 1000000, LOCK_BLOCKS);
    }

    // #16 没有升级权限的人调升级,必须被拒
    function test_revertWhen_unauthorizedUpgrade() public {
        // 准备:先 new 一个新的实现合约当"升级目标"
        // (升级动作本身合法,要证明的是"调用者没资格")
        MetaNodeStake newImpl = new MetaNodeStake();

        // ① user1(没有 UPGRADE_ROLE 升级权限)调升级 → 必须被拒
        // ⚠️ 大坑:vm.prank 只对"紧挨着的下一次对外调用"生效,
        //    而 stake.UPGRADE_ROLE() 这种读常量的 view 调用也算"对外调用",会把 prank 消耗掉!
        //    所以必须先读角色、后 prank —— 顺序反了 msg.sender 就变回测试合约自己
        bytes32 upgradeRole = stake.UPGRADE_ROLE();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            user1,
            upgradeRole
        ));
        stake.upgradeToAndCall(address(newImpl), "");
        // ② 交叉验证:admin(有升级权限的人)调同样的升级 → 成功
        //    (证明权限检查拦的是"没有升级权限的人",不是把所有人都拦了)
        //    注意:成功路径不写 expectRevert,直接调用即可
        vm.prank(admin);
        stake.upgradeToAndCall(address(newImpl), "");
    }

    // #9 endBlock 之后,利息冻结不再增长
    // 背景:奖励只在 [startBlock, endBlock] 这个区间内产出,过了 endBlock
    // 产出就停了,不管再走多少块,应得利息都停在 endBlock 那一刻的数字上。
    // 合约里的实现是 getMultiplier 会把"算到哪"封顶在 endBlock。
    //
    // ⚠️ 全程用 view 函数(stake.pendingMetaNode)读数断言!
    //    原因:过了 endBlock 之后,第一笔会动状态的交易(claim/deposit 等)
    //    会把"结算水位线"推到当前块(已超过 endBlock);紧接着第二笔再触发结算时,
    //    合约里 getMultiplier 的 require(_from <= _to) 会失败,
    //    revert "end block must be greater than start block"。
    //    所以"走块后查利息"只能用 view(view 每次现算,不推水位线,踩不到这个雷)。
    function test_endBlock_freeze() public {
        // 记锚点:user1 押 10 ether(建议押完记录 anchor)
        vm.startPrank(user1);
        uint256 anchor = block.number;
        stake.depositETH{value: 10 ether}();

        vm.stopPrank();

        // 准备:admin 把结束块调近 —— setEndBlock(anchor + 3)
        // 提示:只有 admin 能调,记得 prank(admin);setEndBlock 在 endBlock>startBlock 时才成功
        vm.startPrank(admin);
        stake.setEndBlock(anchor + 3);

        vm.stopPrank();

        vm.startPrank(user1);
        // 场景1:走 2 块(仍在结束块之前)→ pending == 2 × 50 == 100
        vm.roll(anchor + 2);
        uint256 userPendingMateNode = stake.pendingMetaNode(0, user1);
        assertEq(userPendingMateNode, 100, "user1 now(2 block) should has 100 metanode");
        // 场景2:一路走过结束块(roll 到 anchor + 10,已越过 endBlock = anchor+3)
        //        → pending 冻结在 3 × 50 == 150(产出只算到 endBlock)
        vm.roll(anchor + 10);
        uint256 userPendingMateNode2 = stake.pendingMetaNode(0, user1);
        assertEq(userPendingMateNode2, 150, "user1 when endBlock pass 9 should has 150 metanode");

        // 场景3:再走更远(anchor + 30)→ pending 依旧是 150,一分不涨
        vm.roll(anchor + 100);
        uint256 userPendingMateNode3 = stake.pendingMetaNode(0, user1);
        assertEq(userPendingMateNode3, 150, "user1 when endBlock pass 99 should has 150 metanode");

        // 过 endBlock 后的第一笔状态变更(claim)成功——但它把结算水位线推到了当前块(anchor+100,已越过 endBlock);
        // ⚠️ 同一块里紧接着的第二笔不会 revert(被 updatePool 开头的早退挡住,什么都不做);
        // 雷在"更晚的块":roll 到下一块再触发结算,getMultiplier 里 _from=水位线(>endBlock)、
        // _to 被封顶成 endBlock,require(_from<=_to) 失败 → revert
        stake.claim(0);   // 第一笔:成功(水位线被推到 anchor+100)

        // 同一块的第二笔:不 revert、什么都不做(早退)——顺手把它也钉死
        stake.claim(0);

        vm.roll(anchor + 101);   // 走到更晚的块,雷在这一步之后引爆
        vm.expectRevert("end block must be greater than start block");
        stake.claim(0);

        vm.stopPrank();

    }

    // #10 ERC20 池"恰好等于最小质押额"被拒(和 ETH 池行为相反)
    // 背景:两个池的最小质押额都是 1e15(0.001 ether),但门卫的方向不一样:
    //   ETH 池 depositETH 用 >= (恰好等于 → 放行,test_depositETH_minAmount 已测过);
    //   ERC20 池 deposit 用 > (恰好等于 → 拒绝)。
    // 同一个合约、同一个概念,边界点行为相反——这是合约里一处已知的不一致。
    function test_deposit_erc20_minAmount() public {
        // 场景1:approve 恰好 1e15 后 deposit(1, 1e15)
        //        → expectRevert("deposit amount is too small")
        // 提示:approve 和 deposit 都要以 user1 身份(prank)
        vm.startPrank(user1);
        stakingToken.approve(address(stake), 1e15);
        vm.expectRevert("deposit amount is too small");
        stake.deposit(1, 1e15);

        // 场景2(对照组,证明不是"门槛变高了"而是"等于不行"):
        // approve 后 deposit(1, 1e15 + 1) —— 只多 1 wei → 成功
        // 断言 stakingBalance(1, user1) == 1e15 + 1
        stakingToken.approve(address(stake), 1e15 + 1);
        stake.deposit(1, 1e15 + 1);

        vm.stopPrank();
    }

    // #17 奖励池枯竭:应付 1000 但池子里只有 500 → 短付 500,且差额永久不补
    // 背景:claim 的流程是 ①算出应付全额(如 1000) ②按合约实际余额转款
    // (只有 500 就转 500,不报错) ③账本却记成"已结清 1000"。
    // 结果:用户实收 500,账上认为两清,那 500 的差额再也不会补发——
    // 奖励池枯竭时,最后一批领取的人会静默少拿。
    //
    // 在测试里自建一套"小金库"实例,不动 setUp 共享的 stake
    function test_rewardPool_exhausted() public {
        // 第一步:自建实例(照抄 setUp 的部署三件套,但只转 500 wei 奖励)
        //   new MetaNodeStake() 当实现合约
        //   new ERC1967Proxy(实现地址, abi.encodeCall(MetaNodeStake.initialize, (rewardToken, 1, 1_000_000, 100)))
        //   rewardToken.transfer(代理地址, 500)   ← 只给 500 wei,制造枯竭
        //   代理.addPool(address(0), 5, 1e15, LOCK_BLOCKS, false)
        vm.startPrank(admin);
        MetaNodeStake mns = new MetaNodeStake();
        ERC1967Proxy proxy = new ERC1967Proxy(address(mns),
            abi.encodeCall(MetaNodeStake.initialize, (rewardToken, 1, 1000000, 50)));

        MetaNodeStake stake2 = MetaNodeStake(address(proxy));
        rewardToken.transfer(address(stake2), 500);
        stake2.addPool(address(0), 5, 1e15, LOCK_BLOCKS, false);
        vm.stopPrank();

        // 第二步:user1 向新池押 10 ether,roll 20 块
        //   → 应付利息 = 20 块 × 50 = 1000 wei(> 库存 500)
        //   先用 view 断言 stake2.pendingMetaNode(0, user1) == 1000
        vm.startPrank(user1);
        stake2.depositETH{value: 10 ether}();
        uint256 anchor = block.number;
        vm.roll(anchor + 20);
        uint256 token = stake2.pendingMetaNode(0, address(user1));
        assertEq(token, 1000);

        // 第三步:claim → 三条断言
        //   ① 实收只有 500:rewardToken.balanceOf(user1) 前后差 == 500(库存全给,短付)
        //   ② 账本清零:stake2.pendingMetaNode(0, user1) == 0(挂账已按应付全额 1000 清掉)
        //   ③ 差额永久丢失:再 roll 几块、再 claim → balanceOf 不再变化(那 500 既没补发也没记回)
        uint256 balanceBefore = rewardToken.balanceOf(user1);
        console2.log("balanceBefore is ", balanceBefore);
        stake2.claim(0);

        uint256 balanceEnd = rewardToken.balanceOf(user1);
        console2.log("balanceEnd is ", balanceEnd);

        assertEq(balanceEnd - balanceBefore, 500, "user1 should has 500 rewardtoken ,not 1000");

        // 断言②:账本清零 —— 挂账已按应付全额 1000 清掉(尽管实收只有 500)
        assertEq(stake2.pendingMetaNode(0, user1), 0, unicode"账本认为两清");

        // 断言③:差额永久丢失 —— 再走块、再 claim,余额一分不涨
        vm.roll(anchor + 30);
        stake2.claim(0);
        assertEq(rewardToken.balanceOf(user1), balanceEnd, unicode"短付的 500 永不补发");
    }

}