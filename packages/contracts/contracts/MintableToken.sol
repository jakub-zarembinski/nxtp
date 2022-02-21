// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "erc-payable-token/contracts/token/ERC1363/ERC1363.sol";

contract MintableToken is
    Ownable,
    ERC1363
{
    constructor(string memory name, string memory symbol, uint256 amount)
        ERC20(name, symbol)
    {
        _mint(_msgSender(), amount);
    }

    function mint(uint256 amount)
        external onlyOwner
    {
        _mint(_msgSender(), amount);
    }

    function burn(uint256 amount)
        external onlyOwner
    {
        _burn(_msgSender(), amount);
    }
}
