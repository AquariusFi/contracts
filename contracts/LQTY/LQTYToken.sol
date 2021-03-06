// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/CheckContract.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/Ownable.sol";
import "../Interfaces/ILQTYToken.sol";
import "../Interfaces/ILQTYStaking.sol";
import "../Interfaces/ILockupContractFactory.sol";
import "../Dependencies/console.sol";
import "../Dependencies/IUniswapV2Router.sol";

/*
* Based upon OpenZeppelin's ERC20 contract:
* https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol
*  
* and their EIP2612 (ERC20Permit / ERC712) functionality:
* https://github.com/OpenZeppelin/openzeppelin-contracts/blob/53516bc555a454862470e7860a9b5254db4d00f5/contracts/token/ERC20/ERC20Permit.sol
* 
*
*  --- Functionality added specific to the LQTYToken ---
* 
* 1) Transfer protection: blacklist of addresses that are invalid recipients (i.e. core Liquity contracts) in external 
* transfer() and transferFrom() calls. The purpose is to protect users from losing tokens by mistakenly sending LQTY directly to a Liquity
* core contract, when they should rather call the right function.
*
* 2) sendToLQTYStaking(): callable only by Liquity core contracts, which move LQTY tokens from user -> LQTYStaking contract.
*
* 3) Supply hard-capped at 100 million
*
* 4) CommunityIssuance and LockupContractFactory addresses are set at deployment
*
* 5) The bug bounties / hackathons allocation of 2 million tokens is minted at deployment to an EOA

* 6) 32 million tokens are minted at deployment to the CommunityIssuance contract
*
* 7) The LP rewards allocation of (1 + 1/3) million tokens is minted at deployent to a Staking contract
*
* 8) (64 + 2/3) million tokens are minted at deployment to the Liquity multisig
*
* 9) Until one year from deployment:
* -Liquity multisig may only transfer() tokens to LockupContracts that have been deployed via & registered in the 
*  LockupContractFactory 
* -approve(), increaseAllowance(), decreaseAllowance() revert when called by the multisig
* -transferFrom() reverts when the multisig is the sender
* -sendToLQTYStaking() reverts when the multisig is the sender, blocking the multisig from staking its LQTY.
* 
* After one year has passed since deployment of the LQTYToken, the restrictions on multisig operations are lifted
* and the multisig has the same rights as any other address.
*/

contract LQTYToken is CheckContract, ILQTYToken, Ownable {
    using SafeMath for uint256;

    // --- ERC20 Data ---

    string constant internal _NAME = "AQU";
    string constant internal _SYMBOL = "AQU";
    string constant internal _VERSION = "1";
    uint8 constant internal  _DECIMALS = 18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint private _totalSupply;

    // --- EIP 2612 Data ---

    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant _PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _TYPE_HASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    // Cache the domain separator as an immutable value, but also store the chain id that it corresponds to, in order to
    // invalidate the cached domain separator if the chain id changes.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;

    mapping(address => uint256) private _nonces;

    // --- LQTYToken specific data ---

    // uint for use with SafeMath
    uint internal _1_MILLION = 1e24;    // 1e6 * 1e18 = 1e24

    uint internal immutable deploymentStartTime;

    address public immutable multisigAddressForStableCoinDex;
    address public immutable multisigAddressForLQTYHolders;
    address public immutable multisigAddressForPartners;
    address public immutable communityIssuanceAddress;
    address public immutable lqtyStakingAddress;
    address public immutable uniswapV2RouterAddress;

    uint internal immutable AUSDlpRewardsEntitlement;
    uint internal immutable AQUlpRewardsEntitlement;

    uint private constant _liquidityFee = 25;                     // 2.5%
    uint private constant _taxFee = 24;                           // 2.4%
    uint private constant _deflationFee = 1;                      // 0.1%
    uint private constant _1_THOUSAND_DENOMINATOR = 1e3;          // 1000
    
    uint public addLiquityThreshold =  100 * 1e18;                // 100

    mapping(address => bool) public _isExcludedFromFee;

    // --- Events ---

    event CommunityIssuanceAddressSet(address _communityIssuanceAddress);
    event LQTYStakingAddressSet(address _lqtyStakingAddress);
    event LockupContractFactoryAddressSet(address _lockupContractFactoryAddress);

    // --- Functions ---

    constructor
    (
        address _communityIssuanceAddress,
        address _lqtyStakingAddress,
        address _halflifeAddress,
        address _lockInHalflifeAddress,
        address _AUSDlpRewardsAddress,
        address _AQUlpRewardsAddress,
        address _uniswapV2RouterAddress,
        address _multisigAddressForStableCoinDex,
        address _multisigAddressForLQTYHolders,
        address _multisigAddressForPartners
    )
    public
    {
        checkContract(_communityIssuanceAddress);
        checkContract(_lqtyStakingAddress);
        checkContract(_uniswapV2RouterAddress);

        multisigAddressForStableCoinDex = _multisigAddressForStableCoinDex;
        multisigAddressForLQTYHolders = _multisigAddressForLQTYHolders;
        multisigAddressForPartners = _multisigAddressForPartners;

        deploymentStartTime = block.timestamp;

        communityIssuanceAddress = _communityIssuanceAddress;
        lqtyStakingAddress = _lqtyStakingAddress;
        uniswapV2RouterAddress = _uniswapV2RouterAddress;

        bytes32 hashedName = keccak256(bytes(_NAME));
        bytes32 hashedVersion = keccak256(bytes(_VERSION));

        _HASHED_NAME = hashedName;
        _HASHED_VERSION = hashedVersion;
        _CACHED_CHAIN_ID = _chainID();
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(_TYPE_HASH, hashedName, hashedVersion);

        _isExcludedFromFee[_communityIssuanceAddress] = true; // Stability pool excluded from fee
        _isExcludedFromFee[_lqtyStakingAddress] = true;       // LQTY staking pool excluded from fee
        _isExcludedFromFee[_AUSDlpRewardsAddress] = true;     // AUSD LP reward pool excluded from fee
        _isExcludedFromFee[_AQUlpRewardsAddress] = true;      // AQU LP reward pool excluded from fee
        
        _isExcludedFromFee[address(this)] = true;             // LQTY token self  excluded from fee
        _isExcludedFromFee[_halflifeAddress] = true;          // Team halflife pool excluded from fee
        _isExcludedFromFee[_uniswapV2RouterAddress] = true;   // Remove liquity excluded from fee
        _isExcludedFromFee[_multisigAddressForStableCoinDex] = true;
        _isExcludedFromFee[_multisigAddressForLQTYHolders] = true;
        _isExcludedFromFee[_multisigAddressForPartners] = true;

        // --- Initial LQTY allocations ---

        // 32% for stability pool rewards
        uint depositorsAndFrontEndsEntitlement = _1_MILLION.mul(32);
        _mint(_communityIssuanceAddress, depositorsAndFrontEndsEntitlement);

        // 11.9% for AQU-FT LP rewards
        uint _AQUlpRewardsEntitlement = _1_MILLION.mul(119).div(10);
        AQUlpRewardsEntitlement = _AQUlpRewardsEntitlement;
        _mint(_AQUlpRewardsAddress, _AQUlpRewardsEntitlement);

        // 0.1% for aUSD-FTM LP rewards
        uint _AUSDlpRewardsEntitlement = _1_MILLION.mul(1).div(10);
        AUSDlpRewardsEntitlement = _AUSDlpRewardsEntitlement;
        _mint(_AUSDlpRewardsAddress, _AUSDlpRewardsEntitlement);

        // 10% for aUSD-3Pool
        uint stableCoinDexEntitlement = _1_MILLION.mul(10);
        _mint(_multisigAddressForStableCoinDex, stableCoinDexEntitlement);

        // 25% for Aquarius Team
        uint teamAndInvertorShare = _1_MILLION.mul(25);
        _mint(_lockInHalflifeAddress, teamAndInvertorShare);

        // 17% airdrop to LQTY holders and 3% for Liquity core team
        uint LQTYHoldersEntitlement = _1_MILLION.mul(20);
        _mint(_multisigAddressForLQTYHolders, LQTYHoldersEntitlement);
        
        // 1% for marketing/bounties:
        uint partnersEntitlement = _1_MILLION.mul(1);
        _mint(_multisigAddressForPartners, partnersEntitlement);
    
    }

    function setAddLiquityThreshold(uint256 _threshold) external onlyOwner {
        addLiquityThreshold = _threshold;
    }

    // --- External functions ---

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function getDeploymentStartTime() external view override returns (uint256) {
        return deploymentStartTime;
    }

    function getAUSDLpRewardsEntitlement() external view override returns (uint256) {
        return AUSDlpRewardsEntitlement;
    }

    function getAQULpRewardsEntitlement() external view override returns (uint256) {
        return AQUlpRewardsEntitlement;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {

        _requireValidRecipient(recipient);

        // Otherwise, standard transfer functionality
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        _requireValidRecipient(recipient);

        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, _allowances[sender][msg.sender].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external override returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external override returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function sendToLQTYStaking(address _sender, uint256 _amount) external override {
        _requireCallerIsLQTYStaking();
        _transfer(_sender, lqtyStakingAddress, _amount);
    }

    // --- EIP 2612 functionality ---

    function domainSeparator() public view override returns (bytes32) {
        if (_chainID() == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        } else {
            return _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
        }
    }

    function permit
    (
        address owner,
        address spender,
        uint amount,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
    external
    override
    {
        require(deadline >= now, 'LQTY: expired deadline');
        bytes32 digest = keccak256(abi.encodePacked('\x19\x01',
            domainSeparator(), keccak256(abi.encode(
                _PERMIT_TYPEHASH, owner, spender, amount,
                _nonces[owner]++, deadline))));
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress == owner, 'LQTY: invalid signature');
        _approve(owner, spender, amount);
    }

    function nonces(address owner) external view override returns (uint256) {// FOR EIP 2612
        return _nonces[owner];
    }

    // --- Internal operations ---

    function _chainID() private pure returns (uint256 chainID) {
        assembly {
            chainID := chainid()
        }
    }

    function _buildDomainSeparator(bytes32 typeHash, bytes32 name, bytes32 version) private view returns (bytes32) {
        return keccak256(abi.encode(typeHash, name, version, _chainID(), address(this)));
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        bool isExcludedFromFee = (_isExcludedFromFee[sender] || _isExcludedFromFee[recipient]);
        _tokenTransfer(sender, recipient, amount, isExcludedFromFee);
    }

    function _tokenTransfer(address sender, address recipient, uint256 amount, bool isExcludedFromFee) internal {
        if (!isExcludedFromFee) {
            (uint256 taxFee,uint256 liquidityFee,uint256 deflationFee) = _calculateFees(amount);
            
            // deflation
            _burn(sender, deflationFee);
            // donate tax fee into LQTYStaking pool
            _transferToLqtyStaking(sender, taxFee);
            // add liquidity
            _swapAndAddLiquify(sender, liquidityFee);

            amount = amount.sub(taxFee).sub(liquidityFee).sub(deflationFee);
        }

        _transferStandard(sender, recipient, amount);
    }

    function _transferToLqtyStaking(address sender, uint256 amount) internal {
        _transferStandard(sender, lqtyStakingAddress, amount);
        ILQTYStaking(lqtyStakingAddress).increaseF_LQTY(amount);
    }

    function _swapAndAddLiquify(address sender, uint256 amount) internal {
        // transfer to the contract first
        _transferStandard(sender, address(this), amount);

        uint256 balance = _balances[address(this)];

        if (balance < addLiquityThreshold) {
            return;
        }

        // split the amount into halves
        uint256 swapAmount = balance.div(2);
        uint256 liquifyAmount = balance.sub(swapAmount);

        // record the contract's current FTM balance in case of the manual transfer of FTM
        uint256 currentBalance = address(this).balance;
        // swap for FTM
        bool success = _swapTokensForFTM(swapAmount);
        if (!success) {
            return;
        }

        uint256 balanceSwapped = address(this).balance.sub(currentBalance);
        _addLiquidity(liquifyAmount, balanceSwapped);
        emit SwapAndLiquify(swapAmount, balanceSwapped, liquifyAmount);
    }

    function _addLiquidity(uint256 liquifyAmount, uint256 ftmAmount) private {
        IUniswapV2Router02 uniswapV2RouterCached = IUniswapV2Router02(uniswapV2RouterAddress);
        _approve(address(this), address(uniswapV2RouterCached), liquifyAmount);

        // add the liquidity
        uniswapV2RouterCached.addLiquidityETH{value : ftmAmount}(
            address(this),
            liquifyAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(0), // lp token to black hole
            block.timestamp
        );
    }

    function _swapTokensForFTM(uint256 swapAmount) private returns (bool) {
        IUniswapV2Router02 uniswapV2RouterCached = IUniswapV2Router02(uniswapV2RouterAddress);
        // generate the uniswap pair path
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2RouterCached.WETH();

        _approve(address(this), address(uniswapV2RouterCached), swapAmount);

        // make the swap
        try uniswapV2RouterCached.swapExactTokensForETHSupportingFeeOnTransferTokens(
            swapAmount,
            1, // accept any amount of FTM
            path,
            address(this),
            block.timestamp
        ) {
            return true;
         } catch {
            return false;
        }
    }

    function _calculateFees(uint256 amount) internal pure returns (uint256, uint256, uint256){
        uint256 taxFee = amount.mul(_taxFee).div(_1_THOUSAND_DENOMINATOR);
        uint256 liquidityFee = amount.mul(_liquidityFee).div(_1_THOUSAND_DENOMINATOR);
        uint256 deflationFee = amount.mul(_deflationFee).div(_1_THOUSAND_DENOMINATOR);
        return (taxFee, liquidityFee, deflationFee);
    }

    function _transferStandard(address sender, address recipient, uint256 amount) internal {
        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: burn from the zero address");

        _totalSupply = _totalSupply.sub(amount);
        _balances[account] = _balances[account].sub(amount);
        emit Transfer(account, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }


    // --- 'require' functions ---

    function _requireValidRecipient(address _recipient) internal view {
        require(
            _recipient != address(0) &&
            _recipient != address(this),
            "LQTY: Cannot transfer tokens directly to the LQTY token contract or the zero address"
        );
        require(
            _recipient != communityIssuanceAddress &&
            _recipient != lqtyStakingAddress,
            "LQTY: Cannot transfer tokens directly to the community issuance or staking contract"
        );
    }

    function _requireCallerIsLQTYStaking() internal view {
        require(msg.sender == lqtyStakingAddress, "LQTYToken: caller must be the LQTYStaking contract");
    }

    // --- Optional functions ---

    function name() external view override returns (string memory) {
        return _NAME;
    }

    function symbol() external view override returns (string memory) {
        return _SYMBOL;
    }

    function decimals() external view override returns (uint8) {
        return _DECIMALS;
    }

    function version() external view override returns (string memory) {
        return _VERSION;
    }

    function permitTypeHash() external view override returns (bytes32) {
        return _PERMIT_TYPEHASH;
    }

    receive() external payable {}
}
