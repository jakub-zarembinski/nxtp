// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "./Router.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "erc-payable-token/contracts/token/ERC1363/ERC1363.sol";

contract ChildToken is Ownable, ERC1363 {
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

contract RouterEXN is Router {

  ChildToken public childToken;
  uint256 public rootChainId;
  address public rootAssetId;

  constructor(address _routerFactory) Router(_routerFactory) {}

  function initChildToken(
    string memory _name,
    string memory _symbol,
    uint256 _amount,
    uint256 _rootChainId
  ) external onlyOwner {
    require(address(childToken) == address(0x0), "CHILD_TOKEN_ALREADY_INITIALIZED");
    childToken = new ChildToken(_name, _symbol, _amount);
    childToken.approve(address(transactionManager), _amount);
    transactionManager.addLiquidity(_amount, address(childToken));
    rootChainId = _rootChainId;
  }

  function initRootToken(
    address _rootAssetId
  ) external onlyOwner {
    require(rootAssetId == address(0x0), "ROOT_TOKEN_ALREADY_INITIALIZED");
    rootAssetId = _rootAssetId;
  }

  function removeLiquidity(
    uint256 amount,
    address assetId,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  ) public override {
    require(assetId != rootAssetId, "REMOVING_LIQUDITY_FROM_ROOT_TOKEN_IS_NOT_ALLOWED");
    super.removeLiquidity(amount, assetId, routerRelayerFeeAsset, routerRelayerFee, signature);
  }

  function prepare(
    ITransactionManager.PrepareArgs calldata args,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  ) public payable override returns(ITransactionManager.TransactionData memory) {
    
    ITransactionManager.TransactionData memory txData = super.prepare(args, routerRelayerFeeAsset, routerRelayerFee, signature);
    if (args.invariantData.sendingChainId == rootChainId && args.invariantData.receivingAssetId == address(childToken)) {
      childToken.mint(args.amount);
      childToken.approve(address(transactionManager), args.amount);
      transactionManager.addLiquidity(args.amount, address(childToken));
    }
    return txData;
  }

  function fulfill(
    ITransactionManager.FulfillArgs calldata args,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  ) public override returns(ITransactionManager.TransactionData memory) {
    ITransactionManager.TransactionData memory txData = super.fulfill(args, routerRelayerFeeAsset, routerRelayerFee, signature);
    if (args.txData.receivingChainId == rootChainId && args.txData.sendingAssetId == address(childToken)) {
      transactionManager.removeLiquidity(args.txData.amount, address(childToken), payable(this));
      childToken.burn(args.txData.amount);
    }
    return txData;
  }

  function cancel(
    ITransactionManager.CancelArgs calldata args,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  ) public override returns(ITransactionManager.TransactionData memory) {
    ITransactionManager.TransactionData memory txData = super.cancel(args, routerRelayerFeeAsset, routerRelayerFee, signature);
    if (args.txData.sendingChainId == rootChainId && args.txData.receivingAssetId == address(childToken)) {
      transactionManager.removeLiquidity(args.txData.amount, address(childToken), payable(this));
      childToken.burn(args.txData.amount);
    }
    return txData;
  }

}