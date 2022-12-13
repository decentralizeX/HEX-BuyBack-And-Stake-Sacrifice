// SPDX-License-Identifier: NONE
pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IHex {
    function stakeStart(uint256 newStakedHearts, uint256 newStakedDays) external;
    function stakeLists(address, uint256) external view returns (uint40, uint72, uint72, uint16, uint16, uint16, bool);
    function stakeEnd(uint256 stakeIndex, uint40 stakeIdParam) external;
}

//1inch swap proxy source: https://github.com/smye/1inch-swap/blob/master/contracts/SwapProxy.sol
contract BuyBackStakeHexSacrifice is ReentrancyGuard {
    uint256 public constant MIN_SERVE = 555; //555days minimum
    address public immutable AGGREGATION_ROUTER_V5 = 0x1111111254EEB25477B68fb85Ed929f73A960582;
    address public immutable HEX = 0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39;
    address public immutable noExpectationAddress;

    address[] public contractStakes; // stake owner (corresponds to the contract-owned HEX stakes)

    struct SwapDescription {
        IERC20 srcToken;
        IERC20 dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    constructor(address _noExpect) {
        noExpectationAddress = _noExpect;
    }

    event Sacrifice(address user, uint256 totalHex, IERC20 token, address ref);

    function buyBackStakeSacrificeUSDC(uint minOut, bytes calldata _data, uint stakeDays, address ref) public {
        require(stakeDays >= MIN_SERVE, "Minimum 555 days required");
        (, SwapDescription memory desc,) = abi.decode(_data[4:], (address, SwapDescription, bytes));

        IERC20(desc.srcToken).transferFrom(msg.sender, address(this), desc.amount);
        IERC20(desc.srcToken).approve(AGGREGATION_ROUTER_V5, desc.amount);

        (bool succ, bytes memory _data) = address(AGGREGATION_ROUTER_V5).call(_data);
        if (succ) {
            (uint returnAmount, uint gasLeft) = abi.decode(_data, (uint, uint));
            require(returnAmount >= minOut);

            uint hexToStake = returnAmount * 75 / 100;
            IHex(HEX).stakeStart(hexToStake, stakeDays);
            contractStakes.push(msg.sender);
            
            IERC20(HEX).transfer(noExpectationAddress, returnAmount-hexToStake);

            emit Sacrifice(msg.sender, returnAmount, desc.srcToken, ref);
        } else {
            revert();
        }
    }

    function buyBackStakeSacrificeETH(uint minOut, bytes calldata _data, uint stakeDays, address ref) payable public {
        require(stakeDays >= MIN_SERVE, "Minimum 555 days required");
        (, SwapDescription memory desc,) = abi.decode(_data[4:], (address, SwapDescription, bytes));

        (bool succ, bytes memory _data) = payable(AGGREGATION_ROUTER_V5).call{value: desc.amount}(_data);
        if (succ) {
            (uint returnAmount, uint gasLeft) = abi.decode(_data, (uint, uint));
            require(returnAmount >= minOut);

            uint hexToStake = returnAmount * 75 / 100;
            IHex(HEX).stakeStart(hexToStake, stakeDays);
            contractStakes.push(msg.sender);
            IERC20(HEX).transfer(noExpectationAddress, returnAmount-hexToStake);

            emit Sacrifice(msg.sender, returnAmount, desc.srcToken, ref);
        } else {
            revert();
        }
    }

    function endStake(uint256 stakeId) external nonReentrant {
        require(contractStakes[stakeId] == msg.sender, "Stake not owned");
        (uint40 stakeListId, , , uint256 enterDay , , ,) = IHex(HEX).stakeLists(address(this), stakeId);
        require((block.timestamp - (1575331200 + (enterDay-1) * 86400)) / 1 days > MIN_SERVE, "Must serve atleast 555 days");
        
        uint256 hexBefore = IERC20(HEX).balanceOf(address(this));
        IHex(HEX).stakeEnd(stakeId, stakeListId);
        uint256 hexEarned = IERC20(HEX).balanceOf(address(this)) - hexBefore;

        _removeStake(stakeId);

        IERC20(HEX).transfer(msg.sender, hexEarned);
    }

    function _removeStake(uint256 stakeId) private {   
        if(stakeId != contractStakes.length - 1) {
            contractStakes[stakeId] = contractStakes[contractStakes.length - 1];
        }

        contractStakes.pop();
    }

    function getAllStakeOwners() external view returns(address[] memory) {
        address[] memory addresses = new address[](contractStakes.length);
        for(uint i=0; i<contractStakes.length; i++) {
            addresses[i] = contractStakes[i];
        }
        return addresses;
    }

    function getUserOwnedStakes(address _user, uint256 _amount) external view returns(uint256, uint256[] memory) {
        uint256[] memory stakeIDs = new uint256[](_amount);
        uint256 count = 0;
        for(uint i=0; i<contractStakes.length; i++) {
            if(contractStakes[i] == _user) {
                stakeIDs[count] = i;
                count++;
            }
        }
        return (count, stakeIDs);
    }

    function totalStakes() external view returns (uint256) {
        return contractStakes.length;
    }

    // In case tokens are accidentally sent to the contract
    function misplacedEther() external {
        payable(noExpectationAddress).transfer(address(this).balance);
    }
    function misplacedToken(address _token) external {
        IERC20(_token).transfer(noExpectationAddress, IERC20(_token).balanceOf(address(this)));
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    // Fallback function is called when msg.data is not empty
    fallback() external payable {}
}
