// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract StagedPresale is ReentrancyGuard, Ownable {
    // Token being sold, the CA will be update at the time of finalization of the presale
    IERC20 public PKCToken;

    // Treasury address to collect funds
    address public treasury;

    // Payment tokens accepted
    IERC20 public USDT;
    IERC20 public USDC;
    // Decimals on Ethereum & BSC are different for these tokens
    // total of below 2 values should always be = 36
    uint256 public decimalOfStablecoin = 6;
    uint256 public ethToUSDTDecimalPoints = 30;

    // Oracle for ETH price
    AggregatorV3Interface internal priceFeedETHUSD;

    struct Stage {
        uint256 startTime;
        uint256 endTime;
        uint256 priceInUSDT; // Set by the owner for each stage in wei
        uint256 nextStagePrice;
        uint256 totalTokensSold;
        uint256 totalUSDTRaised;
        uint256 minBuyAmount;
        bool soldOut;
    }

    // Struct to hold referral tier information
    struct ReferralTier {
        uint256 amountThreshold;
        uint256 bonusPercentage;
    }

    ReferralTier[] public referralTiers;

    // Stages of the presale
    Stage[] public stages;

    // Stage counter
    uint8 public totalStages;

    // Global variables
    uint256 public totalTokensSoldGlobal;
    uint256 public totalUSDTRaisedGlobal;

    uint256 public claimStart;

    mapping(address => uint256) public userTokenBalances;
    mapping(address => uint256) public totalAmountInvested;

    // Referral tracking
    mapping(address => uint256) public referralRewards;
    mapping(address => uint8) public referralsCount;
    mapping(address => uint256) public totalUSDTBoughtByReferrals;

    bool public presaleFinalized;
    bool public stagesInitialized;

    // Events
    event StageCreated(
        uint8 indexed stageIndex,
        uint256 startTime,
        uint256 endTime,
        uint256 priceInETH,
        uint256 tokenSaleTarget,
        uint256 USDTTarget,
        uint256 minBuyAmount,
        bool soldOut
    );
    event TokensPurchased(
        address indexed buyer,
        uint256 amount,
        address indexed token,
        uint256 value
    );

    event PresaleBegins(uint256 stage, uint256 startTime);
    event PresaleFinalized(uint256 claimStart);
    event TokensClaimed(address indexed user, uint256 amount);
    event TreasuryUpdated(address newTreasury);
    event NextStageBegins(uint256 stageIndex);
    event StageExtended(uint8 currentStage, uint256 newEndTime);

    constructor(
        address _USDT, // 0x3c38B30D8cB8Ed539502B2B84587d26a955692F8 - Sepolia; 0x55d398326f99059fF775485246999027B3197955 - BSC
        address _USDC, // 0xA6C81867f9Fa6b0e7f1D5941E41c91B6DBd19BeD - Sepolia; 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d - BSC
        address _priceFeedETHUSD, // Sepolia 0x694AA1769357215DE4FAC081bf1f309aDC325306, Eth 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, BSC 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE
        address _treasury
    ) {
        USDT = IERC20(_USDT);
        USDC = IERC20(_USDC);
        priceFeedETHUSD = AggregatorV3Interface(_priceFeedETHUSD);
        treasury = _treasury;

        initializeReferralTiers();
        initializeStages();
        startPresale(block.timestamp);
    }

    receive() external payable {}

    modifier onlyTreasury() {
        if(msg.sender != treasury) {
            revert("Only treasury can call this function!");
        }
        _;
    }

    function initializeReferralTiers() internal {
        // Default tiers
        referralTiers.push(ReferralTier(500 * 10**decimalOfStablecoin, 5));
        referralTiers.push(ReferralTier(1001 * 10**decimalOfStablecoin, 7));
        referralTiers.push(ReferralTier(5001 * 10**decimalOfStablecoin, 10));
        referralTiers.push(ReferralTier(10001 * 10**decimalOfStablecoin, 12));
        referralTiers.push(ReferralTier(25001 * 10**decimalOfStablecoin, 13));
        referralTiers.push(ReferralTier(50001 * 10**decimalOfStablecoin, 14));
        referralTiers.push(ReferralTier(100001 * 10**decimalOfStablecoin, 15));
    }

    function initializeStages() internal {
        require(!stagesInitialized, "Stages are already initialized");

        // Hardcoded values for each stage
        uint16[8] memory pricesInUSDT = [
            4000,
            6000,
            8000,
            10000,
            15000,
            17500,
            18000,
            20000
        ];
        uint16[8] memory nextStagePrices = [
            6000,
            8000,
            10000,
            15000,
            17500,
            18000,
            20000,
            20000
        ];
        uint88[8] memory tokenSaleTargets = [
            30000000000000000000000000,
            30000000000000000000000000,
            30000000000000000000000000,
            35000000000000000000000000,
            35000000000000000000000000,
            60000000000000000000000000,
            80000000000000000000000000,
            100000000000000000000000000
        ];
        uint48[8] memory USDTTargets = [
            120000000000,
            180000000000,
            240000000000,
            350000000000,
            525000000000,
            1050000000000,
            1440000000000,
            2000000000000
        ];
        uint32[8] memory minBuyAmounts = [
            100000000,
            100000000,
            200000000,
            200000000,
            250000000,
            250000000,
            300000000,
            300000000
        ];

        for (uint8 i = 0; i < 8; i++) {
            // Create stage with hardcoded values
            stages.push(
                Stage({
                    startTime: 0,
                    endTime: 0,
                    priceInUSDT: pricesInUSDT[i],
                    nextStagePrice: nextStagePrices[i],
                    minBuyAmount: minBuyAmounts[i],
                    totalTokensSold: 0,
                    totalUSDTRaised: 0,
                    soldOut: false
                })
            );

            emit StageCreated(
                i,
                0,
                0,
                pricesInUSDT[i],
                tokenSaleTargets[i],
                USDTTargets[i],
                minBuyAmounts[i],
                false
            );
        }

        totalStages = 8;
        stagesInitialized = true;
    }

    function updateReferralTier(
        uint256 tierIndex,
        uint256 amountThreshold,
        uint256 bonusPercentage
    ) public onlyOwner {
        if (tierIndex < referralTiers.length) {
            referralTiers[tierIndex].amountThreshold = amountThreshold;
            referralTiers[tierIndex].bonusPercentage = bonusPercentage;
        } else {
            referralTiers.push(ReferralTier(amountThreshold, bonusPercentage));
        }
    }

    /**
     * @notice Finds the index of the current presale stage based on the current time.
     * @return index The index of the current presale stage, or -1 if no current stage exists.
     */
    function findCurrentStageIndex() public view returns (int256) {
        uint256 currentTime = block.timestamp;
        for (uint256 i = 0; i < stages.length; i++) {
            if (
                currentTime >= stages[i].startTime &&
                currentTime <= stages[i].endTime
            ) {
                return int256(i); // Current stage found
            }
        }
        return -1; // No current stage
    }

    /**
     * @notice Allows users to buy tokens with ETH.
     * @param stageIndex The index of the presale stage.
     * @param referrer The address of the referrer.
     */
    function buyTokensWithETH(uint256 stageIndex, address referrer)
        external
        payable
        nonReentrant
    {
        require(stageIndex < stages.length, "Invalid stage index");
        require(referrer != _msgSender(), "Can't refer self");
        Stage storage stage = stages[stageIndex];
        require(
            block.timestamp >= stage.startTime && stage.startTime > 0,
            "Presale stage not active"
        );
        require(!stage.soldOut, "Sold out already! Wait for the next stage");

        // Fetch the latest ETH price in USDT
        uint256 ethPriceInUSDT = getLatestETHPrice();

        uint256 amountInUSDT = (msg.value * ethPriceInUSDT) /
            10**ethToUSDTDecimalPoints;
        require(
            amountInUSDT >= stage.minBuyAmount,
            "Buy more than or equal to the minimum amount"
        );

        // Calculate the number of tokens to purchase
        uint256 tokensToPurchase = (amountInUSDT * 1e18) / stage.priceInUSDT;

        uint256 referralBonusETH;
        uint256 purchaseAmountETH;

        // Handle referral if applicable
        if (referrer != address(0)) {
            referralsCount[referrer]++;
            totalUSDTBoughtByReferrals[referrer] += amountInUSDT;
            // Calculate referral bonus
            referralBonusETH = calculateReferralBonus(referrer, msg.value);
            purchaseAmountETH = msg.value - referralBonusETH;

            // Transfer referral bonus to the referrer
            (bool sentReferral, ) = referrer.call{value: referralBonusETH}("");
            require(sentReferral, "Failed to send referral bonus");

            (bool sentTreasury, ) = treasury.call{value: purchaseAmountETH}("");
            require(sentTreasury, "Failed to send treasury amount");

            referralRewards[referrer] +=
                (referralBonusETH * ethPriceInUSDT) /
                10**ethToUSDTDecimalPoints;
        } else {
            purchaseAmountETH = msg.value;

            (bool sentTreasury, ) = treasury.call{value: purchaseAmountETH}("");
            require(sentTreasury, "Failed to send treasury amount");
        }

        // Update stage and global tracking variables
        stage.totalTokensSold += tokensToPurchase;
        stage.totalUSDTRaised += amountInUSDT;
        totalTokensSoldGlobal += tokensToPurchase;
        totalUSDTRaisedGlobal += amountInUSDT;

        userTokenBalances[_msgSender()] += tokensToPurchase;
        totalAmountInvested[_msgSender()] += amountInUSDT;

        emit TokensPurchased(
            _msgSender(),
            tokensToPurchase,
            address(0),
            msg.value
        );
    }

    /**
     * @notice Allows users to buy tokens with ETH.
     * @param stageIndex The index of the presale stage.
     * @param referrer The address of the referrer.
     */
    function buyTokensWithStableCoin(
        IERC20 token,
        uint256 stageIndex,
        address referrer,
        uint256 amountBuy
    ) external nonReentrant {
        require(token == USDT || token == USDC, "Only stablecoins allowed");
        require(referrer != _msgSender(), "Can't refer self");
        require(stageIndex < stages.length, "Invalid stage index");
        require(
            USDT.balanceOf(_msgSender()) >= amountBuy,
            "Insufficient balance"
        );
        Stage storage stage = stages[stageIndex];
        require(
            amountBuy >= stage.minBuyAmount,
            "Buy more than or equal to the minimum amount"
        );
        require(
            block.timestamp >= stage.startTime && stage.startTime > 0,
            "Presale stage not active"
        );
        require(!stage.soldOut, "Sold out already! Wait for the next stage");

        // Calculate the number of tokens to purchase
        uint256 tokensToPurchase = (amountBuy * 1e18) / stage.priceInUSDT;

        uint256 referralBonusUSDT;
        uint256 purchaseAmounUSDT;

        // Handle referral if applicable
        if (referrer != address(0)) {
            referralsCount[referrer]++;
            totalUSDTBoughtByReferrals[referrer] += amountBuy;
            // Calculate referral bonus
            referralBonusUSDT = calculateReferralBonus(referrer, amountBuy);
            purchaseAmounUSDT = amountBuy - referralBonusUSDT;

            // Transfer referral bonus to the referrer
            require(
                token.transferFrom(_msgSender(), referrer, referralBonusUSDT),
                "Failed to transfer referral bonus"
            );

            // Transfer to treasury
            require(
                token.transferFrom(_msgSender(), treasury, purchaseAmounUSDT),
                "Failed to transfer to treasury"
            );

            referralRewards[referrer] += referralBonusUSDT;
        } else {
            purchaseAmounUSDT = amountBuy;

            // Transfer to treasury
            require(
                token.transferFrom(_msgSender(), treasury, purchaseAmounUSDT),
                "Failed to transfer to treasury"
            );
        }

        stage.totalTokensSold += tokensToPurchase;
        stage.totalUSDTRaised += amountBuy;
        totalTokensSoldGlobal += tokensToPurchase;
        totalUSDTRaisedGlobal += amountBuy;

        userTokenBalances[_msgSender()] += tokensToPurchase;
        totalAmountInvested[_msgSender()] += amountBuy;

        emit TokensPurchased(
            _msgSender(),
            tokensToPurchase,
            address(token),
            amountBuy
        );
    }

    /**
     * @notice Fetches the latest ETH price in USDT from the Chainlink Oracle.
     * @return The latest ETH price in USDT.
     */
    function getLatestETHPrice() public view returns (uint256) {
        (, int256 price, , , ) = priceFeedETHUSD.latestRoundData();
        return uint256(price * 1e10); // Adjusting the price to match the token's decimals
    }

    function startPresale(uint256 _startTime) internal {
        Stage storage stage = stages[0];

        require(
            stage.startTime == 0,
            "Presale has already begun"
        );

        stage.startTime = _startTime;
        stage.endTime = _startTime + 40 days;

        emit PresaleBegins(0, _startTime);
    }

    /**
     * @notice Finalizes the presale, preventing the creation of new stages and enabling claims.
     * @param _claimStart Timestamp when token claiming can start.
     */
    function finalizePresale(uint256 _claimStart, IERC20 _PKCToken)
        external
        onlyTreasury
    {
        require(!presaleFinalized, "Presale already finalized");
        require(address(_PKCToken) != address(0), "Can't set to zero address!");
        // If there are already stages created, ensure the last one has concluded
        PKCToken = _PKCToken;

        if (stages.length > 0) {
            Stage storage lastStage = stages[stages.length - 1];
            require(
                block.timestamp > lastStage.endTime || lastStage.endTime == 0,
                "Previous stage has not concluded"
            );
        }

        require(
            _claimStart > block.timestamp,
            "Claim start must be in the future"
        );
        require(
            PKCToken.transferFrom(
                _msgSender(),
                address(this),
                totalTokensSoldGlobal
            ),
            "Can't finalize without tokens"
        );

        claimStart = _claimStart;

        presaleFinalized = true;

        emit PresaleFinalized(_claimStart);
    }

    /**
     * @notice Allows users to claim their purchased tokens after the presale is finalized and the claim period starts.
     */
    function claimTokens() external nonReentrant {
        require(presaleFinalized && claimStart > 0, "Presale not finalized");
        require(block.timestamp >= claimStart, "Claim period not started");
        uint256 claimableTokens = userTokenBalances[_msgSender()];
        require(claimableTokens > 0, "No tokens to claim");

        userTokenBalances[_msgSender()] = 0;
        require(
            PKCToken.balanceOf(address(this)) >= claimableTokens,
            "Insufficient token balance in the contract"
        );
        require(
            PKCToken.transfer(_msgSender(), claimableTokens),
            "Token transfer failed"
        );

        emit TokensClaimed(_msgSender(), claimableTokens);
    }

    function updateTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0x0), "Can't set to zero address");

        treasury = _newTreasury;

        emit TreasuryUpdated(_newTreasury);
    }

    function calculateReferralBonus(address referrer, uint256 purchaseAmount)
        public
        view
        returns (uint256)
    {
        uint256 referralBonus = 0;
        uint256 maxApplicablePercentage = 0;

        // Iterate through all tiers to find the highest applicable bonus percentage
        for (uint256 i = 0; i < referralTiers.length; i++) {
            if (
                totalUSDTBoughtByReferrals[referrer] >=
                referralTiers[i].amountThreshold
            ) {
                // Update maxApplicablePercentage if this tier's bonusPercentage is higher
                if (
                    referralTiers[i].bonusPercentage > maxApplicablePercentage
                ) {
                    maxApplicablePercentage = referralTiers[i].bonusPercentage;
                }
            }
        }

        // Calculate the bonus using the highest applicable bonus percentage
        if (maxApplicablePercentage > 0) {
            referralBonus = (purchaseAmount * maxApplicablePercentage) / 100;
        }

        return referralBonus;
    }

    function withdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH available");
        payable(treasury).transfer(balance);
    }

    function withdrawStablecoin(IERC20 token) external onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "No tokens available");
        require(token.transfer(treasury, balance), "Transfer failed");
    }

    function extendCurrentStage(uint8 _currentStageIndex, uint256 _newEndTime) external onlyTreasury{
        require(_currentStageIndex < stages.length, "Invalid stage index");

        Stage storage stage = stages[_currentStageIndex];

        stage.endTime = _newEndTime;

        emit StageExtended(_currentStageIndex, _newEndTime);
    }

    function concludeCurrentStage(uint256 _stageIndex) external onlyTreasury {
        require(_stageIndex < stages.length - 1, "No next stage available");
        Stage storage stage = stages[_stageIndex];

        stage.endTime = block.timestamp;

        stage.soldOut = true;

        Stage storage nextStage = stages[_stageIndex + 1];

        nextStage.startTime = block.timestamp + 1;
        nextStage.endTime = block.timestamp + 40 days;
        
        emit NextStageBegins(_stageIndex + 1);
    }
}

