// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "hardhat/console.sol";

contract Olive is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using SafeMath for uint8;

    // strategy candidate with proposed timestamp to check for approvalDelay
    struct StratCandidate {
        address implementation;
        uint proposedTime;
    }

    // the last proposed strategy to switch to
    StratCandidate public stratCandidate;

    // the strategy currently in use by the vault
    IStrategy public strategy;

    // the minimum time it has to pass before a strat candidate can be approved
    uint256 public approvalDelay;

    event NewStratCandidate(address implementation);
    event UpgradeStrat(address implementation);

    // tokens used
    IERC20 public wantAddr;
    IERC20 public tokenAddr;

    // contracts used
    IWantManager public wantManager;
    ITreasury public treasury;

    // min & max leverage for the vault
    uint8 public minLeverage;
    uint8 public maxLeverage;

    // latest block number to mitigate flash loan attack
    mapping(address => uint256) latestBlockNumber;

    // whitelisted borrowing pools
    mapping(address => bool) pools;
    
    constructor (
        IERC20 wantAddr, 
        IERC20 tokenAddr, 
        IWantManager wantManager, 
        IStrategy strategy, 
        ITreasury treasury,
        uint256 approvalDelay,
        uint8 minLeverage,
        uint8 maxLeverage
    ) {
        wantAddr = wantAddr;
        tokenAddr = tokenAddr;
        wantManager = wantManager;
        strategy = strategy;
        treasury = treasury;
        approvalDelay = approvalDelay;
        minLeverage = minLeverage;
        maxLeverage = maxLeverage;
    }

    function balance() public view returns (uint256) {
        return wantAddr.balanceOf(address(this)).add(strategy.balanceOf());
    }

    function available() public view returns(uint256) {
        return wantAddr.balanceOf(address(this));
    }

    function totalSupply() public view returns(uint256) {
        return tokenAddr.totalSupply();
    }

    function getPricePerShare() public view returns(uint256) {
        return totalSupply() == 0? 1e18 : balance().mul(1e18).div(totalSupply());
    }

    function depositAll(uint8 leverage, uint256 expectedShares, uint8 acceptableSlippage) external returns(uint256) {
        return deposit(want.balanceOf(msg.sender), leverage, expectedShares, acceptableSlippage);
    }

    function deposit(uint256 wantAmount, uint8 leverage, uint256 expectedShares, uint8 acceptableSlippage) external nonReentrant returns(uint256) {
        require(wantAmount > 0, "Deposit amount can't be less than or equal to zero");
        require(leverage >= minLeverage, "Leverage can't be less than Min Leverage");
        require(leverage <= maxLeverage, "Leverage can't be more than Max Leverage");
        require(expectedShares > 0, "Expected shares can't be less than or equal to zero");
        require(acceptableSlippage >= 0 && acceptableSlippage <= 100, "Acceptable slippage percentage should be between 0% and 100%");

        uint256 shares = 0;

        if(leverage == 1) {
            shares = _deposit(wantAmount);
        } else {
            mapping(IERC20 => uint256) borrowAmount = borrow(wantAddr, leverage.sub(1).mul(wantAmount));
            uint256 mintedWantAmount = wantManager.mint(borrowAmount);            
            shares = _deposit(wantAmount + mintedwantAmount);
        }

        require(shares >= expectedShares.mul(100.sub(acceptableSlippage)), "Exceeds acceptable slippage limit");
        return shares;
    }

    function _deposit(uint256 wantAmount) internal returns(uint256) {
        strategy.beforeDeposit();

        uint256 _beforeBalance = balance();
        wantAddr.safeTransferFrom(msg.sender, address(this), wantAmount);
        deployToStrategy();
        uint256 _afterBalance = balance();
        _amount = _afterBalance.sub(_beforeBalance); // Additional check for deflationary tokens
        uint256 shares = 0;
        
        if(totalSupply() == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalSupply())).div(_beforeBalance);
        }

        tokenAddr.mint(msg.sender, shares); // to check: if above require fails, does mint also reverts
        return shares;
    }

    function deployToStrategy() internal {
        uint256 _bal = available();
        wantAddr.safeTransfer(address(strategy), _bal);
        strategy.deposit();
    }

    function withdrawAll(uint256 expectedWantAmount, uint8 acceptableSlippage) external returns(uint256) {
        return withdraw(tokenAddr.balanceOf(msg.sender), expectedWantAmount, acceptableSlippage);
    }

    function withdraw(uint256 shares, uint256 expectedwantAmount, uint8 acceptableSlippage) external nonReentrant returns(uint256) {
        require(shares > 0, "Withdraw shares can't be less than or equal to zero");
        require(expectedwantAmount >= 0, "Expected wantAmount can't be less than zero");
        require(acceptableSlippage >= 0 && acceptableSlippage <= 100, "Acceptable slippage percentage should be between 0% and 100%");

        uint256 wantAmount = 0;
        uint8 userLeverage = getLeverage();

        require(userLeverage >= _minLeverage, "Leverage can't be less than Min Leverage");
        require(userLeverage <= _maxLeverage, "Leverage can't be more than Max Leverage");

        if(userLeverage == 1) {
            wantAmount = _withdraw(shares);
        } else {
            uint256 prorataDebtAmount = getDebtBalance().mul(shares).div(tokenAddr.balanceOf(msg.sender)); // to do: handle array
            repay(prorataDebtAmount, shares);
            wantAmount = _withdraw(shares);
        }

        require(wantAmount >= expectedwantAmount.mul(100.sub(acceptableSlippage)), "Exceeds acceptable slippage limit");
        return wantAmount;
    }

    function _withdraw(uint256 shares) internal returns(uint256) {
        uint256 r = (balance().mul(shares)).div(totalSupply());
        tokenAddr.burn(msg.sender, shares);

        uint256 b = wantAddr.balanceOf(address(this));
        if(b < r) {
            uint256 w = r.sub(b);
            strategy.withdraw(w);
            uint _after = wantAddr.balanceOf(address(this));
            uint _diff = _after.sub(b);
            if(_diff < w) {
                r = b.add(_diff);
            }
        }

        wantAddr.transfer(msg.sender, r);
        return r;
    }

    function proposeStrat(address _implementation) public onlyOwner {
        require(address(this) == IStrategy(_implementation).vault(), "Proposal not valid for this vault");
        require(wantAddr == IStrategy(_implementation).want(), "Different want");

        stratCandidate = StratCandidate({
            implementation: _implementation,
            proposedTime: block.timestamp
        });

        emit NewStratCandidate(_implementation);
    }

    function upgradeStrat() public onlyOwner {
        require(stratCandidate.implementation != address(0), "Implementation address can't be zero");
        require(stratCandidate.implementation != address(strategy), "Duplicate strategy address");
        require(stratCandidate.implementation != address(this), "Can't be vault address");
        require(stratCandidate.proposedTime + approvalDelay < block.timestamp, "Delay has not passed");

        emit UpgradeStrat(stratCandidate.implementation);

        strategy.retireStrat();
        strategy = IStrategy(stratCandidate.implementation);
        stratCandidate.implementation = address(0);
        stratCandidate.proposedTime = 5000000000; // 100+ years into the future

        deployToStrategy();
    }

    function inCaseTokensGetStuck(address _token) external onlyOwner {
        require(_token != address(wantAddr), "!token");

        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).transfer(msg.sender, amount);
    }

    function getDebtBalance() public returns (uint256) {
        
    }

    function borrow(IERC20 wantAddr, uint256 wantAmount) internal {
        // mint dTokens to the user

    }

    function liquidation() public returns(bool) {

    }
}