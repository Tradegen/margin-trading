pragma solidity >=0.5.0;

//Interfaces
import './interfaces/IAddressResolver.sol';
import './interfaces/IERC20.sol';
import './interfaces/ISettings.sol';
import './interfaces/IBaseUbeswapAdapter.sol';

//Libraries
import './libraries/SafeMath.sol';

//Inheritance
import './interfaces/IInsuranceFund.sol';

contract InsuranceFund is IInsuranceFund {
    using SafeMath for uint;

    IAddressResolver public immutable ADDRESS_RESOLVER;

    // 0 = halted
    // 1 = shortage
    // 2 = stable
    // 3 = surplus
    uint public status;

    constructor(IAddressResolver addressResolver) public {
        ADDRESS_RESOLVER = addressResolver;
        status = 2;
    }

    /* ========== VIEWS ========== */

    /**
    * @dev Returns the cUSD and TGEN balance of the insurance fund
    * @return (uint, uint, uint) The insurance fund's cUSD balance and TGEN balance
    */
    function getReserves() public view override returns (uint, uint) {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();
        address baseTradegenAddress = ADDRESS_RESOLVER.getContractAddress("BaseTradegen");

        return (IERC20(stableCoinAddress).balanceOf(address(this)), IERC20(baseTradegenAddress).balanceOf(address(this)));
    }

    /**
    * @dev Returns the status of the fund (halted, shortage, stable, surplus)
    * @return uint Status of the fund
    */
    function getFundStatus() public view override returns (uint) {
        return status;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
    * @dev Withdraws either cUSD or TGEN from insurance fund; meant to be called by StableCoinStakingRewards contract
    * @param amountToWithdrawInUSD Amount of cUSD to withdraw
    * @param user Address of user to send withdrawal to
    */
    function withdrawFromFund(uint amountToWithdrawInUSD, address user) public override onlyStableCoinStakingRewards {
        (uint availableUSD,) = getReserves();

        //Withdraw 100% of amount from cUSD reserve if insurance fund is halted
        //Throw an error if not enough in cUSD reserve to cover withdrawal amount
        if (status == 0)
        {
            require(availableUSD >= amountToWithdrawInUSD, "InsuranceFund: not enough cUSD reserve to cover withdrawal");

            _withdraw(amountToWithdrawInUSD, 0, user);
        }
        //Try to withdraw 100% of amount from cUSD reserve if insurance fund has shortage
        //Withdraw remainder from TGEN reserves
        else if (status == 1)
        {
            uint deficit = (availableUSD < amountToWithdrawInUSD) ? amountToWithdrawInUSD.sub(availableUSD) : 0;

            //First withdraw min(cUSD reserve size, amountToWithdrawInUSD) from cUSD reserve
            _withdraw(amountToWithdrawInUSD.sub(deficit), 0, user);

            //Withdraw remainder from TGEN reserve
            if (deficit > 0)
            {
                _withdraw(0, deficit, user);
            }
        }
        //Withdraw 50% of amount from cUSD reserve if insurance fund is stable
        else if (status == 2)
        {
            _withdraw(amountToWithdrawInUSD.div(2), amountToWithdrawInUSD.div(2), user);
        }
        //Withdraw 0% of amount from cUSD reserve if insurance fund has surplus
        else
        {
            _withdraw(0, amountToWithdrawInUSD, user);
        }

        _updateStatus();
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
    * @dev Updates the fund's status based on the TGEN reserve relative to target allocation
    */
    function _updateStatus() internal {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        uint targetAllocation = ISettings(settingsAddress).getParameterValue("TargetInsuranceFundAllocation");
        (, uint amountOfTGEN) = getReserves();

        //Halted if TGEN reserve falls below 25% of target allocation
        if (amountOfTGEN < targetAllocation.mul(25).div(100))
        {
            status = 0;
        }
        //Shortage if TGEN reserve falls below 75% of target allocation
        else if (amountOfTGEN < targetAllocation.mul(75).div(100))
        {
            status = 1;
        }
        //Stable if TGEN reserve is between 75% and 125% of target allocation
        else if (amountOfTGEN < targetAllocation.mul(125).div(100))
        {
            status = 2;
        }
        //Surplus if TGEN reserve is above 125% of target allocation
        else
        {
            status = 3;
        }
    }

    /**
    * @dev Withdraws from reserves
    * @param amountUSD Amount of cUSD to withdraw
    * @param amountTGEN Amount of TGEN (in USD) to withdraw
    * @param user Address of user to send withdrawal to
    */
    function _withdraw(uint amountUSD, uint amountTGEN, address user) internal {
        address settingsAddress = ADDRESS_RESOLVER.getContractAddress("Settings");
        address stableCoinAddress = ISettings(settingsAddress).getStableCoinAddress();
        address baseTradegenAddress = ADDRESS_RESOLVER.getContractAddress("BaseTradegen");
        address baseUbeswapAdapterAddress = ADDRESS_RESOLVER.getContractAddress("BaseUbeswapAdapter");

        if (amountUSD > 0)
        {
            IERC20(stableCoinAddress).transfer(user, amountUSD);
        }

        if (amountTGEN > 0)
        {
            //Get number of TGEN needed
            uint numberOfTGEN = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).getAmountsIn(amountTGEN, baseTradegenAddress, stableCoinAddress);

            //Swap TGEN for cUSD
            IERC20(baseTradegenAddress).transfer(baseUbeswapAdapterAddress, numberOfTGEN);
            uint cUSDReceived = IBaseUbeswapAdapter(baseUbeswapAdapterAddress).swapFromStableCoinPool(baseTradegenAddress, stableCoinAddress, numberOfTGEN, 0);

            IERC20(stableCoinAddress).transfer(user, cUSDReceived);
        }
    }

    /* ========== MODIFIERS ========== */

    modifier onlyStableCoinStakingRewards() {
        require(msg.sender == ADDRESS_RESOLVER.getContractAddress("StableCoinStakingRewards"), "InsuranceFund: only StableCoinStakingRewards can call this function");
        _;
    }
}