// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
interface IPriceOracle {

    function getPrice(address _asset) external view returns (uint256);
    function setPrice(address _asset, uint256 _price) external;

}

contract UpsideAcademyLending {
    
        IPriceOracle public priceOracle;
        ERC20 public asset;
        uint256 public constant LIQUIDATION_THRESHOLD_PERCENT = 75;
        uint256 public constant LIQUIDATION_BONUS_PERCENT = 10;

        event log_uint(uint256 value);

        struct User {
            uint256 borrowedAsset;
            uint256 depositedAsset;
            uint256 depositedETH;
        }

        mapping(address => User) public userBalances;
        

        constructor(IPriceOracle _priceOracle, address token) {
            priceOracle = _priceOracle;
            asset = ERC20(token);
        }


        function initializeLendingProtocol(address _usdc) external payable{
            asset = ERC20(_usdc);
            deposit(_usdc, msg.value);
        }

        function getAccruedSupplyAmount(address _asset) external view returns (uint256) {
            return ERC20(_asset).balanceOf(address(this));
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

            require(ERC20(token).transferFrom(msg.sender, address(this), maxLiquidatable), "Liquidation transfer failed");

            userBalances[user].borrowedAsset -= maxLiquidatable;

            uint256 liquidationBonus = maxLiquidatable * ethPrice / assetPrice * LIQUIDATION_BONUS_PERCENT / 100;
            uint256 ethToTransfer = (maxLiquidatable * ethPrice / assetPrice) + liquidationBonus;

            if (ethToTransfer > ethCollateral) {
                ethToTransfer = ethCollateral;
            }

            userBalances[user].depositedETH -= ethToTransfer;
            payable(msg.sender).transfer(ethToTransfer);
        }

        function deposit(address _asset, uint256 _amount) public payable{
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
            

        }

        function withdraw(address _asset, uint256 _amount) external {
            if (_asset == address(0)) {
                require(userBalances[msg.sender].depositedETH >= _amount, "Insufficient deposited balance");
                userBalances[msg.sender].depositedETH -= _amount;
                payable(msg.sender).transfer(_amount);
            } else {
                require(userBalances[msg.sender].depositedAsset >= _amount, "Insufficient deposited balance");
                require(asset.transfer(msg.sender, _amount), "Transfer failed");
                userBalances[msg.sender].depositedAsset -= _amount;
            }
        }

        function borrow(address token, uint256 _amount) external {

            uint256 ethCollateral = userBalances[msg.sender].depositedETH;
            uint256 assetPrice = priceOracle.getPrice(address(token));
            uint256 ethPrice = priceOracle.getPrice(address(0));

            uint256 collateralValue = ethCollateral * ethPrice;
            uint256 maxBorrowable = collateralValue * LIQUIDATION_THRESHOLD_PERCENT / (100 * assetPrice);

            require(maxBorrowable >= _amount, "Insufficient collateral");

            userBalances[msg.sender].borrowedAsset += _amount;
            ERC20(token).transfer(msg.sender, _amount);
            
        }

        function repay(address token, uint256 _amount) external {
            require(_amount <= asset.allowance(msg.sender, address(this)), "Allowance not set");
            require(userBalances[msg.sender].borrowedAsset >= _amount, "Insufficient balance");
            require(asset.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
            userBalances[msg.sender].borrowedAsset -= _amount;

        }
    

}

