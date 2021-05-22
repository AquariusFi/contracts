// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract MultiSig {
    
    IERC20 public token;
    bool private initToken;
    address private tokenSetter;

    uint256 public threshold;
    address[] public owners;
    mapping (address => bool) public isOwner;
    mapping (bytes32 => uint256) public numberOfTransferSignatures;
    mapping (bytes32 => uint256) public numberOfAddOwnerSignatures;
    mapping (address => mapping(bytes32 => bool)) public hasSignTransfer;
    mapping (address => mapping(bytes32 => bool)) public hasSignAddOwner;

    string constant public name = "MultiSig AQU";
    string constant public symbol = "MAQU";
    uint8  constant public decimals = 18;

    event SignTransfer(address indexed owner, address indexed recipient, uint256 amount);
    event SignAddOwner(address indexed owner, address indexed newOwner, uint256 threshold);
    event ThresholdUpdate(uint256 oldThreshol, uint256 newThreshol);
    event AddNewOwner(address indexed newOwner);

    
    constructor(
    ) public {
        owners.push(0x9100e62512645Ae113F56165981776c948e38182);  // address of aqu team
        owners.push(0x47a7d15B7452820DD7A565ea9C39D8b6cef51ed7);  // address of liquityFi team
        
        isOwner[0x9100e62512645Ae113F56165981776c948e38182] = true;
        isOwner[0x47a7d15B7452820DD7A565ea9C39D8b6cef51ed7] = true;

        threshold = 2;

        tokenSetter = msg.sender;
    }

    function setToken(
        address _tokenAddress
    ) external {
        require(!initToken, "MultiSig: token has been initialized");
        require(msg.sender = tokenSetter, "MultiSig: not token setter");
        token = IERC20(_tokenAddress);
        initToken = true;
    }


    function addOwner(
        address _newOwner,
        uint256 _threshold
    ) external {
        require(!isOwner[_newOwner], "MultiSig: it's already the owner");
        require(isOwner[msg.sender], "MultiSig: not owner");
        require(_threshold <= (owners.length + 1), "MultiSig: invalid threshold");
        
        bytes32 key = keccak256(abi.encodePacked(_newOwner, _threshold));
        require(!hasSignAddOwner[msg.sender][key], "MultiSig: you've already signed it");
        
        numberOfAddOwnerSignatures[key]++;
        hasSignAddOwner[msg.sender][key] = true;
        emit SignAddOwner(msg.sender, _newOwner, _threshold);

        if (numberOfAddOwnerSignatures[key] >= threshold) {
            
            owners.push(_newOwner);
            isOwner[_newOwner] = true;
            emit AddNewOwner(_newOwner);
            
            emit ThresholdUpdate(threshold, _threshold);
            threshold = _threshold;
            
            numberOfAddOwnerSignatures[key] = 0;

            for (uint256 i = 0; i < owners.length; i++) {
                hasSignAddOwner[owners[i]][key] = false;
            }
        }
    }

    function transfer(address recipient, uint256 amount)  public returns (bool){
        
        require(isOwner[msg.sender], "MultiSig: not owner");
        require(token.balanceOf(address(this)) >= amount, "MultiSig: insufficient balance");

        bytes32 key = keccak256(abi.encodePacked(recipient, amount));
        require(!hasSignTransfer[msg.sender][key], "MultiSig: you've already signed it");
        
        numberOfTransferSignatures[key]++;
        hasSignTransfer[msg.sender][key] = true;

        emit SignTransfer(msg.sender, recipient, amount);

        if (numberOfTransferSignatures[key] >= threshold) {
            token.transfer(recipient, amount);
            numberOfTransferSignatures[key] = 0;

            for (uint256 i = 0; i < owners.length; i++) {
                hasSignTransfer[owners[i]][key] = false;
            }
        }
        
    }

    function balanceOf(address _owner) public view returns (uint) {
        if (isOwner[_owner]){
            return token.balanceOf(address(this));
        }
        return 0;
    }

    function approve(address spender, uint256 value) external returns (bool){
        return false;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool){
        return false;
    }

    function totalSupply() external view returns (uint256){
          return token.totalSupply();
    }

    function allowance(address owner, address spender) external view returns (uint256){
        return 0;
    }
    
   
}