// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "./Router.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "erc-payable-token/contracts/token/ERC1363/ERC1363.sol";

contract ChildAsset is Ownable, ERC1363 {
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

  address public rootAssetId;
  ChildAsset public childAsset;
  
  constructor(address _routerFactory) Router(_routerFactory) {}

  function initRootAsset(
    address _rootAssetId
  ) external onlyOwner {
    require(rootAssetId == address(0x0), "ROOT_ASSET_ALREADY_INITIALIZED");
    rootAssetId = _rootAssetId;
  }

  function initChildAsset(
    string memory _name,
    string memory _symbol,
    uint256 _amount
  ) external onlyOwner {
    require(address(childAsset) == address(0x0), "CHILD_ASSET_ALREADY_INITIALIZED");
    childAsset = new ChildAsset(_name, _symbol, _amount);
    childAsset.approve(address(transactionManager), _amount);
    transactionManager.addLiquidity(_amount, address(childAsset));
  }

  function removeLiquidity(
    uint256 amount,
    address assetId,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  ) public override {
    require(assetId != rootAssetId, "REMOVING_LIQUDITY_FROM_ROOT_ASSET_NOT_ALLOWED");
    super.removeLiquidity(amount, assetId, routerRelayerFeeAsset, routerRelayerFee, signature);
  }

  function prepare(
    ITransactionManager.PrepareArgs calldata args,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  ) public payable override returns(ITransactionManager.TransactionData memory) {
    
    ITransactionManager.TransactionData memory txData = super.prepare(args, routerRelayerFeeAsset, routerRelayerFee, signature);
    if (args.invariantData.sendingAssetId == rootAssetId && args.invariantData.receivingAssetId == address(childAsset)) {
      childAsset.mint(args.amount);
      childAsset.approve(address(transactionManager), args.amount);
      transactionManager.addLiquidity(args.amount, address(childAsset));
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
    if (args.txData.receivingAssetId == rootAssetId && args.txData.sendingAssetId == address(childAsset)) {
      transactionManager.removeLiquidity(args.txData.amount, address(childAsset), payable(this));
      childAsset.burn(args.txData.amount);
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
    if (args.txData.sendingAssetId == rootAssetId && args.txData.receivingAssetId == address(childAsset)) {
      transactionManager.removeLiquidity(args.txData.amount, address(childAsset), payable(this));
      childAsset.burn(args.txData.amount);
    }
    return txData;
  }

}