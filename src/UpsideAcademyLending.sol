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
    uint256 public INTEREST_RATE = 1000000138822311089315088974; // ../FindInterestPerBlock.py 뉴턴 랩슨 방식으로 블록 당 이자율 계산
    uint256 constant DECIMAL = 1e27; // for precision
    uint256 private totalBorrowedUSDC; // total borrowed USDC, including interest
    uint256 private totalUSDC; // total USDC supplied
    uint256 private lastInterestUpdatedBlock; // last block number when the interest(totalBorrowedUSDC, User.USDCInterest) was updated
    address[] public suppliedUsers; // list of users who supplied USDC

    struct User {
        uint256 borrowedAsset;
        uint256 depositedAsset;
        uint256 depositedETH;
        uint256 borrwedBlock;
        uint256 USDCInterest;
    }

    mapping(address => User) public userBalances;


    // initialize the lending protocol with the price oracle and the token address
    constructor(IPriceOracle _priceOracle, address token) {
        priceOracle = _priceOracle;
        asset = ERC20(token);
    }

    function initializeLendingProtocol(address _usdc) external payable {
        asset = ERC20(_usdc);
        deposit(_usdc, msg.value);
    }



    // deposited asset + interest 계산
    function getAccruedSupplyAmount(address _asset) public returns (uint256) {
        if (_asset == address(0)) {
            
            return userBalances[msg.sender].depositedETH; 
        } else {
            updateUSDC();
            return userBalances[msg.sender].depositedAsset + userBalances[msg.sender].USDCInterest;
        }
    }


    // deposit asset or ETH
    function deposit(address _asset, uint256 _amount) public payable {
        require(_asset == address(0) || _asset == address(asset), "Invalid asset");

        if (_asset == address(0)) {
            require(msg.value >= _amount, "msg.value should be greater than 0");
            userBalances[msg.sender].depositedETH += _amount;
        } else {
            require(_amount <= asset.allowance(msg.sender, address(this)), "Allowance not set");
            require(asset.balanceOf(msg.sender) >= _amount, "Insufficient balance");
            require(asset.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
            userBalances[msg.sender].depositedAsset += _amount; // add to the user's deposited balance
            totalUSDC += _amount; // add to the total USDC supplied
            suppliedUsers.push(msg.sender); // add the user to the USDC suppliers list
        }
    }

    function withdraw(address _asset, uint256 _amount) external {
        require(_asset == address(0) || _asset == address(asset), "Invalid asset");

        uint256 ethCollateral = userBalances[msg.sender].depositedETH; // user's deposited ETH
        uint256 assetPrice = priceOracle.getPrice(address(asset)); // price of the asset
        uint256 ethPrice = priceOracle.getPrice(address(0)); // price of ETH
        uint256 borrowedPeriod = block.number - userBalances[msg.sender].borrwedBlock; // period since the user borrowed the asset
        uint256 borrowed = userBalances[msg.sender].borrowedAsset * pow(INTEREST_RATE, borrowedPeriod) / DECIMAL; // amount of borrowed asset + interest


        if (_asset == address(0)) { // 이더를 출금한 후 필요한 담보 <= balance가 망가지지 않도록.
            require(ethCollateral >= _amount, "Insufficient deposited balance");
            require(address(this).balance >= _amount, "Insufficient supply");
            require((ethCollateral - _amount) * 75 / 100 >= borrowed * assetPrice / ethPrice, "Insufficient collateral"); // LT = 75%

            userBalances[msg.sender].depositedETH -= _amount;
            payable(msg.sender).transfer(_amount);
        } else {
            uint maxDepositable = getAccruedSupplyAmount(msg.sender); // 이자 한번 더 계산.
            require(maxDepositable >= _amount, "Insufficient deposited balance");
            totalUSDC -= _amount;
            userBalances[msg.sender].depositedAsset -= _amount - userBalances[msg.sender].USDCInterest; 
            userBalances[msg.sender].USDCInterest = 0; // withdraw from the interest first
            
            require(asset.transfer(msg.sender, _amount), "Transfer failed");
        }

    }

    function borrow(address _asset, uint256 _amount) external {
        require(_asset == address(0) || _asset == address(asset), "Invalid asset");
        require(asset.balanceOf(address(this)) >= _amount, "Insufficient supply");

        uint256 ethCollateral = userBalances[msg.sender].depositedETH;
        uint256 assetPrice = priceOracle.getPrice(_asset);
        uint256 ethPrice = priceOracle.getPrice(address(0));
        uint256 collateralValue = ethCollateral * ethPrice;
        uint borrowedPeriod = block.number - userBalances[msg.sender].borrwedBlock;
        userBalances[msg.sender].borrowedAsset = userBalances[msg.sender].borrowedAsset * pow(INTEREST_RATE, borrowedPeriod) / DECIMAL; // 이자 계산
        uint256 maxBorrowable = (collateralValue * 50) / (100 * assetPrice) - userBalances[msg.sender].borrowedAsset; // LTV = 50%

        require(maxBorrowable >= _amount, "Insufficient collateral");

        userBalances[msg.sender].borrwedBlock = block.number; // update the borrowedBlock
        userBalances[msg.sender].borrowedAsset += _amount;
        totalBorrowedUSDC += _amount;

        require(ERC20(_asset).transfer(msg.sender, _amount), "Borrow transfer failed");
    }

    function repay(address token, uint256 _amount) external {

        require(token == address(0) || token == address(asset), "Invalid asset");

        User storage user = userBalances[msg.sender];
        
        require(_amount <= asset.allowance(msg.sender, address(this)), "Allowance not set");
        require(user.borrowedAsset >= _amount, "Repay amount exceeds debt");

        user.borrowedAsset -= _amount;
        totalBorrowedUSDC -= _amount;

        require(asset.transferFrom(msg.sender, address(this), _amount), "Repay transfer failed");
    }

    
    function liquidate(address user, address token, uint256 _amount) external {
        uint256 borrowed = userBalances[user].borrowedAsset;
        require(borrowed > 0, "No debt to liquidate");

        uint256 ethCollateral = userBalances[user].depositedETH;
        uint256 ethPrice = priceOracle.getPrice(address(0));
        uint256 assetPrice = priceOracle.getPrice(token);
        uint256 collateralValue = ethCollateral * ethPrice;
        uint256 debtValue = borrowed * assetPrice;

        require(collateralValue * 75 / 100 < debtValue, "Not liquidatable"); // LT = 75% 
        
        if (_amount <= 100){
            require(borrowed <= 100, "can liquidate the whole position when the borrowed amount is less than 100");
        }else{
            require(borrowed * 25 / 100 >= _amount, "can liquidate 25% of the borrowed amount");
        }

        userBalances[user].borrowedAsset -= _amount;
        totalBorrowedUSDC -= _amount;
        userBalances[user].depositedETH -= _amount * assetPrice / ethPrice;

        require(ERC20(token).transferFrom(msg.sender, address(this), _amount), "Liquidation transfer failed");
    }



    // 대출 이자 분배
    // 총_대출_금액 * 블록_당_이자율 ^ 블록수 - 총_대출_금액 = 이자
    // 이자 분배 -> 유저_당_이자 += 이자 * 각_유저의_예치_금액 / 총_예치_금액
    function updateUSDC() internal {
        
        uint256 blocksElapsed = block.number - lastInterestUpdatedBlock;
        uint256 accumed;
        uint256 interest;

        accumed = totalBorrowedUSDC * pow(INTEREST_RATE, blocksElapsed) / DECIMAL;

        for (uint i = 0; i < suppliedUsers.length; i++) { // updates all users' interest at once
            User storage user = userBalances[suppliedUsers[i]];
            interest = (accumed - totalBorrowedUSDC) * user.depositedAsset / totalUSDC;
            user.USDCInterest += interest;
        }

        lastInterestUpdatedBlock = block.number;
        totalBorrowedUSDC = accumed;
        
    }


    function pow(uint256 a, uint256 n) internal pure returns (uint256 z) {
        z = n % 2 != 0 ? a : DECIMAL;

        for (n /= 2; n != 0; n /= 2) {
            a = a ** 2 / DECIMAL;

            if (n % 2 != 0) {
                z = z * a / DECIMAL;
            }
        }
    }

}

