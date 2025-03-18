// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {AccessControl} from "../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

/// @title Cross-Chain Rebase Token
/// @author Anirudh
/// @notice This is a cross-chain rebase token that incentivises users to deposit into a vault and gain interest
/// @notice The interest rate in the smart contract can only decrease
///@notice Each user will have their own interest rate that is the global interest rate at the time of depositing
contract RebaseToken is ERC20, Ownable, AccessControl {
    ////////////////
    /// Errors ////
    //////////////
    error RebaseToken__InterestRateCanOnlyDecrease(uint256 oldInterestRate, uint256 newInterestRate);

    ////////////////////////
    /// State Variables ////
    ///////////////////////
    uint256 private s_interestRate = (5 * PRECISION_FACTOR) / 1e8;
    mapping(address => uint256) private s_userInterestRate;
    mapping(address => uint256) private s_lastUpdatedTimestamp;
    uint256 private constant PRECISION_FACTOR = 1e18;
    bytes32 private constant MINT_AND_BURN_ROLE = keccak256("MINT_AND_BURN_ROLE");

    ////////////////
    /// Events ////
    //////////////
    event InterestRateSet(uint256 newInterestRate);

    /////////////////////
    /// Constructor ////
    ///////////////////
    constructor() ERC20("Rebase Token", "RBT") Ownable(msg.sender) {}

    function grantMintAndBurnRole(address _account) external onlyOwner {
        _grantRole(MINT_AND_BURN_ROLE, _account);
    }

    ///////////////////////////////////////
    /// External and Public Functions ////
    /////////////////////////////////////
    /// @notice Sets the interest rate in the contract
    /// @param _newInterestRate The new interest rate to be set
    /// @dev The interest rate can only decrease
    function setInterestRate(uint256 _newInterestRate) external onlyOwner {
        //set the interest rate
        if (_newInterestRate >= s_interestRate) {
            revert RebaseToken__InterestRateCanOnlyDecrease(s_interestRate, _newInterestRate);
        }
        s_interestRate = _newInterestRate;
        emit InterestRateSet(_newInterestRate);
    }

    /// @notice Get the ptinciple balance of the user.This is the number of tokens that have currently been minted to the user, not including any interest that has accrued since the last time the user interacted with the protocol
    /// @param _user The user to get the principle balance for
    /// @return The principle balance of the user
    function principleBalanceOf(address _user) external view returns (uint256) {
        return super.balanceOf(_user);
    }

    /// @notice Mint the user tokens when they deposit into the vault
    /// @param _to The user to whom the tokens are to be minted
    /// @param _amount The amount of tokens to be minted
    function mint(address _to, uint256 _amount, uint256 _userInterestRate) external onlyRole(MINT_AND_BURN_ROLE) {
        _mintAccruedInterest(_to);
        s_userInterestRate[_to] = _userInterestRate;
        _mint(_to, _amount);
    }

    /// @notice Burn the user tokens when they withdraw from the vault
    /// @param _from The user to burn the tokens from
    /// @param _amount the amount of tokens to burn
    function burn(address _from, uint256 _amount) external onlyRole(MINT_AND_BURN_ROLE) {
        if (_amount == type(uint256).max) {
            _amount = balanceOf(_from);
        }
        _mintAccruedInterest(_from);
        _burn(_from, _amount);
    }

    /// @notice Calculate the balance of the user including any interest accumulated since the last update
    /// @param _user The user whose balance is to be calculated
    /// @return The balance of the user including any interest accumulated since the last update
    function balanceOf(address _user) public view override returns (uint256) {
        // get the current principle balance -> number of tokens that have actually been minted to the user
        //multiply the principle balance by the interest that has accumulated in the time since the balance was last updated
        return (super.balanceOf(_user) * _calculateUserAccumulatedInterestSinceLastUpdate(_user)) / PRECISION_FACTOR;
    }

    /// @notice Transfers tokens from one user to another
    /// @param _recipient the user to transfer the tokens to
    /// @param _amount The amount of tokens to transfer
    /// @return True if the transfer was successful
    function transfer(address _recipient, uint256 _amount) public override returns (bool) {
        _mintAccruedInterest(msg.sender);
        _mintAccruedInterest(_recipient);
        if (_amount == type(uint256).max) {
            _amount = balanceOf(msg.sender);
        }
        if (balanceOf(_recipient) == 0) {
            s_userInterestRate[_recipient] = s_userInterestRate[msg.sender];
        }
        return super.transfer(_recipient, _amount);
    }

    /// @notice Transfers tokens from one user to another
    /// @param _sender the user from whom tokens are transfered
    /// @param _recipient the user to transfer the tokens to
    /// @param _amount The amount of tokens to transfer
    /// @return True if the transfer was successful
    function transferFrom(address _sender, address _recipient, uint256 _amount) public override returns (bool) {
        _mintAccruedInterest(_sender);
        _mintAccruedInterest(_recipient);
        if (_amount == type(uint256).max) {
            _amount = balanceOf(_sender);
        }
        if (balanceOf(_recipient) == 0) {
            s_userInterestRate[_recipient] = s_userInterestRate[_sender];
        }
        return super.transferFrom(_sender, _recipient, _amount);
    }

    ////////////////////////////
    /// Internal Functions ////
    //////////////////////////

    /// @dev returns the interest accrued since the last update of the user's balance - aka since the last time the interest accrued was minted to the user.
    /// @return linearInterest the interest accrued since the last update
    function _calculateUserAccumulatedInterestSinceLastUpdate(address _user)
        internal
        view
        returns (uint256 linearInterest)
    {
        //we need to calculate the interest that has been accumulated since the last update
        // this is going to be linear growth with time
        uint256 timeElapsed = block.timestamp - s_lastUpdatedTimestamp[_user];
        linearInterest = PRECISION_FACTOR + (s_userInterestRate[_user] * timeElapsed);
    }

    /// @notice Mint accrued interest to the user since the last time they interacted with the protocol(eg burn, mint, transfer etc)
    /// @param _user the user to mint the accrued interest to
    function _mintAccruedInterest(address _user) internal {
        //(1)find the current balance of rebase tokens that have been minted to them -> principal balance
        uint256 previousPrincipleBalance = super.balanceOf(_user);
        //(2)calculate their current balance including any interest -> balanceOf
        uint256 currentBalance = balanceOf(_user);
        //(3)calculate the number of tokens that need to be minted to the user (2) - (1)
        uint256 balanceIncrease = currentBalance - previousPrincipleBalance;
        // set the user's last updated timestamp
        s_lastUpdatedTimestamp[_user] = block.timestamp;
        // call _mint to mint the tokens to the user
        _mint(_user, balanceIncrease);
    }

    //////////////////////////
    /// Getter Functions ////
    ////////////////////////

    /// @notice Get the interest rate that is currently set for the contract. Any future depositers will receive this interest rate.
    /// @return Returns the interest rate for the contract
    function getInterestRate() external view returns (uint256) {
        return s_interestRate;
    }

    /// @notice gets the user's interest rate
    /// @param _user The user whose interest rate is to be fetched
    function getUserInterestRate(address _user) external view returns (uint256) {
        return s_userInterestRate[_user];
    }
}
