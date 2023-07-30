// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Foundry libraries
import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";

// Test ERC-20 token implementation
import {TestERC20} from "v4-core/test/TestERC20.sol";

// Libraries
import {CurrencyLibrary, Currency} from "v4-core/libraries/CurrencyLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/libraries/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

// Interfaces
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

// Pool Manager related contracts
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolModifyPositionTest} from "v4-core/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

// Our contracts
import {TakeProfitsHook} from "../src/TakeProfitsHook.sol";
import {TakeProfitsStub} from "../src/TakeProfitsStub.sol";

contract TakeProfitsHookTest is Test, GasSnapshot {
    using PoolIdLibrary for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    TakeProfitsHook hook =
        TakeProfitsHook(
            address(
                uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)
            )
        );

    PoolManager poolManager;

    PoolModifyPositionTest modifyPositionRouter;

    PoolSwapTest swapRouter;

    TestERC20 token0;
    TestERC20 token1;

    IPoolManager.PoolKey poolKey;
    PoolId poolId;
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    function _deployERC20Tokens() private {
        TestERC20 tokenA = new TestERC20(2 ** 128);
        TestERC20 tokenB = new TestERC20(2 ** 128);
        if (address(tokenA) < address(tokenB)) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
    }

    function _stubValidateHookAddress() private {
        TakeProfitsStub stub = new TakeProfitsStub(poolManager, hook);

        (, bytes32[] memory writes) = vm.accesses(address(stub));

        vm.etch(address(hook), address(stub).code);

        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(hook), slot, vm.load(address(stub), slot));
            }
        }
    }

    function _initializePool() private {
        modifyPositionRouter = new PoolModifyPositionTest(
            IPoolManager(address(poolManager))
        );
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        poolKey = IPoolManager.PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        poolId = poolKey.toId();

        poolManager.initialize(poolKey, SQRT_RATIO_1_1);
    }

    function _addLiquidityToPool() private {
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);

        token0.approve(address(modifyPositionRouter), 100 ether);
        token1.approve(address(modifyPositionRouter), 100 ether);
        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-60, 60, 10 ether)
        );

        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-120, 120, 10 ether)
        );

        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                50 ether
            )
        );

        token0.approve(address(swapRouter), 100 ether);
        token1.approve(address(swapRouter), 100 ether);
    }

    function setUp() public {
        _deployERC20Tokens();
        poolManager = new PoolManager(500_000);
        _stubValidateHookAddress();
        _initializePool();
        _addLiquidityToPool();
    }

    receive() external payable {}

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155Received(address,address,uint256,uint256,bytes)"
                )
            );
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"
                )
            );
    }

    function test_placeOrder() public {
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        uint256 originalBalance = token0.balanceOf(address(this));

        token0.approve(address(hook), amount);
        int24 tickLower = hook.placeOrder(poolKey, tick, amount, zeroForOne);

        uint256 newBalance = token0.balanceOf(address(this));

        assertEq(tickLower, 60);

        assertEq(originalBalance - newBalance, amount);

        uint256 tokenId = hook.getTokenId(poolKey, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), tokenId);

        assertTrue(tokenId != 0);
        assertEq(tokenBalance, amount);
    }

    function test_cancelOrder() public {
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        uint256 originalBalance = token0.balanceOf(address(this));

        token0.approve(address(hook), amount);
        int24 tickLower = hook.placeOrder(poolKey, tick, amount, zeroForOne);

        uint256 newBalance = token0.balanceOf(address(this));

        assertEq(tickLower, 60);
        assertEq(originalBalance - newBalance, amount);

        uint256 tokenId = hook.getTokenId(poolKey, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), tokenId);
        assertEq(tokenBalance, amount);

        hook.cancelOrder(poolKey, tickLower, zeroForOne);

        uint256 finalBalance = token0.balanceOf(address(this));
        assertEq(finalBalance, originalBalance);

        tokenBalance = hook.balanceOf(address(this), tokenId);
        assertEq(tokenBalance, 0);
    }

    function test_orderExecute_zeroForOne() public {
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        token0.approve(address(hook), amount);
        int24 tickLower = hook.placeOrder(poolKey, tick, amount, zeroForOne);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(poolKey, params, testSettings);

        int256 tokensLeftToSell = hook.takeProfitPositions(
            poolId,
            tick,
            zeroForOne
        );
        assertEq(tokensLeftToSell, 0);

        uint256 tokenId = hook.getTokenId(poolKey, tickLower, zeroForOne);
        uint256 claimableTokens = hook.tokenIdClaimable(tokenId);
        uint256 hookContractToken1Balance = token1.balanceOf(address(hook));
        assertEq(claimableTokens, hookContractToken1Balance);

        uint256 originalToken1Balance = token1.balanceOf(address(this));
        hook.redeem(tokenId, amount, address(this));
        uint256 newToken1Balance = token1.balanceOf(address(this));

        assertEq(newToken1Balance - originalToken1Balance, claimableTokens);
    }

    function test_orderExecute_oneForZero() public {
        int24 tick = -100;
        uint256 amount = 10 ether;
        bool zeroForOne = false;

        token1.approve(address(hook), amount);
        int24 tickLower = hook.placeOrder(poolKey, tick, amount, zeroForOne);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(poolKey, params, testSettings);

        int256 tokensLeftToSell = hook.takeProfitPositions(
            poolId,
            tick,
            zeroForOne
        );
        assertEq(tokensLeftToSell, 0);

        uint256 tokenId = hook.getTokenId(poolKey, tickLower, zeroForOne);
        uint256 claimableTokens = hook.tokenIdClaimable(tokenId);
        uint256 hookContractToken0Balance = token0.balanceOf(address(hook));
        assertEq(claimableTokens, hookContractToken0Balance);

        uint256 originalToken0Balance = token0.balanceOf(address(this));
        hook.redeem(tokenId, amount, address(this));
        uint256 newToken0Balance = token0.balanceOf(address(this));

        assertEq(newToken0Balance - originalToken0Balance, claimableTokens);
    }
}
