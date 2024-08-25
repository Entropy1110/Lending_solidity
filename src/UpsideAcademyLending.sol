// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
interface IPriceOracle {

    function getPrice(address _asset) external view returns (uint256);
    function setPrice(address _asset, uint256 _price) external;

}

contract UpsideAcademyLending {

    event LogUint(uint256 value);

    IPriceOracle public priceOracle;
    ERC20 public asset;
    uint256 public constant LIQUIDATION_THRESHOLD_PERCENT = 66;
    uint256 public constant LIQUIDATION_BONUS_PERCENT = 10;

    struct User {
        uint256 borrowedAsset;
        uint256 depositedAsset;
        uint256 depositedETH;
        uint256 lastBorrowedBlock;
        uint256 lastDepositedBlock;
    }

    mapping(address => User) public userBalances;

    uint256 public totalBorrowed;
    uint256 public totalDeposited;

    constructor(IPriceOracle _priceOracle, address token) {
        priceOracle = _priceOracle;
        asset = ERC20(token);
    }

    function initializeLendingProtocol(address _usdc) external payable {
        asset = ERC20(_usdc);
        deposit(_usdc, msg.value);  // ETH deposit
    }

    function getAccruedSupplyAmount(address _asset) external view returns (uint256) {
        if (_asset == address(0)) {
            
            return userBalances[msg.sender].depositedETH; 
        } else {
            uint256 accruedInterest = calculateYield(userBalances[msg.sender]);
            return userBalances[msg.sender].depositedAsset + accruedInterest;
        }
    }

    function deposit(address _asset, uint256 _amount) public payable {
        require(_asset == address(0) || _asset == address(asset), "Invalid asset");

        if (_asset == address(0)) {
            require(msg.value >= _amount, "msg.value should be greater than 0");
            userBalances[msg.sender].depositedETH += _amount;
        } else {
            require(_amount <= asset.allowance(msg.sender, address(this)), "Allowance not set");
            require(asset.balanceOf(msg.sender) >= _amount, "Insufficient balance");
            require(asset.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
            userBalances[msg.sender].depositedAsset += _amount;
        }

        if (userBalances[msg.sender].depositedETH == 0) {
            userBalances[msg.sender].lastDepositedBlock = block.number;
        }

        totalDeposited += _amount;
    }

    function withdraw(address _asset, uint256 _amount) external {

        uint256 ethCollateral = userBalances[msg.sender].depositedETH;
        uint256 assetPrice = priceOracle.getPrice(address(asset));
        uint256 ethPrice = priceOracle.getPrice(address(0));

        uint256 collateralValue = ethCollateral * ethPrice;
        uint256 borrowed = userBalances[msg.sender].borrowedAsset;

        uint256 requiredCollateral = (borrowed * assetPrice) / ethPrice + _amount;

        require(ethCollateral >= requiredCollateral, "Insufficient collateral to cover the borrow amount");

        if (_asset == address(0)) {
            require(userBalances[msg.sender].depositedETH >= _amount, "Insufficient deposited balance");
            require(address(this).balance >= _amount, "Insufficient supply");
            
            userBalances[msg.sender].depositedETH -= _amount;
            payable(msg.sender).transfer(_amount);
        } else {
            require(userBalances[msg.sender].depositedAsset >= _amount, "Insufficient deposited balance");
            require(userBalances[msg.sender].borrowedAsset * assetPrice >= _amount, "Insufficient supply");
            
            userBalances[msg.sender].depositedAsset -= _amount;
            require(asset.transfer(msg.sender, _amount), "Transfer failed");
        }

        totalDeposited -= _amount;
    }

    function borrow(address _asset, uint256 _amount) external {
        uint256 ethCollateral = userBalances[msg.sender].depositedETH;
        uint256 assetPrice = priceOracle.getPrice(_asset);
        uint256 ethPrice = priceOracle.getPrice(address(0));

        uint256 collateralValue = ethCollateral * ethPrice;
        uint256 maxBorrowable = (collateralValue * LIQUIDATION_THRESHOLD_PERCENT) / (100 * assetPrice) - userBalances[msg.sender].borrowedAsset;
        emit LogUint(maxBorrowable);
        require(maxBorrowable >= _amount, "Insufficient collateral");
        require(asset.balanceOf(address(this)) >= _amount, "Insufficient supply");

        if (userBalances[msg.sender].borrowedAsset == 0) {
            userBalances[msg.sender].lastBorrowedBlock = block.number;
        }
        userBalances[msg.sender].borrowedAsset += _amount;
        totalBorrowed += _amount;


        require(ERC20(_asset).transfer(msg.sender, _amount), "Borrow transfer failed");
    }

    function repay(address token, uint256 _amount) external {
        User storage user = userBalances[msg.sender];
        uint256 ethPrice = priceOracle.getPrice(address(0));
        uint256 assetPrice = priceOracle.getPrice(token);
        uint256 interest = calculateInterest(user) * assetPrice / ethPrice;

        require(_amount <= asset.allowance(msg.sender, address(this)), "Allowance not set");
        require(user.borrowedAsset >= _amount, "Repay amount exceeds debt");
        
        require(asset.transferFrom(msg.sender, address(this), _amount), "Repay transfer failed");

        user.borrowedAsset -= _amount;
        user.depositedETH -= interest;
        totalBorrowed -= _amount;
        
        user.lastBorrowedBlock = block.number;
    }
    function liquidate(address user, address token, uint256 _amount) external {
        uint256 borrowed = userBalances[user].borrowedAsset;
        require(borrowed > 0, "No debt to liquidate");

        uint256 ethCollateral = userBalances[user].depositedETH;
        uint256 ethPrice = priceOracle.getPrice(address(0));
        uint256 assetPrice = priceOracle.getPrice(token);

        uint256 collateralValue = ethCollateral * ethPrice;
        uint256 debtValue = borrowed * assetPrice;

        require(collateralValue * LIQUIDATION_THRESHOLD_PERCENT / 100 < debtValue, "Position is not liquidatable");

        uint256 maxLiquidatable = borrowed < _amount ? borrowed : _amount;
        uint256 liquidationBonus = maxLiquidatable * LIQUIDATION_BONUS_PERCENT / 100;

        require(ERC20(token).transferFrom(msg.sender, address(this), maxLiquidatable), "Liquidation transfer failed");

        userBalances[user].borrowedAsset -= maxLiquidatable;
        totalBorrowed -= maxLiquidatable;

        uint256 ethToTransfer = (maxLiquidatable * ethPrice / assetPrice) + liquidationBonus;

        if (ethToTransfer > ethCollateral) {
            ethToTransfer = ethCollateral;
        }

        userBalances[user].depositedETH -= ethToTransfer;
        payable(msg.sender).transfer(ethToTransfer);
    }


    function calculateInterest(User storage user) internal view returns (uint256) {
        uint256 blocksElapsed = block.number - user.lastBorrowedBlock;
        uint256 interestRate = 485e15;
        uint256 interest = (user.borrowedAsset * interestRate * blocksElapsed) / 1e18;
        return interest;
    }

    function calculateYield(User storage user) internal view returns (uint256) {
        // uint256 blocksElapsed = block.number - user.lastBorrowedBlock;
        // uint256 interestRate = 264;
        // uint256 base = 1e18 + interestRate; // 1 + 이자율 (스케일링된 값)
        // uint256 accruedYield = user.depositedETH * (base**blocksElapsed - 1e18) / 1e18; // 복리 계산


        // return accruedYield;
    }
}
